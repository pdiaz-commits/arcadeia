"""gymnasium.Env wrapper around MAME running Tehkan World Cup (tehkanwc).

Communicates with ``scripts/mame/tehkan_learn.lua`` over a TCP socket.
The Lua driver sends one JSON observation per ``emu.frame_done`` and
blocks waiting for the next action — that gives us perfect frame lockstep
regardless of host latency.

Key design choices (see also ``docs/tehkan_train_design.md`` notes in progress):

* Action space is ``Box(-1, 1, (3,), float32)``: a continuous trackball
  intent plus a kick threshold. PPO learns diagonal magnitudes faster
  than traversing a 5x5 MultiDiscrete grid.
* Reward is Potential-Based Reward Shaping (PBRS) plus a terminal
  +1 / -1 for scored / conceded goals. The per-frame penalty is
  intentionally absent — otherwise PPO learned to self-own-goal to
  collect the truncation bonus (lesson learnt from the very first
  prototype).
* Termination is driven by detected goal events; truncation is a
  step cap. A full 90 s match is too sparse to learn from.
* MAME is spawned lazily inside ``reset()`` (not ``__init__``) so that
  SB3's ``SubprocVecEnv`` can ``fork`` workers without inheriting our
  open sockets / Popen handles.
* Each worker binds a unique port (``9878 + env_id``) so multiple
  training envs can coexist on one host.
"""

from __future__ import annotations

import json
import os
import socket
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Optional

import numpy as np

try:
    import gymnasium as gym
    from gymnasium import spaces
except ImportError as exc:  # pragma: no cover — gymnasium is a hard dep
    raise ImportError(
        "gymnasium is required for tehkan_env. "
        "Verifica requirements.txt: gymnasium[atari]>=0.29.0"
    ) from exc

from .mame_env import resolve_mame_binary

_ROOT = Path(__file__).resolve().parents[3]
_DEFAULT_LUA = _ROOT / "scripts" / "mame" / "tehkan_learn.lua"
_DEFAULT_ROMS = _ROOT / "roms"
_DEFAULT_CFG = _ROOT / "cfg"

OBS_DIM = 14  # ver `_obs_to_array` para el orden


@dataclass
class TehkanResult:
    ok: bool
    reason: str = ""


