#!/usr/bin/env python3
"""Generic attract-mode recorder launcher.

Usage:
    scripts/teach_attract.py <game_key> [--seconds 60] [--no-window] [--keep-config]

Reads ``config/games.yaml`` + ``config/attract_recording/<game_id>.yaml``,
generates a per-game Lua companion config at
``scripts/mame/.teach_attract_<game_id>.lua``, spawns MAME with the
GENERIC recorder ``scripts/mame/teach_attract.lua``, and kills MAME
after ``record_seconds`` (default 60).

The generic Lua loads the companion at runtime via the
``ARCADEIA_ATTRACT_CFG`` env var and dispatches on its ``mode``:

  - ``tile``   → tile-based playfield (atetris-style)
  - ``sprite`` → sprite-based playfield (wboy / gngb / outrun-style)

The recorder NEVER presses coin/start — the arcade plays its own demo.

Adding a new game:
  1. Drop ``config/attract_recording/<game_id>.yaml`` with the right
     RAM layout (see ``config/attract_recording/README.md``).
  2. ``scripts/mame/teach_attract.sh <game_key>`` works.
"""

from __future__ import annotations

import argparse
import os
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

try:
    import yaml  # type: ignore
    _HAVE_YAML = True
except ImportError:
    yaml = None
    _HAVE_YAML = False


# --------------------------------------------------------------------------- #
# Minimal YAML reader (used only when PyYAML is not installed).
# Handles exactly the subset our configs use:
#   key: value
#   key: [v1, v2, ...]                (inline list, numbers/strings)
#   key:
#     subkey: value                   (nested dict)
#   key: hex-value | int | float | "quoted string" | true | false | null
#   # comments
# --------------------------------------------------------------------------- #
def _mini_yaml_load(text: str) -> Any:
    """A 60-line YAML parser covering only what the recording configs use."""
    tokens: list[tuple[str, str]] = []  # (indent, content)
    for raw in text.splitlines():
        # strip comments outside of quotes
        in_s = False
        cut = -1
        for i, ch in enumerate(raw):
            if ch == '"':
                in_s = not in_s
            elif not in_s and ch == "#":
                cut = i; break
        line = raw if cut < 0 else raw[:cut]
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip(" "))
        tokens.append((indent, line.strip()))

    root: dict = {}
    stack: list[tuple[int, Any]] = [(-1, root)]
    list_stack: list[tuple[int, list]] = []  # parallel stack for current list

    def _parse_scalar(s: str) -> Any:
        s = s.strip()
        if not s: return None
        if s.startswith('"') and s.endswith('"'):
            return s[1:-1]
        if s in ("true", "True", "yes"): return True
        if s in ("false", "False", "no"): return False
        if s in ("null", "Null", "~"): return None
        if s.startswith("0x") or s.startswith("0X"):
            return int(s, 16)
        try:
            return int(s)
        except ValueError:
            pass
        try:
            return float(s)
        except ValueError:
            pass
        return s

    for indent, content in tokens:
        # pop deeper or equal levels
        while stack and stack[-1][0] >= indent:
            stack.pop()
            if list_stack and list_stack[-1][0] >= indent:
                list_stack.pop()
        parent = stack[-1][1]
        # list?
        if content.startswith("- "):
            item_content = content[2:].strip()
            if isinstance(parent, list):
                item = _parse_scalar(item_content) if not item_content.endswith(":") else {}
                parent.append(item)
                if isinstance(item, dict):
                    stack.append((indent, item))
                    list_stack.append((indent, parent))
            continue
        if content.endswith(":"):
            key = content[:-1].strip()
            sub: Any = {}
            parent[key] = sub
            stack.append((indent, sub))
            continue
        # inline list?
        if content.endswith("]"):
            key, _, rest = content.partition(":")
            key = key.strip()
            lst_str = rest.strip()
            inner = lst_str[1:-1] if lst_str.startswith("[") else lst_str
            items = [_parse_scalar(p) for p in inner.split(",") if p.strip()]
            parent[key] = items
            continue
        # scalar
        if ":" in content:
            key, _, val = content.partition(":")
            parent[key.strip()] = _parse_scalar(val)
        else:
            # bare scalar — only meaningful inside a list
            if isinstance(parent, list):
                parent.append(_parse_scalar(content))

    return root


