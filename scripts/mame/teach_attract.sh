#!/usr/bin/env bash
# Generic attract-mode recorder.
# Usage: scripts/mame/teach_attract.sh <game_key> [--seconds N] [--no-window] [--keep-config] [--dry-run]
#
# Examples:
#   scripts/mame/teach_attract.sh atetris
#   scripts/mame/teach_attract.sh wonder_boy --seconds 90 --no-window
#   scripts/mame/teach_attract.sh outrun --keep-config
#
# Reads config/games.yaml + config/attract_recording/<game_id>.yaml,
# generates a per-game Lua config under scripts/mame/.teach_attract_<game_id>.lua,
# launches MAME with the GENERIC recorder (scripts/mame/teach_attract.lua),
# and kills MAME after `record_seconds`.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$HERE/../.." && pwd)"

# Prefer the project .venv (matches run.sh / scripts/mame_play.sh patterns).
PY="${PROJECT_ROOT}/.venv/bin/python3"
if [[ ! -x "$PY" ]]; then
    PY="$(command -v python3 || true)"
fi
if [[ -z "$PY" ]]; then
    echo "ERROR: python3 not found (no .venv/bin/python3 and no system python3)" >&2
    exit 1
fi

exec "$PY" "$HERE/../teach_attract.py" "$@"