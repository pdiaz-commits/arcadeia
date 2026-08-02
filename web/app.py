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

import asyncio
import json
import queue
import threading
import os
import sys
from pathlib import Path
from typing import Any, Optional

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))

from fastapi import FastAPI, File, Header, HTTPException, UploadFile, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse, JSONResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles

from arcade_ai import __version__
from arcade_ai.envs.ale_env import load_games_config
from arcade_ai.envs.mame_env import mame_status

from web.game_stream import hosted_ale_games, run_live_session
from web.mame_stream import (
    MAME_SESSION_TIMEOUT_S,
    hosted_mame_live_games,
    invalidate_mame_live_cache,
    mame_live_enabled,
    mame_prefer_snaps,
    mame_rom_issue,
    mame_session_busy,
    run_live_mame_session,
    _kill_stale_mame_processes,
)
from web.i18n import LOCALES, get_locale

ROMS_DIR = ROOT / "roms"
LUA_DIR = ROOT / "scripts" / "mame"
SNAP_DIR = ROOT / "snap"
DEMOS_DIR = ROOT / "logs" / "demos"
ADMIN_TOKEN = os.environ.get("ARCADEIA_ADMIN_TOKEN", "")

MAX_UPLOAD_BYTES = 50 * 1024 * 1024  # 50 MB, matches mockup's stated limit

_enable_docs = os.environ.get("ENABLE_API_DOCS", "").strip().lower() in ("1", "true", "yes", "on")
app = FastAPI(
    title="Arcade AI",
    version=__version__,
    docs_url="/docs" if _enable_docs else None,
    redoc_url="/redoc" if _enable_docs else None,
    openapi_url="/openapi.json" if _enable_docs else None,
)


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
        "mame_live_enabled": mame_live_enabled(),
        "mame_prefer_snaps": mame_prefer_snaps(),
        "admin_enabled": bool(ADMIN_TOKEN),
        "hosted_ale_games": sorted(hosted_ale_games()),
        "hosted_mame_live_games": sorted(hosted_mame_live_games()),
        "max_concurrent_ai_sessions": 4,
        "max_concurrent_mame_sessions": 1,
        "mame_session_busy": mame_session_busy(),
        "mame_session_timeout_minutes": MAME_SESSION_TIMEOUT_S // 60,
    }


@app.get("/api/i18n/{lang}")
def api_i18n(lang: str) -> dict[str, Any]:
    return get_locale(lang)


@app.get("/api/languages")
def api_languages() -> list[str]:
    return sorted(LOCALES.keys())


def _mame_lua_path(game_key: str, entry: dict[str, Any]) -> Path | None:
    name = entry.get("ai_script")
    if name:
        path = LUA_DIR / name
        if path.is_file():
            return path
    for candidate in (f"{game_key}_ai.lua", f"{entry['game_id']}_ai.lua"):
        path = LUA_DIR / candidate
        if path.is_file():
            return path
    return None


def _mame_snaps(game_id: str) -> list[str]:
    snap_dir = SNAP_DIR / game_id
    if not snap_dir.is_dir():
        return []
    names = []
    for p in snap_dir.iterdir():
        if p.suffix.lower() in (".png", ".svg", ".jpg", ".jpeg"):
            names.append(p.name)
    return sorted(names)


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
                "play_mode": "ale_live",
            }
        )
    for key, entry in mame.items():
        rom_file = entry.get("rom", f"{entry['game_id']}.zip")
        game_id = entry["game_id"]
        has_rom = rom_file in roms_present
        has_lua = _mame_lua_path(key, entry) is not None
        snaps = _mame_snaps(game_id)
        can_live = (
            mame_live_enabled()
            and not mame_prefer_snaps()
            and has_rom
            and has_lua
            and key in hosted_mame_live_games()
        )
        can_educational = has_rom and has_lua and not can_live
        if can_live:
            play_mode = "mame_live"
            status = "ready_live"
            hosted = True
        elif can_educational:
            play_mode = "mame_educational"
            status = "ready_educational"
            hosted = True
        elif not has_rom:
            play_mode = None
            status = "needs_rom"
            hosted = False
        else:
            play_mode = None
            status = "needs_agent"
            hosted = False
        rows.append(
            {
                "key": key,
                "title": key.replace("_", " ").title(),
                "engine": "MAME",
                "year": entry.get("year"),
                "description": entry.get("description"),
                "agent": "heuristic" if has_lua else "—",
                "rom": rom_file,
                "status": status,
                "hosted": hosted,
                "play_mode": play_mode,
                "game_id": game_id,
                "snap_count": len(snaps),
            }
        )
    return {"games": rows}


@app.get("/api/mame/{game_key}/lua")
def api_mame_lua(game_key: str) -> dict[str, Any]:
    cfg = load_games_config()
    mame = cfg.get("mame_games", {})
    if game_key not in mame:
        raise HTTPException(404, f"Unknown MAME game: {game_key!r}")
    entry = mame[game_key]
    lua_path = _mame_lua_path(game_key, entry)
    if not lua_path:
        raise HTTPException(404, "No Lua AI script for this game.")
    return {"game": game_key, "filename": lua_path.name, "source": lua_path.read_text(encoding="utf-8")}