def yaml_load(text: str) -> Any:
    if _HAVE_YAML:
        return yaml.safe_load(text)
    return _mini_yaml_load(text)


ROOT = Path(__file__).resolve().parent.parent
GAMES_YAML = ROOT / "config" / "games.yaml"
CFG_REC_DIR = ROOT / "config" / "attract_recording"
GENERIC_LUA = ROOT / "scripts" / "mame" / "teach_attract.lua"
GENERATED_CFG_DIR = ROOT / "scripts" / "mame"
MAME_BIN_CANDIDATES = [ROOT / "bin" / "mame", Path("/usr/games/mame"), Path("/usr/local/bin/mame")]
LOG_DIR = ROOT / "logs" / "demos"
DEFAULT_SECONDS = 60


# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #


def find_mame() -> Path:
    for p in MAME_BIN_CANDIDATES:
        if p.exists() and os.access(p, os.X_OK):
            return p
    # Fallback: env var or PATH lookup
    found = shutil.which("mame") or shutil.which("mame64")
    if found:
        return Path(found)
    sys.exit("ERROR: MAME binary not found in bin/, /usr/games, /usr/local/bin, or $PATH")


def load_game(game_key: str) -> dict:
    if not GAMES_YAML.exists():
        sys.exit(f"ERROR: missing {GAMES_YAML}")
    data = yaml_load(GAMES_YAML.read_text(encoding="utf-8"))
    mame = (data or {}).get("mame_games", {})
    if game_key not in mame:
        keys = ", ".join(sorted(mame))
        sys.exit(f"ERROR: '{game_key}' not in games.yaml. Available: {keys}")
    g = mame[game_key]
    for k in ("game_id", "rom"):
        if k not in g:
            sys.exit(f"ERROR: '{game_key}' missing '{k}' in games.yaml")
    return g


def load_recording_yaml(game_id: str) -> dict:
    ypath = CFG_REC_DIR / f"{game_id}.yaml"
    if not ypath.exists():
        sys.exit(
            f"ERROR: recording YAML not found: {ypath}\n"
            f"Create one (see config/attract_recording/atetris.yaml for example)."
        )
    return yaml_load(ypath.read_text(encoding="utf-8"))


def lua_str(s: Any) -> str:
    if s is None:
        return "nil"
    if isinstance(s, bool):
        return "true" if s else "false"
    if isinstance(s, (int, float)):
        if isinstance(s, float) and s.is_integer():
            return str(int(s))
        return str(s)
    # string
    return '"' + str(s).replace("\\", "\\\\").replace('"', '\\"') + '"'


