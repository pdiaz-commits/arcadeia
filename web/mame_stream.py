"""Live MAME gameplay streaming for hosted cabinet games.

Runs MAME headless on Xvfb with a real Lua AI agent, captures the framebuffer
with a persistent ffmpeg x11grab process, and yields JPEG frames for the
browser WebSocket — same contract as `web.game_stream.run_live_session`.
"""

from __future__ import annotations

import asyncio
import base64
import os
import shutil
import signal
import subprocess
import tempfile
import threading
import time
from pathlib import Path
from typing import Any, AsyncIterator

from arcade_ai.envs.ale_env import load_games_config
from arcade_ai.envs.mame_env import resolve_mame_binary
from arcade_ai.envs.mame_launch import extend_mame_cmd

ROOT = Path(__file__).resolve().parent.parent
LUA_DIR = ROOT / "scripts" / "mame"
ROMS_DIR = ROOT / "roms"
SYSTEM_MAME_ROMS = Path("/usr/share/games/mame/roms")
CFG_DIR = ROOT / "cfg"
RUNTIME_LUA = LUA_DIR / ".runtime_ai.lua"

MAX_CONCURRENT_MAME_SESSIONS = 1
_mame_semaphore = asyncio.Semaphore(MAX_CONCURRENT_MAME_SESSIONS)
MAME_SESSION_TIMEOUT_S = int(os.environ.get("ARCADEIA_MAME_SESSION_TIMEOUT", "1200"))
MAME_BUSY_MESSAGE = (
    "Hay muchas peticiones ahora. Prueba más tarde."
)
MAME_TIMEOUT_MESSAGE = (
    "Tiempo máximo de sesión alcanzado (20 minutos). La partida ha finalizado."
)


def mame_session_busy() -> bool:
    """True when the single MAME slot is already taken."""
    return _mame_semaphore.locked()


async def _try_acquire_mame_slot() -> bool:
    # Non-blocking acquire: wait_for(..., timeout=0) always times out because
    # Semaphore.acquire() needs at least one event-loop tick even when free.
    if _mame_semaphore.locked():
        return False
    await _mame_semaphore.acquire()
    return True

# Native-ish arcade resolution (336×240); override per game in games.yaml.
MAME_WIDTH = int(os.environ.get("ARCADEIA_MAME_WIDTH", "336"))
MAME_HEIGHT = int(os.environ.get("ARCADEIA_MAME_HEIGHT", "240"))
STREAM_WIDTH = int(os.environ.get("ARCADEIA_MAME_STREAM_WIDTH", str(MAME_WIDTH)))
STREAM_HEIGHT = int(os.environ.get("ARCADEIA_MAME_STREAM_HEIGHT", str(MAME_HEIGHT)))
MAME_GRAB_FPS = int(os.environ.get("ARCADEIA_MAME_GRAB_FPS", "30"))
MAME_JPEG_QUALITY = int(os.environ.get("ARCADEIA_MAME_JPEG_Q", "22"))
MAME_BOOT_WAIT_S = float(os.environ.get("ARCADEIA_MAME_BOOT_WAIT", "5.0"))
MAME_FRAMESKIP = int(os.environ.get("ARCADEIA_MAME_FRAMESKIP", "2"))
MAME_AUTOFRAMESKIP = os.environ.get("ARCADEIA_MAME_AUTOFRAMESKIP", "1").lower() in (
    "1",
    "true",
    "yes",
)
MIN_JPEG_BYTES = 400
# Solid-black X11 grabs compress to ~3.8 KB; real frames are much larger.
MIN_VISIBLE_JPEG_BYTES = int(os.environ.get("ARCADEIA_MAME_MIN_VISIBLE_JPEG", "4000"))
MAME_VISIBLE_WAIT_S = float(os.environ.get("ARCADEIA_MAME_VISIBLE_WAIT", "35.0"))
MAX_FRAMES = 5400  # ~7.5 min at 12 fps safety cap

MAME_LIVE_ENABLED = os.environ.get("ARCADEIA_MAME_LIVE", "").lower() in ("1", "true", "yes")
MAME_AUDIO_ENABLED = os.environ.get("ARCADEIA_MAME_AUDIO", "0").lower() in ("1", "true", "yes")
AUDIO_SAMPLE_RATE = int(os.environ.get("ARCADEIA_MAME_AUDIO_RATE", "48000"))
PULSE_SINK_NAME = "arcadeia_mame"

