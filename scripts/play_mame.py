#!/usr/bin/env python3
"""Lanza MAME con agente IA (script Lua) para juegos arcade."""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

from arcade_ai.envs.ale_env import load_games_config
from arcade_ai.envs.mame_env import resolve_mame_binary
from arcade_ai.envs.mame_launch import extend_mame_cmd, mame_env

MAME_DIR = ROOT / "scripts" / "mame"


def _lua_for_game(game_key: str, game_id: str) -> Path | None:
    cfg = load_games_config().get("mame_games", {})
    entry = cfg.get(game_key) or cfg.get(game_id, {})
    name = entry.get("ai_script")
    if name:
        path = MAME_DIR / name
        if path.is_file():
            return path
    for key in (game_key, game_id):
        fallback = MAME_DIR / f"{key}_ai.lua"
        if fallback.is_file():
            return fallback
    legacy = {
        "tecmo_world_cup": MAME_DIR / "twcup90_ai.lua",
        "twcup90": MAME_DIR / "twcup90_ai.lua",
        "tehkan_world_cup": MAME_DIR / "tehkanwc_ai.lua",
        "tehkanwc": MAME_DIR / "tehkanwc_ai.lua",
        "wonder_boy": MAME_DIR / "wboy_ai.lua",
        "wboy": MAME_DIR / "wboy_ai.lua",
    }
    return legacy.get(game_key) or legacy.get(game_id)


def resolve_mame_game(game_key: str) -> tuple[str, str]:
    cfg = load_games_config()
    mame = cfg.get("mame_games", {})
    if game_key not in mame:
        raise ValueError(
            f"Juego MAME no configurado: {game_key!r}. "
            f"Disponibles: {', '.join(sorted(mame))}"
        )
    entry = mame[game_key]
    return entry["game_id"], entry.get("rom", f"{entry['game_id']}.zip")


RUNTIME_LUA = ROOT / "scripts" / "mame" / ".runtime_ai.lua"


def patch_lua_agent(lua_path: Path, agent: str) -> Path:
    text = lua_path.read_text(encoding="utf-8")
    patched = []
    for line in text.splitlines():
        if line.startswith('local ROOT = "'):
            patched.append(f'local ROOT = "{ROOT}"')
        elif line.startswith('local AGENT = "'):
            patched.append(f'local AGENT = "{agent}"')
        else:
            patched.append(line)
    RUNTIME_LUA.write_text("\n".join(patched) + "\n", encoding="utf-8")
    return RUNTIME_LUA


def main() -> None:
    parser = argparse.ArgumentParser(description="Arcade AI — MAME con agente")
    parser.add_argument("--game", default="tehkan_world_cup")
    parser.add_argument(
        "--agent",
        default="heuristic",
        choices=["random", "heuristic", "human_record"],
        help="Agente IA: heuristic (reglas), random, o human_record (graba humano a CSV)",
    )
    parser.add_argument("--render", action="store_true", help="Ventana gráfica")
    parser.add_argument(
        "--mouse",
        action="store_true",
        help="Ratón como trackball (solo enseñanza humana; desactiva la IA Lua)",
    )
    parser.add_argument(
        "--plugins",
        default="ai",
        choices=["ai", "manual", "teach", "debug", "none"],
        help="Perfil de plugins MAME (autofire/hiscore/console…)",
    )
    args = parser.parse_args()

    game_id, rom_file = resolve_mame_game(args.game)
    rom_path = ROOT / "roms" / rom_file
    if not rom_path.is_file():
        print(f"Falta ROM: {rom_path}")
        sys.exit(1)

    lua_src = _lua_for_game(args.game, game_id)
    if not lua_src or not lua_src.is_file():
        print(f"No hay script IA para {args.game!r} todavía.")
        sys.exit(1)

    lua_tmp = patch_lua_agent(lua_src, args.agent)
    mame_bin = resolve_mame_binary()
    if not mame_bin:
        print("MAME no encontrado. Ejecuta: ./scripts/install_mame.sh")
        sys.exit(1)

    env = mame_env()
    cfg_dir = ROOT / "cfg"
    cmd = [
        mame_bin,
        game_id,
        "-rompath",
        str(ROOT / "roms"),
        "-autoboot_script",
        str(lua_tmp),
        "-autoboot_delay",
        "2",
    ]
    if args.plugins != "none":
        cmd = extend_mame_cmd(cmd, profile=args.plugins)
    elif cfg_dir.is_dir():
        cmd.extend(["-cfg_directory", str(cfg_dir)])
    # Wonder Boy mappings now live in cfg/wboy.cfg (auto-load).
    # See cfg/wboy.cfg <input> block — X=jump, Z=shoot, arrows.
    # Legacy cfg/wboy_mac.cfg stays on disk as historical reference only
    # (do NOT load via -ctrlr: it overrides the project's WBoy mapping).
    trackball_games = {"tehkanwc", "tehkan_world_cup"}
    if args.mouse and (game_id in trackball_games or args.game in trackball_games):
        cmd.append("-mouse")
    if args.render:
        cmd.append("-window")
    else:
        cmd.append("-nowindow")

    print(f"MAME IA → {game_id} | agente: {args.agent} | plugins: {args.plugins}")
    print("Cierra la ventana o pulsa ESC en MAME para salir.")
    result = subprocess.run(cmd, env=env, cwd=str(ROOT), check=False)
    if result.returncode != 0:
        print(f"MAME terminó con código {result.returncode}")


if __name__ == "__main__":
    main()