def emit_lua_config(game_key: str, game: dict, rec: dict) -> Path:
    """Generate ``scripts/mame/.teach_attract_<game_id>.lua`` from YAML + meta."""
    mode = rec.get("mode")
    if mode not in ("tile", "sprite"):
        sys.exit(f"ERROR: '{game_key}' recording.yaml must set mode: tile | sprite")

    out_path = GENERATED_CFG_DIR / f".teach_attract_{game['game_id']}.lua"
    out_path.parent.mkdir(parents=True, exist_ok=True)

    lines: list[str] = [
        "-- AUTO-GENERATED by scripts/teach_attract.py — DO NOT EDIT.",
        f"-- Source: config/attract_recording/{game['game_id']}.yaml",
        "-- Re-run the launcher to regenerate.",
        "return {",
        f"    mode = {lua_str(mode)},",
        f"    game_id = {lua_str(game['game_id'])},",
        f"    rom = {lua_str(game['rom'])},",
        f"    record_seconds = {int(rec.get('record_seconds', DEFAULT_SECONDS))},",
        f"    sample_every = {int(rec.get('sample_every', 3))},",
        f"    boot_skip_frames = {int(rec.get('boot_skip_frames', 0))},",
    ]

    if mode == "tile":
        if "tile" not in rec:
            sys.exit(f"ERROR: '{game_key}' tile-mode YAML missing 'tile:' block")
        t = rec["tile"]
        for k in ("base", "col_count", "bytes_per_cell"):
            if k not in t:
                sys.exit(f"ERROR: '{game_key}' tile block missing '{k}'")
        if "bg_scan" not in t or "rows" not in t["bg_scan"] or "cols" not in t["bg_scan"]:
            sys.exit(f"ERROR: '{game_key}' tile.bg_scan.rows/cols required")
        if "playfield" not in t or "rows" not in t["playfield"] or "cols" not in t["playfield"]:
            sys.exit(f"ERROR: '{game_key}' tile.playfield.rows/cols required")
        bg_r = t["bg_scan"]["rows"]; bg_c = t["bg_scan"]["cols"]
        pf_r = t["playfield"]["rows"]; pf_c = t["playfield"]["cols"]
        lines.append("    tile = {")
        lines.append(f"        base = 0x{int(t['base']):x},")
        lines.append(f"        col_count = {int(t['col_count'])},")
        lines.append(f"        bytes_per_cell = {int(t['bytes_per_cell'])},")
        lines.append(f"        bg_scan_rows = {{{int(bg_r[0])}, {int(bg_r[1])}}},")
        lines.append(f"        bg_scan_cols = {{{int(bg_c[0])}, {int(bg_c[1])}}},")
        lines.append(f"        play_rows = {{{int(pf_r[0])}, {int(pf_r[1])}}},")
        lines.append(f"        play_cols = {{{int(pf_c[0])}, {int(pf_c[1])}}},")
        lines.append("    },")
    else:  # sprite
        if "sprite" not in rec:
            sys.exit(f"ERROR: '{game_key}' sprite-mode YAML missing 'sprite:' block")
        s = rec["sprite"]
        for k in ("base", "stride", "sprite_count"):
            if k not in s:
                sys.exit(f"ERROR: '{game_key}' sprite block missing '{k}'")
        lines.append("    sprite = {")
        lines.append(f"        base = 0x{int(s['base']):x},")
        lines.append(f"        stride = {int(s['stride'])},")
        lines.append(f"        sprite_count = {int(s['sprite_count'])},")
        lines.append(f"        code_offset = {int(s.get('code_offset', 0))},")
        lines.append(f"        x_raw_offset = {int(s.get('x_raw_offset', 2))},")
        lines.append(f"        x_offset = {int(s.get('x_offset', -128))},")
        lines.append(f"        y_raw_offset = {int(s.get('y_raw_offset', 1))},")
        lines.append(f"        y_transform = {lua_str(s.get('y_transform', 'flip'))},")
        lines.append(f"        ignore_codes = {{ {', '.join(str(int(c)) for c in s.get('ignore_codes', [0, 0xff]))} }},")
        em = s.get("end_marker")
        if em:
            lines.append("        end_marker = {")
            lines.append(f"            offset = {int(em['offset'])},")
            lines.append(f"            mask = 0x{int(em['mask']):x},")
            lines.append("        },")
        lines.append("    },")

    lines.append("}")
    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return out_path


