#!/usr/bin/env python3
"""Capture PNG snaps from MAME for educational demos (games with verified ROMs).

Usage (on server with Xvfb, ffmpeg, mame):
  cd /var/www/arcadeia && .venv/bin/python scripts/generate_mame_snaps.py atetris wonder_boy
"""

from __future__ import annotations

import os
import signal
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "src"))

from arcade_ai.envs.ale_env import load_games_config  # noqa: E402
from arcade_ai.envs.mame_env import resolve_mame_binary  # noqa: E402
from web.mame_stream import (  # noqa: E402
    MAME_AUTOFRAMESKIP,
    MAME_BOOT_WAIT_S,
    MAME_FRAMESKIP,
    MAME_HEIGHT,
    MAME_WIDTH,
    _find_free_display,
    _kill_stale_mame_processes,
    _lua_for_game,
    _mame_rompath,
    _rom_verified,
    _session_geometry,
    patch_lua_agent,
)

SNAP_DIR = ROOT / "snap"
FRAMES = int(os.environ.get("ARCADEIA_SNAP_FRAMES", "24"))
INTERVAL_S = float(os.environ.get("ARCADEIA_SNAP_INTERVAL", "0.8"))
MIN_VISIBLE_PNG = 1500


def _capture_png(display: int, dest: Path, width: int, height: int, env: dict[str, str]) -> bool:
    dest.unlink(missing_ok=True)
    r = subprocess.run(
        [
            "ffmpeg",
            "-y",
            "-nostdin",
            "-loglevel",
            "error",
            "-f",
            "x11grab",
            "-draw_mouse",
            "0",
            "-video_size",
            f"{width}x{height}",
            "-i",
            f":{display}",
            "-frames:v",
            "1",
            str(dest),
        ],
        env=env,
        capture_output=True,
        timeout=15,
    )
    return r.returncode == 0 and dest.is_file() and dest.stat().st_size >= MIN_VISIBLE_PNG


def generate(game_key: str, game_id: str | None = None) -> int:
    game_id = game_id or game_key
    if not _rom_verified(game_id):
        print(f"SKIP {game_id}: ROM not verified")
        return 0

    cfg = load_games_config().get("mame_games", {})
    entry = cfg.get(game_key) or cfg.get(game_id, {})
    session_w, session_h = _session_geometry(entry) if entry else (MAME_WIDTH, MAME_HEIGHT)

    lua = _lua_for_game(game_key, game_id)
    if not lua:
        print(f"SKIP {game_id}: no Lua script")
        return 0

    mame_bin = resolve_mame_binary()
    if not mame_bin:
        print("MAME binary not found")
        return 0

    _kill_stale_mame_processes()
    out_dir = SNAP_DIR / game_id
    out_dir.mkdir(parents=True, exist_ok=True)
    lua_tmp = patch_lua_agent(lua, "heuristic", ROOT)
    display = _find_free_display()
    xvfb = subprocess.Popen(
        ["Xvfb", f":{display}", "-screen", "0", f"{session_w}x{session_h}x24", "-ac"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    time.sleep(0.8)
    env = os.environ.copy()
    env["DISPLAY"] = f":{display}"
    mame_cmd = [
        mame_bin,
        game_id,
        "-rompath",
        _mame_rompath(),
        "-autoboot_script",
        str(lua_tmp),
        "-autoboot_delay",
        "1",
        "-window",
        "-sound",
        "none",
        "-nomaximize",
        "-skip_gameinfo",
        "-video",
        "soft",
        "-resolution",
        f"{session_w}x{session_h}",
        "-keepaspect",
        "-nothrottle",
        "-frameskip",
        str(MAME_FRAMESKIP),
    ]
    if MAME_AUTOFRAMESKIP:
        mame_cmd.append("-autoframeskip")
    mame = subprocess.Popen(
        mame_cmd,
        env=env,
        cwd=str(ROOT),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        preexec_fn=os.setsid,
    )
    time.sleep(MAME_BOOT_WAIT_S + 8)
    saved = 0
    try:
        for i in range(FRAMES):
            if mame.poll() is not None:
                break
            dest = out_dir / f"{i:04d}.png"
            if _capture_png(display, dest, session_w, session_h, env):
                saved += 1
                print(f"  saved {dest.name} ({dest.stat().st_size} bytes)")
            time.sleep(INTERVAL_S)
    finally:
        if mame.poll() is None:
            try:
                os.killpg(os.getpgid(mame.pid), signal.SIGKILL)
            except OSError:
                mame.kill()
            try:
                mame.wait(timeout=2)
            except subprocess.TimeoutExpired:
                pass
        xvfb.terminate()
        xvfb.wait(timeout=3)
    print(f"{game_id}: {saved} snaps")
    return saved


def main() -> None:
    cfg = load_games_config().get("mame_games", {})
    targets = sys.argv[1:] or [
        k for k, e in cfg.items() if _rom_verified(e["game_id"])
    ]
    total = 0
    for key in targets:
        entry = cfg.get(key)
        gid = entry["game_id"] if entry else key
        print(f"=== {key} ({gid}) ===")
        total += generate(key, gid)
    print(f"Done: {total} snaps total")


if __name__ == "__main__":
    main()