class TehkanEnv(gym.Env):
    """gymnasium.Env for Tehkan World Cup via MAME + Lua socket bridge."""

    metadata = {"render_modes": ["human"], "render_fps": 60}

    def __init__(
        self,
        env_id: int = 0,
        rom_dir: Optional[Path] = None,
        mame_binary: Optional[str] = None,
        max_steps: int = 2000,
        render: bool = False,
        mame_root: Optional[Path] = None,
        dry_run: bool = False,
    ) -> None:
        super().__init__()
        self.env_id = env_id
        self.port = 9878 + env_id
        self.rom_dir = Path(rom_dir) if rom_dir else _DEFAULT_ROMS
        self.mame_root = Path(mame_root) if mame_root else _ROOT
        self.mame_binary = mame_binary or resolve_mame_binary()
        self.max_steps = max_steps
        self.render_window = render
        # dry_run=True: NO arranca MAME. Asume que un FakeLuaServer ya esta
        # escuchando en localhost:port; util para CI / smoke tests.
        self.dry_run = dry_run

        # Continuous trackball (dx, dy) + kick threshold in [-1, 1]
        self.action_space = spaces.Box(
            low=-1.0, high=1.0, shape=(3,), dtype=np.float32
        )
        self.observation_space = spaces.Box(
            low=-1.0, high=1.0, shape=(OBS_DIM,), dtype=np.float32
        )

        self._mame_proc: Optional[subprocess.Popen] = None
        self._sock: Optional[socket.socket] = None
        self._steps = 0
        self._frame = 0
        self._last_obs: Optional[dict] = None
        self._last_potential = 0.0
        self._last_score_us = -1
        self._last_score_them = -1
        self._episode_goal_seen = False

    # ------------------------------------------------------------------
    # MAME process lifecycle (lazy in reset, NOT in __init__ — ver docstring).
    # ------------------------------------------------------------------
    def _spawn_mame(self) -> None:
        if self.dry_run:
            # En dry-run MAME esta reemplazado por FakeLuaServer; no spawn.
            return
        if not self.mame_binary:
            raise RuntimeError(
                "MAME no encontrado. Ejecuta ./scripts/install_mame.sh o "
                "exporta ARCADEIA_MAME_BIN=<path>."
            )
        rom_path = self.rom_dir / "tehkanwc.zip"
        if not rom_path.is_file():
            raise FileNotFoundError(
                f"ROM no encontrada: {rom_path}. Copia la ROM legal en roms/."
            )
        env = os.environ.copy()
        env["ARCAIDEIA_ROOT"] = str(self.mame_root)
        env["ARCAIDEIA_LUA_HOST"] = "127.0.0.1"
        env["ARCAIDEIA_LUA_PORT"] = str(self.port)
        env["ARCAIDEIA_LUA_NAME"] = "tehkan_learn"

        cmd = [
            self.mame_binary,
            "tehkanwc",
            "-rompath", str(self.rom_dir),
            "-autoboot_script", str(_DEFAULT_LUA),
            "-autoboot_delay", "2",
        ]
        if self.render_window:
            cmd.append("-window")
        else:
            cmd.append("-nowindow")
        # Plugin path evita segment fault en macOS (cf. teach_session.sh).
        plugin_root = self.mame_root / "vendor" / "mame" / "mame0288-arm64" / "plugins"
        if plugin_root.is_dir():
            cmd.extend([
                "-pluginspath", str(plugin_root),
                "-homepath", str(self.mame_root),
                "-inipath", f"{self.mame_root / 'cfg'};.",
                "-plugin", "hiscore",
            ])

        self._mame_proc = subprocess.Popen(
            cmd,
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            cwd=str(self.mame_root),
        )

    def _connect_socket(self, attempts: int = 120) -> None:
        """Espera a que el Lua script abra la conexion TCP."""
        if self._sock is not None:
            return
        deadline = time.monotonic() + 30.0
        while time.monotonic() < deadline and attempts > 0:
            if self._mame_proc is not None and self._mame_proc.poll() is not None:
                raise RuntimeError(
                    f"MAME termino con codigo {self._mame_proc.returncode} "
                    "antes de conectar. Revisa la ROM y el script lua."
                )
            try:
                s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                s.settimeout(1.0)
                s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                s.connect(("127.0.0.1", self.port))
                self._sock = s
                return
            except (ConnectionRefusedError, socket.timeout, OSError):
                time.sleep(0.25)
                attempts -= 1
        raise TimeoutError(
            f"No se pudo conectar a 127.0.0.1:{self.port} tras 30 s. "
            "MAME-Lua probablemente no levanto luasocket."
        )

    def _send(self, obj: dict[str, Any]) -> bool:
        if self._sock is None:
            return False
        payload = (json.dumps(obj, separators=(",", ":")) + "\n").encode("utf-8")
        try:
            self._sock.sendall(payload)
            return True
        except OSError:
            return False

    def _recv(self, timeout: float = 10.0) -> Optional[dict[str, Any]]:
        if self._sock is None:
            return None
        self._sock.settimeout(timeout)
        buf = bytearray()
        try:
            while True:
                chunk = self._sock.recv(4096)
                if not chunk:
                    return None
                buf.extend(chunk)
                if b"\n" in buf:
                    line, _, rest = buf.partition(b"\n")
                    if rest:
                        # No deberia pasar con nuestro protocolo — pero defensivo.
                        pass
                    return json.loads(line.decode("utf-8"))
        except (socket.timeout, json.JSONDecodeError, OSError):
            return None

    # ------------------------------------------------------------------
    # Observation shaping: Order estable para que SB3 indexe siempre
    # las mismas features. Todo normalizado a [-1, 1].
    # ------------------------------------------------------------------
    @staticmethod
    def _obs_to_array(obs: dict[str, Any]) -> np.ndarray:
        ball = obs.get("ball", {}) or {}
        player = obs.get("player", {}) or {}

        def norm_x(x: Any) -> float:
            # Field width ~256. Center=128. map a [-1, 1].
            v = (float(x or 128) - 128.0) / 128.0
            return float(np.clip(v, -1.0, 1.0))

        def norm_y(y: Any) -> float:
            # 0..240 → [-1, 1].
            v = (float(y or 112) - 112.0) / 112.0
            return float(np.clip(v, -1.0, 1.0))

        def b2(v: Any) -> float:
            return 1.0 if v else 0.0

        vec = np.array([
            norm_x(ball.get("x")),               # 0
            norm_y(ball.get("y")),               # 1
            b2(ball.get("valid")),               # 2
            norm_x(player.get("x")),             # 3
            norm_y(player.get("y")),             # 4
            b2(player.get("valid")),             # 5
            b2(obs.get("possessed")),            # 6
            b2(obs.get("in_attack")),            # 7
            b2(obs.get("near_shoot_zone")),      # 8
            float(obs.get("score_us", 0) or 0) / 9.0,    # 9
            float(obs.get("score_them", 0) or 0) / 9.0,  # 10
            b2(obs.get("goal_event") == "us"),            # 11
            b2(obs.get("goal_event") == "them"),          # 12
            float(obs.get("frame", 0) % 1024) / 512.0 - 1.0,  # 13 (tiempo buco)
        ], dtype=np.float32)
        return vec

    @staticmethod
    def _potential(obs: dict[str, Any]) -> float:
        # Φ(s) = c1 * ball_y_progress_to_opp_goal - c2 * player_to_ball
        # ball.y bajo => más cerca de portería rival.
        ball_y = float(obs.get("ball", {}).get("y", MID_FALLBACK))
        progress = (200.0 - ball_y) / 200.0  # 0..1, +1 = en portería rival
        bx = float(obs.get("ball", {}).get("x", 128))
        by = float(obs.get("ball", {}).get("y", 112))
        px = float(obs.get("player", {}).get("x", 128))
        py = float(obs.get("player", {}).get("y", 112))
        dist = (abs(px - bx) + abs(py - by)) / 240.0  # ~manhattan, normalizada
        return 1.0 * progress - 0.5 * dist

    # ------------------------------------------------------------------
    # gym.Env API
    # ------------------------------------------------------------------
    def reset(
        self,
        seed: Optional[int] = None,
        options: Optional[dict[str, Any]] = None,
    ) -> tuple[np.ndarray, dict[str, Any]]:
        super().reset(seed=seed)
        # Re-inicializa estado del env (no cierres el proceso: MAME es lento).
        if self._mame_proc is None or self._mame_proc.poll() is not None:
            self._sock = None
            self._spawn_mame()
            self._connect_socket()
            # Consumimos el handshake "hello" antes del primer obs.
            if not self.dry_run:
                self._recv(timeout=15.0)
        else:
            # Pide restart limpio sin matar el proceso.
            self._send({"type": "cmd", "cmd": "reset"})

        # spin-wait hasta phase == "play"
        play_obs: Optional[dict[str, Any]] = None
        for _ in range(1200):  # ~60s con sleeps de 50ms
            obs = self._recv(timeout=0.2)
            if obs and obs.get("phase") == "play":
                play_obs = obs
                break
            if (
                self._mame_proc is not None
                and self._mame_proc.poll() is not None
            ):
                raise RuntimeError("MAME murio durante el boot.")
        if play_obs is None:
            raise TimeoutError(
                "MAME no alcanzo phase=play tras 60 s. ¿ROM rota? ¿DSW?"
            )

        self._last_obs = play_obs
        self._last_potential = self._potential(play_obs)
        self._last_score_us = play_obs.get("score_us", -1)
        self._last_score_them = play_obs.get("score_them", -1)
        self._steps = 0
        self._episode_goal_seen = False

        return self._obs_to_array(play_obs), {
            "frame": play_obs.get("frame", 0),
            "phase": play_obs.get("phase"),
        }

    def step(
        self, action: np.ndarray
    ) -> tuple[np.ndarray, float, bool, bool, dict[str, Any]]:
        action = np.asarray(action, dtype=np.float32).reshape(3)
        MAX = 58
        dx = int(np.clip(action[0], -1.0, 1.0) * MAX)
        dy = int(np.clip(action[1], -1.0, 1.0) * MAX)
        kick = bool(action[2] > 0.0)
        self._send({"type": "act", "dx": dx, "dy": dy, "kick": kick})

        obs = self._recv(timeout=15.0)
        if obs is None:
            # Conexion rota: MAME o Lua murieron. Reset silencioso.
            return (
                np.zeros(OBS_DIM, dtype=np.float32),
                0.0, True, False,
                {"reason": "mame_died"},
            )

        # Reward = PBRS step + goal bonus/penalty.
        phi_now = self._potential(obs)
        reward = float(phi_now - self._last_potential)
        self._last_potential = phi_now

        goal_event = obs.get("goal_event", "none")
        if goal_event == "us":
            reward += 1.0
            terminated = True
            self._episode_goal_seen = True
        elif goal_event == "them":
            reward -= 1.0
            terminated = True
            self._episode_goal_seen = True
        else:
            terminated = False

        self._steps += 1
        truncated = self._steps >= self.max_steps
        self._last_obs = obs
        return (
            self._obs_to_array(obs),
            reward,
            terminated,
            truncated,
            {
                "frame": obs.get("frame", 0),
                "phase": obs.get("phase"),
                "score_us": obs.get("score_us", -1),
                "score_them": obs.get("score_them", -1),
                "goal_event": goal_event,
            },
        )

    def close(self) -> None:
        try:
            if self._sock is not None:
                try:
                    self._send({"type": "cmd", "cmd": "quit"})
                except OSError:
                    pass
                self._sock.close()
        finally:
            self._sock = None
        if self._mame_proc is not None:
            try:
                self._mame_proc.terminate()
                self._mame_proc.wait(timeout=5)
            except (subprocess.TimeoutExpired, OSError):
                try:
                    self._mame_proc.kill()
                except OSError:
                    pass
            self._mame_proc = None


