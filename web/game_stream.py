"""Live ALE gameplay streaming for the "AI plays now" feature.

This is the *real* part of the demo: it actually runs a Gymnasium/ALE
environment with one of the heuristic agents from `arcade_ai.agents`, renders
real frames (`render_mode="rgb_array"`), and yields them (plus the agent's
real decision metadata) so `web/app.py` can push them to the browser over a
WebSocket. Nothing here is pre-recorded or faked.
"""

from __future__ import annotations

import asyncio
import base64
import io
import time
from dataclasses import dataclass, field
from typing import Any, AsyncIterator

from PIL import Image

from arcade_ai.agents import make_agent
from arcade_ai.envs.ale_env import list_ale_games, make_arcade_env

MAX_CONCURRENT_SESSIONS = 4
_session_semaphore = asyncio.Semaphore(MAX_CONCURRENT_SESSIONS)

JPEG_QUALITY = 65
MAX_STEPS_PER_EPISODE = 4000
MAX_EPISODES = 20  # safety cap so a forgotten open tab doesn't run forever


def hosted_ale_games() -> dict[str, dict[str, Any]]:
    """ALE games this deployment can actually stream live."""
    return list_ale_games()


def _frame_to_b64_jpeg(frame) -> str:
    img = Image.fromarray(frame)
    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=JPEG_QUALITY)
    return base64.b64encode(buf.getvalue()).decode("ascii")


@dataclass
class SessionStats:
    episode: int = 0
    step: int = 0
    total_reward: float = 0.0
    last_decision: dict = field(default_factory=dict)


async def run_live_session(
    game: str,
    agent_level: str,
    fps: float,
    seed: int,
) -> AsyncIterator[dict[str, Any]]:
    """Async generator yielding JSON-serializable events for the WebSocket.

    Event types: "connected", "frame", "episode_end", "error".
    Runs the (blocking) ALE step loop in a background thread via
    `asyncio.to_thread` so the event loop stays responsive, and paces itself
    to roughly `fps` frames/sec so it's watchable and doesn't peg the CPU.
    """
    async with _session_semaphore:
        try:
            env = await asyncio.to_thread(make_arcade_env, game, render_mode="rgb_array")
        except Exception as exc:  # noqa: BLE001 — surface to client
            yield {"type": "error", "message": f"Could not start environment: {exc}"}
            return

        agent = make_agent(agent_level, game)
        stats = SessionStats()
        width, height = 160, 210
        try:
            probe = await asyncio.to_thread(env.render)
            if probe is not None and len(probe.shape) >= 2:
                height, width = int(probe.shape[0]), int(probe.shape[1])
        except Exception:
            pass
        yield {
            "type": "connected",
            "game": game,
            "agent": agent.name,
            "max_episodes": MAX_EPISODES,
            "width": width,
            "height": height,
        }

        try:
            for episode in range(1, MAX_EPISODES + 1):
                stats.episode = episode
                obs, _info = await asyncio.to_thread(env.reset, seed=seed + episode)
                agent.reset()
                stats.step = 0
                stats.total_reward = 0.0

                frame_interval = 1.0 / max(fps, 1.0)
                while stats.step < MAX_STEPS_PER_EPISODE:
                    loop_start = time.monotonic()

                    def _tick():
                        action = agent.act(obs, env)
                        return (action, *env.step(action))

                    action, next_obs, reward, terminated, truncated, _info = await asyncio.to_thread(_tick)
                    obs = next_obs
                    stats.step += 1
                    stats.total_reward += float(reward)
                    frame = await asyncio.to_thread(env.render)

                    yield {
                        "type": "frame",
                        "episode": episode,
                        "step": stats.step,
                        "reward": stats.total_reward,
                        "frame": _frame_to_b64_jpeg(frame) if frame is not None else None,
                        "decision": getattr(agent, "last_decision", {}) or {},
                    }

                    if terminated or truncated:
                        yield {
                            "type": "episode_end",
                            "episode": episode,
                            "steps": stats.step,
                            "total_reward": stats.total_reward,
                        }
                        break

                    elapsed = time.monotonic() - loop_start
                    remaining = frame_interval - elapsed
                    if remaining > 0:
                        await asyncio.sleep(remaining)
        finally:
            await asyncio.to_thread(env.close)
