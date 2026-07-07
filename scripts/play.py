#!/usr/bin/env python3
"""Demo CLI: juega un episodio con un agente (random o heurístico)."""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

from arcade_ai.agents import make_agent
from arcade_ai.envs.ale_env import list_ale_games, make_arcade_env
from arcade_ai.envs.mame_env import mame_status


def main() -> None:
    parser = argparse.ArgumentParser(description="Arcade AI — demo local")
    parser.add_argument(
        "--game",
        default="breakout",
        help=f"Juego ALE: {', '.join(list_ale_games())}",
    )
    parser.add_argument(
        "--agent",
        default="random",
        choices=["random", "heuristic"],
        help="Nivel de IA",
    )
    parser.add_argument("--episodes", type=int, default=3)
    parser.add_argument("--max-steps", type=int, default=5000)
    parser.add_argument("--render", action="store_true", help="Ventana gráfica")
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()

    status = mame_status()
    print("=== Arcade AI — demo local ===")
    print(f"Motor: ALE (Atari 2600) | MAME: {'OK' if status['mame_installed'] else 'no instalado'}")
    if not status["mame_installed"]:
        print(f"  → {status['hint']}")
    print(f"Juego: {args.game} | Agente: {args.agent} | Episodios: {args.episodes}\n")

    render_mode = "human" if args.render else None
    env = make_arcade_env(args.game, render_mode=render_mode)
    agent = make_agent(args.agent, args.game)

    for ep in range(1, args.episodes + 1):
        obs, info = env.reset(seed=args.seed + ep)
        agent.reset()
        total_reward = 0.0
        steps = 0
        while steps < args.max_steps:
            action = agent.act(obs, env)
            obs, reward, terminated, truncated, info = env.step(action)
            total_reward += float(reward)
            steps += 1
            if args.render:
                env.render()
                time.sleep(1.0 / 30.0)
            if terminated or truncated:
                break
        print(f"Episodio {ep}: reward={total_reward:.1f} steps={steps}")

    env.close()
    print("\nListo.")


if __name__ == "__main__":
    main()