# ROMs known broken on MAME verifyroms (skip live, keep educational snaps if any).
_ROM_VERIFY_CACHE: dict[str, bool] = {}
_HOSTED_MAME_LIVE_CACHE: dict[str, dict[str, Any]] | None = None


def mame_live_enabled() -> bool:
    return (
        MAME_LIVE_ENABLED
        and not mame_prefer_snaps()
        and resolve_mame_binary() is not None
        and shutil.which("ffmpeg") is not None
        and shutil.which("Xvfb") is not None
    )


def mame_prefer_snaps() -> bool:
    """When true, catalogue uses pre-recorded MAME snaps instead of live streaming."""
    return os.environ.get("ARCADEIA_MAME_PREFER_SNAPS", "0").lower() in (
        "1",
        "true",
        "yes",
    )


def _session_geometry(entry: dict[str, Any]) -> tuple[int, int]:
    """Per-game window size (native resolution when set in games.yaml)."""
    w = int(entry.get("mame_width") or entry.get("width") or MAME_WIDTH)
    h = int(entry.get("mame_height") or entry.get("height") or MAME_HEIGHT)
    return w, h


def _kill_stale_mame_processes() -> None:
    """Remove orphaned MAME/Xvfb/ffmpeg from aborted streams."""
    rom_marker = str(ROMS_DIR)
    for pattern in (
        f"mame.*-rompath.*{rom_marker}",
        "ffmpeg.*x11grab",
        "Xvfb :",
    ):
        try:
            subprocess.run(
                ["pkill", "-9", "-f", pattern],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=3,
            )
        except (OSError, subprocess.TimeoutExpired):
            pass


def _lua_for_game(game_key: str, game_id: str) -> Path | None:
    cfg = load_games_config().get("mame_games", {})
    entry = cfg.get(game_key) or cfg.get(game_id, {})
    name = entry.get("ai_script")
    if name:
        path = LUA_DIR / name
        if path.is_file():
            return path
    for key in (game_key, game_id):
        fallback = LUA_DIR / f"{key}_ai.lua"
        if fallback.is_file():
            return fallback
    legacy = {
        "tehkan_world_cup": LUA_DIR / "tehkanwc_ai.lua",
        "wonder_boy": LUA_DIR / "wboy_ai.lua",
    }
    return legacy.get(game_key) or legacy.get(game_id)


def patch_lua_agent(lua_path: Path, agent: str, root: Path | None = None) -> Path:
    root_str = str(root or ROOT)
    patched: list[str] = []
    for line in lua_path.read_text(encoding="utf-8").splitlines():
        if line.startswith('local AGENT = "'):
            patched.append(f'local AGENT = "{agent}"')
        elif line.startswith('local ROOT = "'):
            patched.append(f'local ROOT = "{root_str}"')
        else:
            patched.append(line)
    RUNTIME_LUA.write_text("\n".join(patched) + "\n", encoding="utf-8")
    return RUNTIME_LUA


def _mame_rompath() -> str:
    paths = [str(ROMS_DIR)]
    if SYSTEM_MAME_ROMS.is_dir():
        paths.append(str(SYSTEM_MAME_ROMS))
    return ";".join(paths)


def _rom_verify_output(game_id: str) -> str:
    mame_bin = resolve_mame_binary()
    if not mame_bin:
        return ""
    try:
        out = subprocess.run(
            [mame_bin, "-rompath", _mame_rompath(), "-verifyroms", game_id],
            capture_output=True,
            text=True,
            timeout=30,
        )
        return out.stdout + out.stderr
    except (OSError, subprocess.TimeoutExpired):
        return ""


def mame_rom_issue(game_id: str) -> str | None:
    """Human-readable missing-ROM line from `mame -verifyroms`, or None if OK."""
    if _rom_verified(game_id):
        return None
    text = _rom_verify_output(game_id)
    for line in text.splitlines():
        if "NOT FOUND" in line:
            return line.strip()
    if f"romset {game_id} is bad" in text:
        return f"romset {game_id} is bad"
    return "ROM verification failed"


