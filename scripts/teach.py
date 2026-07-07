#!/usr/bin/env python3
"""Anota pasos y goles mientras grabas una partida humana."""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEMO_DIR = ROOT / "logs" / "demos"
FRAME_FILE = DEMO_DIR / "current_frame.txt"
SESSION_FILE = DEMO_DIR / "current_session.txt"
MARKERS_FILE = DEMO_DIR / "markers.jsonl"


def current_frame() -> int:
    if not FRAME_FILE.is_file():
        return -1
    try:
        return int(FRAME_FILE.read_text(encoding="utf-8").strip())
    except ValueError:
        return -1


def current_session() -> str:
    if SESSION_FILE.is_file():
        return SESSION_FILE.read_text(encoding="utf-8").strip()
    return ""


def append_marker(kind: str, text: str) -> None:
    DEMO_DIR.mkdir(parents=True, exist_ok=True)
    fr = current_frame()
    entry = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "kind": kind,
        "text": text,
        "frame": fr,
        "session": current_session(),
    }
    with MARKERS_FILE.open("a", encoding="utf-8") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")
    print(f"✓ [{kind}] frame={fr} → {text}")


def cmd_mark(args: argparse.Namespace) -> None:
    append_marker("step", args.text)


def cmd_goal(args: argparse.Namespace) -> None:
    append_marker("goal", args.text)


def cmd_list(_: argparse.Namespace) -> None:
    if not MARKERS_FILE.is_file():
        print("Sin anotaciones todavía.")
        return
    for line in MARKERS_FILE.read_text(encoding="utf-8").splitlines():
        if line.strip():
            e = json.loads(line)
            print(f"frame {e['frame']:>6}  [{e['kind']}]  {e['text']}")


def cmd_status(_: argparse.Namespace) -> None:
    print(f"Sesión: {current_session() or '(no activa)'}")
    print(f"Frame actual: {current_frame()}")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Anota goles mientras juegas (modo grabación)"
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_mark = sub.add_parser("mark", help="Marcar un paso de la jugada")
    p_mark.add_argument("text")
    p_mark.set_defaults(func=cmd_mark)

    p_goal = sub.add_parser("goal", help="Marcar un gol y su descripción")
    p_goal.add_argument("text")
    p_goal.set_defaults(func=cmd_goal)

    p_list = sub.add_parser("list", help="Listar anotaciones")
    p_list.set_defaults(func=cmd_list)

    p_status = sub.add_parser("status", help="Frame y sesión actuales")
    p_status.set_defaults(func=cmd_status)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
