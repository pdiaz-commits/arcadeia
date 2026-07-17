"""Fake 'MAME+Lua' server para dry-run del TehkanEnv.

Emula exactamente el protocolo de ``scripts/mame/tehkan_learn.lua`` sobre
TCP. Útil para CI / debugging sin necesidad de MAME real: arranca el
server, conecta el env, simula ``N`` observaciones y verifica que el
ciclo obs/action/reward/termination funciona end-to-end.

Uso: ver ``tehkan_env._dry_run``.
"""

from __future__ import annotations

import json
import socket
import threading
import time
from dataclasses import dataclass, field
from typing import Optional


@dataclass
class FakeLuaServer:
    port: int
    ball_x: int = 128
    ball_y: int = 112
    player_x: int = 128
    player_y: int = 112
    score_us: int = 0
    score_them: int = 0
    frame: int = 0
    _server: Optional[socket.socket] = None
    _conn: Optional[socket.socket] = None
    _thread: Optional[threading.Thread] = None
    _stop = threading.Event()
    # Para test: inyectar goal event en un step concreto.
    pending_goal_at: Optional[int] = field(default=None)
    pending_goal_team: str = "us"  # "us" | "them" | "none"

    # ------------------------------------------------------------------
    def start(self) -> None:
        self._stop.clear()
        self._server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._server.bind(("127.0.0.1", self.port))
        self._server.listen(1)
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._conn is not None:
            try: self._conn.shutdown(socket.SHUT_RDWR)
            except OSError: pass
            try: self._conn.close()
            except OSError: pass
            self._conn = None
        if self._server is not None:
            try: self._server.close()
            except OSError: pass
            self._server = None
        if self._thread is not None:
            self._thread.join(timeout=2.0)
            self._thread = None

    # ------------------------------------------------------------------
    def _serve(self) -> None:
        self._server.settimeout(1.0)
        while not self._stop.is_set():
            try:
                conn, _ = self._server.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            self._conn = conn
            # Emula la transición boot_sequence(frames 1-520) → play de MAME:
            # mandamos DOS obs consecutivos para que el spin-wait de Python
            # salga sin necesidad de que aún haya llegado una acción.
            self._send_obs(phase="boot", goal_event="none")
            self._send_obs(phase="play", goal_event="none")
            try:
                while not self._stop.is_set():
                    line = conn.recv(4096)
                    if not line:
                        break
                    # Solo consumimos; respondemos con la siguiente obs
                    # después de un pequeño delay (emula un frame_done).
                    for raw in line.split(b"\n"):
                        raw = raw.strip()
                        if not raw:
                            continue
                        try:
                            msg = json.loads(raw)
                        except json.JSONDecodeError:
                            continue
                        self._handle(msg)
                        time.sleep(0.005)
                        self._send_obs(phase="play", goal_event=self._maybe_goal())
            except OSError:
                break
            finally:
                try: conn.close()
                except OSError: pass
                self._conn = None

    # ------------------------------------------------------------------
    def _handle(self, msg: dict) -> None:
        if msg.get("type") == "cmd":
            cmd = msg.get("cmd")
            if cmd == "quit":
                self._stop.set()
            elif cmd == "reset":
                self.score_us = 0
                self.score_them = 0
                self.frame = 0
        elif msg.get("type") == "act":
            # Sin emulador arriba, el "agente" puede mover la bola — simulamos
            # que cualquier accion >0.5 acerca al balon a la porteria rival.
            dx = float(msg.get("dx", 0)) / 58.0
            dy = float(msg.get("dy", 0)) / 58.0
            self.ball_x = int(max(0, min(255, self.ball_x + dx * 8)))
            self.ball_y = int(max(0, min(239, self.ball_y + dy * 12)))
            self.player_x = int(max(0, min(255, self.player_x + dx * 6)))
            self.player_y = int(max(0, min(239, self.player_y + dy * 8)))

    def _maybe_goal(self) -> str:
        if self.pending_goal_at is None:
            return "none"
        if self.frame == self.pending_goal_at:
            team = self.pending_goal_team
            if team == "us":
                self.score_us += 1
            elif team == "them":
                self.score_them += 1
            self.pending_goal_at = None
            self.ball_x, self.ball_y = 128, 112
            return team
        return "none"

    # ------------------------------------------------------------------
    def _send_obs(self, phase: str, goal_event: str) -> None:
        if self._conn is None:
            return
        possessed = abs(self.ball_x - self.player_x) + abs(self.ball_y - self.player_y) < 28
        payload = {
            "type": "obs",
            "frame": self.frame,
            "phase": phase,
            "ball": {"x": self.ball_x, "y": self.ball_y, "valid": 1},
            "player": {"x": self.player_x, "y": self.player_y, "valid": 1},
            "possessed": possessed,
            "in_attack": self.ball_y < 112,
            "near_shoot_zone": self.player_y < 70 and abs(self.player_x - 128) < 60,
            "score_us": self.score_us,
            "score_them": self.score_them,
            "goal_event": goal_event,
        }
        self.frame += 1
        try:
            self._conn.sendall((json.dumps(payload) + "\n").encode("utf-8"))
        except OSError:
            pass