def _rom_verified(game_id: str) -> bool:
    if game_id in _ROM_VERIFY_CACHE:
        return _ROM_VERIFY_CACHE[game_id]
    text = _rom_verify_output(game_id)
    if not text:
        _ROM_VERIFY_CACHE[game_id] = False
        return False
    ok = f"romset {game_id}" in text and " is good" in text
    if not ok and game_id == "gngb":
        ok = "romset gngb [gng] is good" in text
    if not ok and " is good" in text and game_id in text:
        ok = True
    _ROM_VERIFY_CACHE[game_id] = ok
    return ok


def hosted_mame_live_games() -> dict[str, dict[str, Any]]:
    global _HOSTED_MAME_LIVE_CACHE
    if _HOSTED_MAME_LIVE_CACHE is not None:
        return _HOSTED_MAME_LIVE_CACHE
    if not mame_live_enabled():
        _HOSTED_MAME_LIVE_CACHE = {}
        return _HOSTED_MAME_LIVE_CACHE
    cfg = load_games_config()
    mame = cfg.get("mame_games", {})
    roms_present = {p.name for p in ROMS_DIR.glob("*.zip")} if ROMS_DIR.is_dir() else set()
    out: dict[str, dict[str, Any]] = {}
    for key, entry in mame.items():
        rom_file = entry.get("rom", f"{entry['game_id']}.zip")
        game_id = entry["game_id"]
        if rom_file not in roms_present:
            continue
        if not _lua_for_game(key, game_id):
            continue
        if not _rom_verified(game_id):
            continue
        out[key] = entry
    _HOSTED_MAME_LIVE_CACHE = out
    return out


def invalidate_mame_live_cache() -> None:
    global _HOSTED_MAME_LIVE_CACHE
    _HOSTED_MAME_LIVE_CACHE = None
    _ROM_VERIFY_CACHE.clear()


