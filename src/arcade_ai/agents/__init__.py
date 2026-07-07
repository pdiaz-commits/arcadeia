from __future__ import annotations

import random
from typing import Protocol

import numpy as np

# ALE Breakout (action_space Discrete(4))
NOOP, FIRE, RIGHT, LEFT = 0, 1, 2, 3
_ACTION_NAMES = {NOOP: "NOOP", FIRE: "FIRE", RIGHT: "RIGHT", LEFT: "LEFT"}


class Agent(Protocol):
    name: str

    def reset(self) -> None: ...
    def act(self, observation, env) -> int: ...


class RandomAgent:
    name = "random"

    def __init__(self) -> None:
        self.last_decision: dict = {}

    def reset(self) -> None:
        self.last_decision = {}

    def act(self, observation, env) -> int:
        action = int(env.action_space.sample())
        self.last_decision = {
            "phase": "random",
            "reason": "Uniform random action (baseline agent)",
            "action": action,
        }
        return action


class HeuristicBreakoutAgent:
    """Sigue la pelota; lanza con FIRE al inicio y tras perder vida."""

    name = "heuristic"

    def __init__(self) -> None:
        self.step = 0
        self.last_decision: dict = {}

    def reset(self) -> None:
        self.step = 0
        self.last_decision = {}

    def act(self, observation, env) -> int:
        self.step += 1

        # Inicio de partida: hay que pulsar FIRE para sacar la pelota
        if self.step <= 25:
            action = FIRE if self.step % 4 == 0 else (RIGHT if self.step % 2 == 0 else LEFT)
            self.last_decision = {
                "phase": "kickoff",
                "reason": "Boot sequence: launching ball with FIRE and centering paddle",
                "action": _ACTION_NAMES.get(action, action),
            }
            return action

        if observation is None or not hasattr(observation, "shape"):
            action = random.choice([RIGHT, LEFT])
            self.last_decision = {
                "phase": "no_observation",
                "reason": "No usable frame yet — moving randomly",
                "action": _ACTION_NAMES.get(action, action),
            }
            return action

        gray = observation.mean(axis=2) if observation.ndim == 3 else observation
        h, w = gray.shape
        paddle_x = self._paddle_x(gray)
        ball_x = self._ball_x(gray)

        if ball_x is None:
            # Sin pelota visible: lanzar y centrar paleta
            if self.step % 8 == 0:
                action = FIRE
                reason = "No ball visible — pressing FIRE to serve"
            elif paddle_x < w // 2 - 8:
                action = RIGHT
                reason = "No ball visible — recentering paddle (move right)"
            elif paddle_x > w // 2 + 8:
                action = LEFT
                reason = "No ball visible — recentering paddle (move left)"
            else:
                action = FIRE
                reason = "No ball visible — paddle centered, pressing FIRE"
            self.last_decision = {
                "phase": "searching",
                "reason": reason,
                "paddle_x": paddle_x,
                "ball_x": None,
                "action": _ACTION_NAMES.get(action, action),
            }
            return action

        if ball_x > paddle_x + 6:
            action = RIGHT
            reason = f"Ball (x={ball_x}) is right of paddle (x={paddle_x}) — moving right"
        elif ball_x < paddle_x - 6:
            action = LEFT
            reason = f"Ball (x={ball_x}) is left of paddle (x={paddle_x}) — moving left"
        else:
            action = NOOP
            reason = f"Ball (x={ball_x}) aligned with paddle (x={paddle_x}) — holding position"
        self.last_decision = {
            "phase": "tracking",
            "reason": reason,
            "paddle_x": paddle_x,
            "ball_x": ball_x,
            "action": _ACTION_NAMES.get(action, action),
        }
        return action

    @staticmethod
    def _paddle_x(gray: np.ndarray) -> int:
        h, w = gray.shape
        band = gray[int(h * 0.86) :, :]
        score = (band > 40).sum(axis=0)
        if score.max() < 2:
            return w // 2
        return int(score.argmax())

    @staticmethod
    def _ball_x(gray: np.ndarray) -> int | None:
        h, w = gray.shape
        # Zona de juego (debajo de ladrillos, encima de la paleta)
        zone = gray[int(h * 0.32) : int(h * 0.84), :]
        bright = zone > 180
        if not bright.any():
            return None
        ys, xs = np.where(bright)
        # La pelota es un cuadrado pequeño; los ladrillos llenan muchas columnas
        if len(xs) > 80:
            lower = ys > zone.shape[0] // 3
            if lower.any():
                xs = xs[lower]
            else:
                return None
        return int(np.median(xs))


class HeuristicTetrisAgent:
    """Mueve, rota y baja piezas de forma simple."""

    name = "heuristic"

    _TETRIS_ACTIONS = {0: "NOOP", 1: "ROTATE", 2: "DROP", 3: "RIGHT", 4: "LEFT"}

    def __init__(self) -> None:
        self.step = 0
        self.last_decision: dict = {}

    def reset(self) -> None:
        self.step = 0
        self.last_decision = {}

    def act(self, observation, env) -> int:
        self.step += 1
        # ALE Tetris: 0=NOOP, 1=ROTATE, 2=DROP, 3=RIGHT, 4=LEFT
        if self.step < 8:
            action, reason, phase = 1, "New piece — rotating to a scouted orientation", "rotate"
        else:
            cycle = self.step % 14
            if cycle in (0, 1):
                action, reason, phase = 4, "Sliding piece left along the fixed cycle", "slide_left"
            elif cycle in (2, 3):
                action, reason, phase = 3, "Sliding piece right along the fixed cycle", "slide_right"
            elif cycle == 7:
                action, reason, phase = 1, "Mid-cycle rotation", "rotate"
            elif cycle == 11:
                action, reason, phase = 2, "Dropping piece", "drop"
            else:
                action, reason, phase = 0, "Holding — waiting for next cycle step", "hold"
        self.last_decision = {
            "phase": phase,
            "reason": reason,
            "action": self._TETRIS_ACTIONS.get(action, action),
        }
        return action


AGENTS: dict[str, type] = {
    "random": RandomAgent,
    "heuristic": HeuristicBreakoutAgent,
}

HEURISTIC_BY_GAME: dict[str, type] = {
    "breakout": HeuristicBreakoutAgent,
    "tetris": HeuristicTetrisAgent,
}


def make_agent(level: str, game: str = "breakout") -> Agent:
    if level == "heuristic":
        cls = HEURISTIC_BY_GAME.get(game, HeuristicBreakoutAgent)
        return cls()
    cls = AGENTS.get(level)
    if cls is None:
        raise ValueError(f"Nivel desconocido: {level!r}. Usa: random, heuristic")
    return cls()
