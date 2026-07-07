#!/usr/bin/env python3
"""Arcade AI — production web app.

Real, working FastAPI app implementing a working subset of the
`arcade-ai-web-mockup` Canvas design: game catalog, live "AI plays now"
streaming (real Gymnasium/ALE + heuristic agents, not simulated), a
"how does the AI decide?" panel fed by the agent's real decision trace,
a read-only "Teach" view over real recorded demo sessions, and an Admin
upload panel for ROMs / Lua AI scripts. See README.md for exactly what is
real vs. simulated in this deployment.

Run with:
    uvicorn web.app:app --host 0.0.0.0 --port 8014
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import Any, Optional

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))

from fastapi import FastAPI, File, Header, HTTPException, UploadFile, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles

from arcade_ai import __version__
from arcade_ai.envs.ale_env import load_games_config
from arcade_ai.envs.mame_env import mame_status

from web.game_stream import hosted_ale_games, run_live_session
from web.i18n import LOCALES, get_locale

ROMS_DIR = ROOT / "roms"
LUA_DIR = ROOT / "scripts" / "mame"
DEMOS_DIR = ROOT / "logs" / "demos"
ADMIN_TOKEN = os.environ.get("ARCADEIA_ADMIN_TOKEN", "")

MAX_UPLOAD_BYTES = 50 * 1024 * 1024  # 50 MB, matches mockup's stated limit

app = FastAPI(title="Arcade AI", version=__version__)


def _require_admin(x_admin_token: Optional[str]) -> None:
    if not ADMIN_TOKEN:
        raise HTTPException(503, "Admin uploads disabled: ARCADEIA_ADMIN_TOKEN is not configured on the server.")
    if not x_admin_token or x_admin_token != ADMIN_TOKEN:
        raise HTTPException(401, "Invalid or missing admin token.")


@app.get("/api/status")
def api_status() -> dict[str, Any]:
    ms = mame_status()
    return {
        "version": __version__,
        "mame": ms,
        "admin_enabled": bool(ADMIN_TOKEN),
        "hosted_ale_games": sorted(hosted_ale_games()),
        "max_concurrent_ai_sessions": 4,
    }


@app.get("/api/i18n/{lang}")
def api_i18n(lang: str) -> dict[str, Any]:
    return get_locale(lang)


@app.get("/api/languages")
def api_languages() -> list[str]:
    return sorted(LOCALES.keys())


@app.get("/api/games")
def api_games() -> dict[str, Any]:
    cfg = load_games_config()
    ale = cfg.get("ale_games", {})
    mame = cfg.get("mame_games", {})
    roms_present = {p.name for p in ROMS_DIR.glob("*.zip")} if ROMS_DIR.is_dir() else set()

    rows = []
    for key, entry in ale.items():
        rows.append(
            {
                "key": key,
                "title": key.replace("_", " ").title(),
                "engine": "ALE",
                "year": entry.get("year"),
                "description": entry.get("description"),
                "agent": "heuristic" if key in ("breakout", "tetris") else "random",
                "rom": "bundled (Atari 2600, ALE)",
                "status": "ready",
                "hosted": True,
            }
        )
    for key, entry in mame.items():
        rom_file = entry.get("rom", f"{entry['game_id']}.zip")
        has_rom = rom_file in roms_present
        rows.append(
            {
                "key": key,
                "title": key.replace("_", " ").title(),
                "engine": "MAME",
                "year": entry.get("year"),
                "description": entry.get("description"),
                "agent": "heuristic" if entry.get("ai_script") else "—",
                "rom": rom_file,
                "status": "ready" if has_rom else "needs_rom",
                "hosted": False,
            }
        )
    return {"games": rows}


@app.get("/api/teach/sessions")
def api_teach_sessions() -> dict[str, Any]:
    if not DEMOS_DIR.is_dir():
        return {"sessions": []}
    sessions = []
    for path in sorted(DEMOS_DIR.glob("session_*.jsonl")):
        markers = 0
        goals = 0
        last_frame = -1
        try:
            for line in path.read_text(encoding="utf-8").splitlines():
                if not line.strip():
                    continue
                entry = json.loads(line)
                markers += 1
                if entry.get("kind") == "goal":
                    goals += 1
                last_frame = max(last_frame, entry.get("frame", -1))
        except (OSError, json.JSONDecodeError):
            continue
        sessions.append(
            {
                "name": path.stem,
                "markers": markers,
                "goals": goals,
                "last_frame": last_frame,
            }
        )
    return {"sessions": sessions}


@app.get("/api/admin/files")
def api_admin_files(x_admin_token: Optional[str] = Header(default=None)) -> dict[str, Any]:
    _require_admin(x_admin_token)
    roms = sorted(p.name for p in ROMS_DIR.glob("*.zip")) if ROMS_DIR.is_dir() else []
    lua = sorted(p.name for p in LUA_DIR.glob("*.lua")) if LUA_DIR.is_dir() else []
    return {"roms": roms, "lua": lua}


async def _save_upload(dest_dir: Path, upload: UploadFile, allowed_suffix: str) -> str:
    name = Path(upload.filename or "").name
    if not name or not name.lower().endswith(allowed_suffix):
        raise HTTPException(400, f"File must have a {allowed_suffix!r} extension.")
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = dest_dir / name
    size = 0
    with dest.open("wb") as out:
        while chunk := await upload.read(1024 * 1024):
            size += len(chunk)
            if size > MAX_UPLOAD_BYTES:
                out.close()
                dest.unlink(missing_ok=True)
                raise HTTPException(413, "File too large (max 50 MB).")
            out.write(chunk)
    return name


@app.post("/api/admin/upload-rom")
async def api_upload_rom(
    file: UploadFile = File(...),
    x_admin_token: Optional[str] = Header(default=None),
) -> dict[str, Any]:
    _require_admin(x_admin_token)
    name = await _save_upload(ROMS_DIR, file, ".zip")
    return {"saved": name, "path": f"roms/{name}"}


@app.post("/api/admin/upload-lua")
async def api_upload_lua(
    file: UploadFile = File(...),
    x_admin_token: Optional[str] = Header(default=None),
) -> dict[str, Any]:
    _require_admin(x_admin_token)
    name = await _save_upload(LUA_DIR, file, ".lua")
    return {"saved": name, "path": f"scripts/mame/{name}"}


@app.websocket("/ws/play")
async def ws_play(websocket: WebSocket) -> None:
    await websocket.accept()
    params = websocket.query_params
    game = params.get("game", "breakout")
    agent = params.get("agent", "heuristic")
    try:
        fps = float(params.get("fps", "20"))
    except ValueError:
        fps = 20.0
    fps = max(2.0, min(fps, 30.0))
    seed = 42

    if game not in hosted_ale_games():
        await websocket.send_json(
            {"type": "error", "message": f"Game {game!r} is not hosted for live AI play on this server."}
        )
        await websocket.close()
        return

    try:
        async for event in run_live_session(game, agent, fps, seed):
            await websocket.send_json(event)
    except WebSocketDisconnect:
        pass
    except Exception as exc:  # noqa: BLE001
        try:
            await websocket.send_json({"type": "error", "message": str(exc)})
        except Exception:
            pass
    finally:
        try:
            await websocket.close()
        except Exception:
            pass


STATIC_DIR = Path(__file__).resolve().parent / "static"
app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")


@app.get("/")
def index() -> FileResponse:
    return FileResponse(str(STATIC_DIR / "index.html"))


@app.get("/play")
def play() -> FileResponse:
    """Dedicated, larger gameplay view (opened in a new window from the
    landing cabinet). Reads ?game=&agent=&mode=&lang= on the client and either
    streams a hosted ALE game over /ws/play or shows a clean 'not available on
    this hosted server' panel for MAME games — never a stuck spinner."""
    return FileResponse(str(STATIC_DIR / "play.html"))


@app.get("/healthz")
def healthz() -> JSONResponse:
    return JSONResponse({"ok": True, "version": __version__})


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="127.0.0.1", port=8014)