def _start_ffmpeg_grabber(display: int, dest_jpg: Path, env: dict[str, str]) -> subprocess.Popen:
    """Legacy file-based grabber (kept for snap tooling)."""
    return subprocess.Popen(
        [
            "ffmpeg",
            "-nostdin",
            "-loglevel",
            "error",
            "-f",
            "x11grab",
            "-draw_mouse",
            "0",
            "-framerate",
            str(MAME_GRAB_FPS),
            "-video_size",
            f"{MAME_WIDTH}x{MAME_HEIGHT}",
            "-i",
            f":{display}",
            "-vf",
            f"scale={STREAM_WIDTH}:{STREAM_HEIGHT}",
            "-update",
            "1",
            "-q:v",
            str(MAME_JPEG_QUALITY),
            str(dest_jpg),
        ],
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


class _LatestJpeg:
    """Thread-safe slot for the most recent JPEG from the ffmpeg pipe."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._data: bytes | None = None
        self._seq = 0
        self._ready = threading.Event()

    def set(self, data: bytes) -> None:
        with self._lock:
            self._data = data
            self._seq += 1
        self._ready.set()

    def get(self) -> bytes | None:
        with self._lock:
            return self._data

    def get_seq(self) -> tuple[bytes | None, int]:
        with self._lock:
            return self._data, self._seq

    async def wait_next(self, last_seq: int, timeout_s: float = 0.25) -> tuple[bytes | None, int]:
        """Wait until the pipe delivers a frame newer than last_seq."""
        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline:
            data, seq = self.get_seq()
            if data and seq != last_seq:
                return data, seq
            await asyncio.sleep(0.001)
        return self.get_seq()

    def wait_visible(self, timeout_s: float, min_bytes: int) -> bytes | None:
        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline:
            data = self.get()
            if data and len(data) >= min_bytes:
                return data
            time.sleep(0.04)
        return None


def _jpeg_pipe_reader(proc: subprocess.Popen, latest: _LatestJpeg) -> None:
    assert proc.stdout is not None
    buf = bytearray()
    try:
        while proc.poll() is None:
            chunk = proc.stdout.read(65536)
            if not chunk:
                break
            buf.extend(chunk)
            while True:
                start = buf.find(b"\xff\xd8")
                if start < 0:
                    if len(buf) > 1:
                        del buf[:-1]
                    break
                end = buf.find(b"\xff\xd9", start + 2)
                if end < 0:
                    if start > 0:
                        del buf[:start]
                    break
                frame = bytes(buf[start : end + 2])
                del buf[: end + 2]
                if len(frame) >= MIN_JPEG_BYTES:
                    latest.set(frame)
    except OSError:
        pass


def _start_ffmpeg_pipe_grabber(
    display: int,
    env: dict[str, str],
    width: int,
    height: int,
) -> subprocess.Popen:
    return subprocess.Popen(
        [
            "ffmpeg",
            "-nostdin",
            "-loglevel",
            "error",
            "-f",
            "x11grab",
            "-draw_mouse",
            "0",
            "-framerate",
            str(MAME_GRAB_FPS),
            "-video_size",
            f"{width}x{height}",
            "-i",
            f":{display}",
            "-c:v",
            "mjpeg",
            "-q:v",
            str(MAME_JPEG_QUALITY),
            "-f",
            "image2pipe",
            "pipe:1",
        ],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )


def _wait_for_jpeg(path: Path, timeout_s: float = 10.0, min_bytes: int = MIN_JPEG_BYTES) -> bool:
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        try:
            if path.is_file():
                sz = path.stat().st_size
                if sz >= min_bytes:
                    time.sleep(0.05)
                    if path.stat().st_size >= min_bytes:
                        return True
        except OSError:
            pass
        time.sleep(0.1)
    return False


def _read_grabbed_jpeg(path: Path) -> str | None:
    for _ in range(5):
        try:
            if not path.is_file():
                time.sleep(0.02)
                continue
            sz = path.stat().st_size
            if sz < MIN_JPEG_BYTES:
                time.sleep(0.02)
                continue
            data = path.read_bytes()
            if len(data) < MIN_JPEG_BYTES:
                time.sleep(0.02)
                continue
            return base64.b64encode(data).decode("ascii")
        except OSError:
            time.sleep(0.02)
    return None


def _capture_frame_jpeg(display: int, dest_jpg: Path, env: dict[str, str]) -> str | None:
    """Fallback one-shot grab (slow; used only if persistent grabber is unavailable)."""
    try:
        dest_jpg.unlink(missing_ok=True)
        result = subprocess.run(
            [
                "ffmpeg",
                "-y",
                "-nostdin",
                "-loglevel",
                "error",
                "-f",
                "x11grab",
                "-video_size",
                f"{MAME_WIDTH}x{MAME_HEIGHT}",
                "-i",
                f":{display}",
                "-frames:v",
                "1",
                "-update",
                "1",
                "-q:v",
                "7",
                str(dest_jpg),
            ],
            env=env,
            capture_output=True,
            timeout=10,
        )
        if result.returncode != 0 or not dest_jpg.is_file():
            return None
        data = dest_jpg.read_bytes()
        if len(data) < MIN_JPEG_BYTES:
            return None
        return base64.b64encode(data).decode("ascii")
    except (OSError, subprocess.TimeoutExpired):
        return None


def _find_free_display() -> int:
    for num in range(120, 200):
        lock = Path(f"/tmp/.X{num}-lock")
        if not lock.exists():
            return num
    return 199


def _setup_pulse_sink() -> int | None:
    """Create a PulseAudio null sink for MAME; returns module id or None."""
    if not MAME_AUDIO_ENABLED or not shutil.which("pactl"):
        return None
    try:
        subprocess.run(["pulseaudio", "--check"], capture_output=True, check=True, timeout=5)
    except (subprocess.CalledProcessError, FileNotFoundError, subprocess.TimeoutExpired):
        if not shutil.which("pulseaudio"):
            return None
        try:
            subprocess.Popen(
                ["pulseaudio", "--daemonize"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            time.sleep(0.6)
        except OSError:
            return None
    result = subprocess.run(
        [
            "pactl",
            "load-module",
            "module-null-sink",
            f"sink_name={PULSE_SINK_NAME}",
            "sink_properties=device.description=ArcadeiaMAME,buffer_length=16384",
        ],
        capture_output=True,
        text=True,
        timeout=10,
    )
    if result.returncode != 0:
        return None
    try:
        return int(result.stdout.strip())
    except ValueError:
        return None


def _teardown_pulse_sink(module_id: int | None) -> None:
    if module_id is None or not shutil.which("pactl"):
        return
    try:
        subprocess.run(["pactl", "unload-module", str(module_id)], capture_output=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        pass


def _start_audio_capture(env: dict[str, str]) -> subprocess.Popen | None:
    if not MAME_AUDIO_ENABLED or not shutil.which("ffmpeg"):
        return None
    sink_monitor = f"{PULSE_SINK_NAME}.monitor"
    try:
        return subprocess.Popen(
            [
                "ffmpeg",
                "-nostdin",
                "-loglevel",
                "error",
                "-f",
                "pulse",
                "-i",
                sink_monitor,
                "-ar",
                str(AUDIO_SAMPLE_RATE),
                "-ac",
                "1",
                "-f",
                "s16le",
                "pipe:1",
            ],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
    except OSError:
        return None


async def _drain_audio_queue(queue: asyncio.Queue[bytes | None], max_items: int = 2) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []
    while len(events) < max_items:
        try:
            chunk = queue.get_nowait()
        except asyncio.QueueEmpty:
            break
        if chunk is None:
            break
        if chunk:
            events.append(
                {
                    "type": "audio",
                    "pcm": base64.b64encode(chunk).decode("ascii"),
                    "rate": AUDIO_SAMPLE_RATE,
                    "channels": 1,
                }
            )
    # Drop backlog so audio never starves video.
    while True:
        try:
            extra = queue.get_nowait()
            if extra is None:
                break
        except asyncio.QueueEmpty:
            break
    return events


def _audio_reader_thread(
    proc: subprocess.Popen,
    queue: asyncio.Queue[bytes | None],
    loop: asyncio.AbstractEventLoop,
) -> None:
    def put_item(item: bytes | None) -> None:
        try:
            queue.put_nowait(item)
        except asyncio.QueueFull:
            pass

    try:
        assert proc.stdout is not None
        while proc.poll() is None:
            chunk = proc.stdout.read(4096)
            if not chunk:
                break
            loop.call_soon_threadsafe(put_item, chunk)
    except OSError:
        pass
    finally:
        loop.call_soon_threadsafe(put_item, None)


async def run_live_mame_session(
    game_key: str,
    agent: str,
    fps: float,
) -> AsyncIterator[dict[str, Any]]:
    """Async generator: MAME + Lua on Xvfb, ffmpeg grab → JPEG frames."""
    if not mame_live_enabled():
        yield {"type": "error", "message": "Live MAME is not enabled on this server."}
        return

    cfg = load_games_config().get("mame_games", {})
    if game_key not in cfg:
        yield {"type": "error", "message": f"Unknown MAME game: {game_key!r}"}
        return

    entry = cfg[game_key]
    game_id = entry["game_id"]
    session_w, session_h = _session_geometry(entry)
    rom_file = entry.get("rom", f"{game_id}.zip")
    if not (ROMS_DIR / rom_file).is_file():
        yield {"type": "error", "message": f"ROM missing on server: {rom_file}"}
        return

    lua_src = _lua_for_game(game_key, game_id)
    if not lua_src:
        yield {"type": "error", "message": f"No Lua agent for {game_key!r}"}
        return

    mame_bin = resolve_mame_binary()
    if not mame_bin:
        yield {"type": "error", "message": "MAME binary not found."}
        return

    await asyncio.to_thread(_kill_stale_mame_processes)

    if not await _try_acquire_mame_slot():
        yield {
            "type": "error",
            "code": "too_many_requests",
            "message": MAME_BUSY_MESSAGE,
        }
        return

    try:
        lua_tmp = patch_lua_agent(lua_src, agent, ROOT)
        display = _find_free_display()
        xvfb_proc: subprocess.Popen | None = None
        mame_proc: subprocess.Popen | None = None
        ffmpeg_proc: subprocess.Popen | None = None
        audio_proc: subprocess.Popen | None = None
        pulse_module: int | None = None
        audio_queue: asyncio.Queue[bytes | None] | None = None
        audio_thread = None
        jpeg_latest = _LatestJpeg()
        jpeg_thread: threading.Thread | None = None

        try:
            xvfb_proc = await asyncio.to_thread(
                subprocess.Popen,
                [
                    "Xvfb",
                    f":{display}",
                    "-screen",
                    "0",
                    f"{session_w}x{session_h}x24",
                    "-ac",
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            await asyncio.sleep(0.8)

            env = os.environ.copy()
            env["DISPLAY"] = f":{display}"
            pulse_module = await asyncio.to_thread(_setup_pulse_sink)
            audio_on = pulse_module is not None
            if audio_on:
                env["PULSE_SINK"] = PULSE_SINK_NAME

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
                "pulse" if audio_on else "none",
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
            if CFG_DIR.is_dir():
                mame_cmd.extend(["-cfg_directory", str(CFG_DIR)])
            mame_cmd = extend_mame_cmd(mame_cmd, profile="ai")

            mame_proc = await asyncio.to_thread(
                subprocess.Popen,
                mame_cmd,
                env=env,
                cwd=str(ROOT),
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                preexec_fn=os.setsid,
            )
            await asyncio.sleep(MAME_BOOT_WAIT_S)

            if mame_proc.poll() is not None:
                yield {
                    "type": "error",
                    "message": f"MAME exited immediately (code {mame_proc.returncode}). ROM may be invalid.",
                }
                return

            ffmpeg_proc = await asyncio.to_thread(
                _start_ffmpeg_pipe_grabber, display, env, session_w, session_h
            )
            jpeg_thread = threading.Thread(
                target=_jpeg_pipe_reader,
                args=(ffmpeg_proc, jpeg_latest),
                daemon=True,
            )
            jpeg_thread.start()

            if not await asyncio.to_thread(
                jpeg_latest.wait_visible, MAME_VISIBLE_WAIT_S, MIN_VISIBLE_JPEG_BYTES
            ):
                yield {"type": "error", "message": "Video capture failed to start (ffmpeg)."}
                return

            if audio_on:
                audio_proc = await asyncio.to_thread(_start_audio_capture, env)
                if audio_proc and audio_proc.stdout:
                    audio_queue = asyncio.Queue(maxsize=64)
                    loop = asyncio.get_running_loop()
                    audio_thread = threading.Thread(
                        target=_audio_reader_thread,
                        args=(audio_proc, audio_queue, loop),
                        daemon=True,
                    )
                    audio_thread.start()
                else:
                    audio_on = False

            yield {
                "type": "connected",
                "game": game_key,
                "agent": agent,
                "engine": "MAME",
                "mode": "live",
                "width": session_w,
                "height": session_h,
                "binaryFrames": True,
                "audio": audio_on,
                "sampleRate": AUDIO_SAMPLE_RATE if audio_on else None,
            }

            step = 0
            last_seq = 0
            session_start = time.monotonic()
            timed_out = False
            while step < MAX_FRAMES:
                if mame_proc.poll() is not None:
                    break
                if time.monotonic() - session_start >= MAME_SESSION_TIMEOUT_S:
                    timed_out = True
                    break

                jpeg, seq = jpeg_latest.get_seq()
                if jpeg and seq != last_seq and len(jpeg) >= MIN_VISIBLE_JPEG_BYTES:
                    last_seq = seq
                    step += 1
                    yield {
                        "type": "frame",
                        "jpeg": jpeg,
                        "episode": 1,
                        "step": step,
                        "reward": 0.0,
                    }

                if audio_queue is not None:
                    for audio_ev in await _drain_audio_queue(audio_queue, max_items=1):
                        yield audio_ev

            if timed_out:
                yield {
                    "type": "session_timeout",
                    "message": MAME_TIMEOUT_MESSAGE,
                    "max_minutes": MAME_SESSION_TIMEOUT_S // 60,
                    "steps": step,
                }
            else:
                yield {"type": "episode_end", "episode": 1, "steps": step, "total_reward": 0.0}

        finally:
            if audio_proc and audio_proc.poll() is None:
                audio_proc.terminate()
                try:
                    audio_proc.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    audio_proc.kill()
            if ffmpeg_proc and ffmpeg_proc.poll() is None:
                ffmpeg_proc.terminate()
                try:
                    ffmpeg_proc.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    ffmpeg_proc.kill()
            if mame_proc and mame_proc.poll() is None:
                try:
                    os.killpg(os.getpgid(mame_proc.pid), signal.SIGTERM)
                except (OSError, ProcessLookupError):
                    mame_proc.terminate()
                try:
                    await asyncio.wait_for(asyncio.to_thread(mame_proc.wait), timeout=5.0)
                except asyncio.TimeoutError:
                    try:
                        os.killpg(os.getpgid(mame_proc.pid), signal.SIGKILL)
                    except (OSError, ProcessLookupError):
                        mame_proc.kill()
            if xvfb_proc and xvfb_proc.poll() is None:
                xvfb_proc.terminate()
                try:
                    xvfb_proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    xvfb_proc.kill()
            if pulse_module is not None:
                await asyncio.to_thread(_teardown_pulse_sink, pulse_module)
    finally:
        _mame_semaphore.release()
