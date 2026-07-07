from __future__ import annotations

from pathlib import Path
from typing import Any

import gymnasium as gym
import yaml

_CONFIG = Path(__file__).resolve().parents[3] / "config" / "games.yaml"


def load_games_config() -> dict[str, Any]:
    with _CONFIG.open(encoding="utf-8") as f:
        return yaml.safe_load(f)


def list_ale_games() -> dict[str, dict[str, Any]]:
    return load_games_config().get("ale_games", {})


def resolve_env_id(game_key: str | None = None) -> str:
    cfg = load_games_config()
    key = game_key or cfg.get("default_game", "breakout")
    ale = cfg.get("ale_games", {})
    if key not in ale:
        available = ", ".join(sorted(ale))
        raise ValueError(f"Juego ALE desconocido: {key!r}. Disponibles: {available}")
    return ale[key]["env_id"]


def make_arcade_env(
    game_key: str | None = None,
    *,
    render_mode: str | None = None,
    frameskip: int = 4,
) -> gym.Env:
    """Crea entorno Gymnasium (ALE / Atari 2600)."""
    import ale_py  # noqa: F401 — registra envs

    gym.register_envs(ale_py)
    env_id = resolve_env_id(game_key)
    return gym.make(
        env_id,
        render_mode=render_mode,
        frameskip=frameskip,
        repeat_action_probability=0.0,
    )