def main() -> int:
    ap = argparse.ArgumentParser(description="Generic attract-mode recorder")
    ap.add_argument("game", help="game key from config/games.yaml (e.g. atetris, wonder_boy)")
    ap.add_argument("--seconds", type=int, default=None,
                    help="override record_seconds from YAML")
    ap.add_argument("--no-window", action="store_true",
                    help="run MAME headless (-nowindow -sound none)")
    ap.add_argument("--keep-config", action="store_true",
                    help="don't delete the generated Lua config after run")
    ap.add_argument("--dry-run", action="store_true",
                    help="emit the Lua config and exit (don't launch MAME)")
    args = ap.parse_args()

    game = load_game(args.game)
    rec = load_recording_yaml(game["game_id"])
    if args.seconds is not None:
        rec["record_seconds"] = args.seconds
    secs = int(rec.get("record_seconds", DEFAULT_SECONDS))

    print(f"[teach_attract] game_key   = {args.game}")
    print(f"[teach_attract] game_id    = {game['game_id']}")
    print(f"[teach_attract] rom        = {game['rom']}")
    print(f"[teach_attract] mode       = {rec.get('mode')}")
    print(f"[teach_attract] seconds    = {secs}")
    print(f"[teach_attract] sample_every = {rec.get('sample_every', 3)}")
    print(f"[teach_attract] boot_skip  = {rec.get('boot_skip_frames', 0)} frames")

    cfg_path = emit_lua_config(args.game, game, rec)
    print(f"[teach_attract] generated  = {cfg_path}")

    if args.dry_run:
        print(cfg_path.read_text())
        return 0

    mame = find_mame()
    cmd = [
        str(mame),
        game["rom"].replace(".zip", ""),  # MAME takes ROM stem, no .zip
        "-rompath", str(ROOT / "roms"),
        "-cfg_directory", str(ROOT / "cfg"),
        "-autoboot_script", str(GENERIC_LUA),
        "-autoboot_delay", "0",
    ]
    if args.no_window:
        cmd += ["-nowindow", "-sound", "none"]
    else:
        cmd += ["-window", "-sound", "alsa"]

    LOG_DIR.mkdir(parents=True, exist_ok=True)
    mlog = LOG_DIR / "mame_attract_last.log"
    env = os.environ.copy()
    env["ARCADEIA_ATTRACT_CFG"] = str(cfg_path)
    env["ARCADEIA_ROOT"] = str(ROOT)

    print(f"[teach_attract] mame       = {mame}")
    print(f"[teach_attract] cmd        = {' '.join(cmd)}")
    print(f"[teach_attract] cfg env    = {cfg_path}")
    print(f"[teach_attract] mame log   = {mlog}")
    print(f"[teach_attract] running for {secs}s (no coin — observe only) ...")

    t0 = time.time()
    proc = subprocess.Popen(
        cmd, env=env, cwd=str(ROOT),
        stdout=open(mlog, "w"), stderr=subprocess.STDOUT,
    )
    interrupted = False
    rc = -1
    try:
        rc = proc.wait(timeout=secs + 30)
        elapsed = time.time() - t0
        print(f"[teach_attract] MAME exited rc={rc} after {elapsed:.1f}s")
    except subprocess.TimeoutExpired:
        elapsed = time.time() - t0
        print(f"[teach_attract] MAME ran {elapsed:.1f}s — killing (timeout safety)")
        _kill_mame(proc)
    except KeyboardInterrupt:
        interrupted = True
        print("[teach_attract] Ctrl-C — killing MAME")
        _kill_mame(proc)

    # Find the most recent attract_<game_id>_*.jsonl
    cands = sorted(
        LOG_DIR.glob(f"attract_{game['game_id']}_*.jsonl"),
        key=lambda p: p.stat().st_mtime,
    )
    if cands:
        latest = cands[-1]
        size = latest.stat().st_size
        with latest.open() as f:
            n = sum(1 for _ in f)
        print(f"[teach_attract] log        = {latest}")
        print(f"[teach_attract] size       = {size} bytes, {n} lines")
    else:
        print(f"[teach_attract] WARN: no attract_{game['game_id']}_*.jsonl found in {LOG_DIR}")
        print(f"[teach_attract] check {mlog} for MAME errors")

    if not args.keep_config:
        try:
            cfg_path.unlink()
            print(f"[teach_attract] removed {cfg_path.name}")
        except FileNotFoundError:
            pass
    else:
        print(f"[teach_attract] kept {cfg_path}")

    return (1 if interrupted else 0) if not cands else (130 if interrupted else 0)


# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #


def _kill_mame(proc: subprocess.Popen) -> None:
    """SIGTERM, then SIGKILL after 5 s if MAME ignores SIGTERM.

    Defined here (before ``if __name__``) so it's available even if MAME
    hangs during the first launch and the timeout fires before any user
    code has touched the module.
    """
    try:
        proc.send_signal(signal.SIGTERM)
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            proc.kill()
            proc.wait()
        except Exception:
            pass


if __name__ == "__main__":
    sys.exit(main())