# ----------------------------------------------------------------------
# Util interno — coordenadas "neutras" cuando el sprite no se detecta.
# ----------------------------------------------------------------------
MID_FALLBACK = 112


# ----------------------------------------------------------------------
# Dry-run helper: arranca un fake "lua server" inline y hace N pasos
# con acciones random. Sirve para validar el protocolo sin MAME.
# Útil para CI / debugging: `python -m arcade_ai.envs.tehkan_env --dry-run`
# ----------------------------------------------------------------------
def _dry_run(env_id: int = 0, steps: int = 50) -> TehkanResult:
    import threading

    from .dry_lua_server import FakeLuaServer

    port = 9878 + env_id
    server = FakeLuaServer(port=port)
    server.start()

    env = TehkanEnv(env_id=env_id, dry_run=True)
    try:
        obs, info = env.reset(seed=42)
        print(f"[dry-run] reset_obs shape={obs.shape}  ball={info}")
        rng = np.random.default_rng(42)
        total_r = 0.0
        for t in range(steps):
            a = rng.uniform(-1.0, 1.0, size=3).astype(np.float32)
            a[2] = float(rng.random() > 0.95) * 2 - 1
            obs, r, term, trunc, info = env.step(a)
            total_r += r
            if t < 5 or t % 10 == 0:
                print(
                    f"[dry-run] t={t:>3}  r={r:+.3f}  term={term}  trunc={trunc}  "
                    f"goal={info.get('goal_event')}  "
                    f"ball={obs[0:2].round(2)}  player={obs[3:5].round(2)}"
                )
            if term or trunc:
                break
        print(f"[dry-run] done total_r={total_r:.3f}")
        server.stop()
        env.close()
        return TehkanResult(ok=True)
    except Exception as e:  # noqa: BLE001 — surfacing to caller in dry-run
        server.stop()
        env.close()
        return TehkanResult(ok=False, reason=str(e))


if __name__ == "__main__":  # pragma: no cover — utility entry point
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--steps", type=int, default=50)
    parser.add_argument("--env-id", type=int, default=0)
    args = parser.parse_args()
    if args.dry_run:
        result = _dry_run(env_id=args.env_id, steps=args.steps)
        raise SystemExit(0 if result.ok else 1)
    else:
        parser.print_help()