@app.get("/api/mame/{game_key}/snaps")
def api_mame_snaps(game_key: str) -> dict[str, Any]:
    cfg = load_games_config()
    mame = cfg.get("mame_games", {})
    if game_key not in mame:
        raise HTTPException(404, f"Unknown MAME game: {game_key!r}")
    game_id = mame[game_key]["game_id"]
    entry = mame[game_key]
    snaps = _mame_snaps(game_id)
    return {
        "game": game_key,
        "game_id": game_id,
        "snaps": [f"/snap/{game_id}/{name}" for name in snaps],
        "rom_ok": mame_rom_issue(game_id) is None,
        "rom_issue": mame_rom_issue(game_id),
        "description": entry.get("description"),
    }


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
    invalidate_mame_live_cache()
    return {"saved": name, "path": f"roms/{name}"}


@app.post("/api/admin/upload-lua")
async def api_upload_lua(
    file: UploadFile = File(...),
    x_admin_token: Optional[str] = Header(default=None),
) -> dict[str, Any]:
    _require_admin(x_admin_token)
    name = await _save_upload(LUA_DIR, file, ".lua")
    return {"saved": name, "path": f"scripts/mame/{name}"}


MJPEG_BOUNDARY = "arcadeia"


def _mjpeg_sync_iter(game: str, agent: str, fps: float):
    """Sync multipart iterator; MAME capture runs on a dedicated thread/event loop."""
    frame_q: queue.Queue[bytes | None] = queue.Queue(maxsize=32)

    def producer() -> None:
        async def pump() -> None:
            gen = run_live_mame_session(game, agent, fps)
            try:
                async for event in gen:
                    if event.get("type") == "frame" and "jpeg" in event:
                        jpeg = event["jpeg"]
                        while frame_q.full():
                            try:
                                frame_q.get_nowait()
                            except queue.Empty:
                                break
                        frame_q.put(jpeg)
                    elif event.get("type") == "error":
                        break
            finally:
                await gen.aclose()
                await asyncio.to_thread(_kill_stale_mame_processes)
                frame_q.put(None)

        asyncio.run(pump())

    threading.Thread(target=producer, daemon=True).start()
    while True:
        jpeg = frame_q.get()
        if jpeg is None:
            break
        header = (
            f"--{MJPEG_BOUNDARY}\r\n"
            f"Content-Type: image/jpeg\r\n"
            f"Content-Length: {len(jpeg)}\r\n\r\n"
        ).encode("ascii")
        yield header + jpeg + b"\r\n"
    yield f"--{MJPEG_BOUNDARY}--\r\n".encode("ascii")


async def _mjpeg_bytes(game: str, agent: str, fps: float):
    """Unused async wrapper — kept for tests; production uses _mjpeg_sync_iter."""
    for chunk in _mjpeg_sync_iter(game, agent, fps):
        yield chunk


@app.get("/api/mame/live.mjpg")
async def mame_live_mjpeg(
    game: str,
    agent: str = "heuristic",
    fps: float = 30.0,
) -> StreamingResponse:
    if game not in hosted_mame_live_games():
        raise HTTPException(status_code=404, detail=f"Game {game!r} is not hosted for live MAME.")
    fps = max(2.0, min(fps, 30.0))
    return StreamingResponse(
        _mjpeg_sync_iter(game, agent, fps),
        media_type=f"multipart/x-mixed-replace; boundary={MJPEG_BOUNDARY}",
        headers={
            "Cache-Control": "no-cache, no-store, must-revalidate",
            "Pragma": "no-cache",
            "X-Accel-Buffering": "no",
        },
    )


async def _relay_mame_ws(
    websocket: WebSocket,
    game: str,
    agent: str,
    fps: float,
) -> None:
    """Decouple MAME capture from WebSocket send so slow clients do not stall grabs."""
    outbound: asyncio.Queue[bytes | dict[str, Any] | None] = asyncio.Queue(maxsize=12)

    async def writer() -> None:
        while True:
            item = await outbound.get()
            if item is None:
                return
            if isinstance(item, (bytes, bytearray)):
                await websocket.send_bytes(item)
            else:
                await websocket.send_json(item)

    async def reader() -> None:
        try:
            async for event in run_live_mame_session(game, agent, fps):
                if event.get("type") == "frame" and "jpeg" in event:
                    jpeg = event["jpeg"]
                    backlog: list[bytes | dict[str, Any]] = []
                    while True:
                        try:
                            backlog.append(outbound.get_nowait())
                        except asyncio.QueueEmpty:
                            break
                    for item in backlog:
                        if not isinstance(item, (bytes, bytearray)):
                            await outbound.put(item)
                    try:
                        outbound.put_nowait(jpeg)
                    except asyncio.QueueFull:
                        pass
                else:
                    await outbound.put(event)
        finally:
            await outbound.put(None)

    writer_task = asyncio.create_task(writer())
    try:
        await reader()
    finally:
        await outbound.put(None)
        await writer_task


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

    if game in hosted_mame_live_games():
        try:
            await _relay_mame_ws(websocket, game, agent, fps)
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
        return

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
DOSSIER_DIR = Path(__file__).resolve().parent.parent / "dossier"
app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")
if SNAP_DIR.is_dir():
    app.mount("/snap", StaticFiles(directory=str(SNAP_DIR)), name="snap")
if DOSSIER_DIR.is_dir():
    app.mount("/dossier", StaticFiles(directory=str(DOSSIER_DIR), html=True), name="dossier")


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
