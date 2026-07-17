#!/usr/bin/env python3
"""Auditoría end-to-end del branch atetris.

Lanza MAME con el agente (random o heuristic) y un observer que loguea
per-frame el estado del tablero. Los logs quedan en
`logs/demos/atetris_audit_*.jsonl` para análisis post-mortem.

Uso::

    python3 scripts/audit_atetris.py --agent random    --duration 180
    python3 scripts/audit_atetris.py --agent heuristic --duration 180

El audit script (`scripts/mame/atetris_audit.lua`) registra su propio
`frame_done` ANTES de cargar el agente, así que captura desde frame 1.
El agente corre normalmente — no se modifica nada.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

from arcade_ai.envs.mame_env import resolve_mame_binary
from arcade_ai.envs.mame_launch import mame_env

AGENT_LUA = ROOT / "scripts" / "mame" / "atetris_ai.lua"
AUDIT_WRAPPER = ROOT / "scripts" / "mame" / "atetris_audit.lua"
RUNTIME_AGENT = ROOT / "scripts" / "mame" / ".audit_atetris_agent.lua"


def patch_agent(agent: str) -> Path:
    """Parchea atetris_ai.lua con AGENT=random|heuristic + ROOT del proyecto."""
    text = AGENT_LUA.read_text(encoding="utf-8")
    text = text.replace(
        'local ROOT = "/Users/pablo/Documents/arcade-ai"',
        f'local ROOT = "{ROOT}"',
    )
    text = text.replace('local AGENT = "heuristic"', f'local AGENT = "{agent}"')
    RUNTIME_AGENT.write_text(text, encoding="utf-8")
    return RUNTIME_AGENT


def main() -> int:
    parser = argparse.ArgumentParser(description="Auditoría atetris end-to-end")
    parser.add_argument("--agent", default="random",
                        choices=["random", "heuristic"])
    parser.add_argument("--duration", type=int, default=180,
                        help="Duración en segundos (MAME será matado al cabo)")
    parser.add_argument("--no-window", action="store_true",
                        help="Sin ventana (headless; más rápido)")
    args = parser.parse_args()

    mame_bin = resolve_mame_binary()
    if not mame_bin:
        print("MAME no encontrado.")
        return 1

    if not AGENT_LUA.is_file():
        print(f"Falta {AGENT_LUA}")
        return 1

    runtime = patch_agent(args.agent)
    print(f"[audit] agent={args.agent} runtime={runtime.name}")

    cmd = [
        mame_bin, "atetris",
        "-rompath", str(ROOT / "roms"),
        "-cfg_directory", str(ROOT / "cfg"),
        "-autoboot_script", str(AUDIT_WRAPPER),
        "-autoboot_delay", "1",
        "-sound", "none",
    ]
    if args.no_window:
        cmd.append("-nowindow")
    else:
        cmd.append("-window")

    print(f"[audit] launching MAME for {args.duration}s...")
    print(f"[audit] cmd: {' '.join(cmd)}")
    try:
        result = subprocess.run(
            cmd, cwd=str(ROOT), env=mame_env(),
            timeout=args.duration, check=False,
        )
        print(f"[audit] MAME exited with code {result.returncode}")
    except subprocess.TimeoutExpired:
        print(f"[audit] MAME killed after {args.duration}s (timeout OK)")

    log_files = sorted(
        (ROOT / "logs" / "demos").glob("atetris_audit_*.jsonl"),
        key=lambda p: p.stat().st_mtime, reverse=True,
    )
    if log_files:
        latest = log_files[0]
        size = latest.stat().st_size
        print(f"[audit] log más reciente: {latest} ({size} bytes)")
        return 0
    print("[audit] no se generó log")
    return 1


if __name__ == "__main__":
    sys.exit(main())