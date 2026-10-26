#!/usr/bin/env python3
"""Paso 1 — harness de control Tehkan (prompts/tehkan_control_first.md).

Lanza MAME UNA vez con tehkan_control_proof.lua, analiza el CSV y escribe
logs/tehkan_control_proof_result.md con PASS/FAIL.

Uso:
  python3 scripts/prove_tehkan_control.py
  python3 scripts/prove_tehkan_control.py --no-window
  python3 scripts/prove_tehkan_control.py --analyze-only
"""

from __future__ import annotations

import argparse
import csv
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

from arcade_ai.envs.mame_env import resolve_mame_binary
from arcade_ai.envs.mame_launch import mame_env

LUA_SRC = ROOT / "scripts" / "mame" / "tehkan_control_proof.lua"
LUA_RUNTIME = ROOT / "scripts" / "mame" / ".tehkan_control_proof.lua"
CSV_PATH = ROOT / "logs" / "tehkan_control_proof.csv"
RESULT_MD = ROOT / "logs" / "tehkan_control_proof_result.md"
SUMMARY = Path("/tmp/tehkan_control_proof.log")

# Criterio del prompt: |Δsx|+|Δsy| >= 2 en ≥3 ventanas de 30 frames (post-boot).
WINDOW = 30
MOTION_THRESH = 2
MIN_WINDOWS = 3
PROOF_TIMEOUT_S = 90  # boot ~15s + proof ~15s + margen


def patch_lua() -> Path:
    text = LUA_SRC.read_text(encoding="utf-8")
    text = text.replace(
        'local ROOT = "/Users/pablo/Documents/arcade-ai"',
        f'local ROOT = "{ROOT}"',
    )
    LUA_RUNTIME.write_text(text, encoding="utf-8")
    return LUA_RUNTIME


def run_mame(*, window: bool) -> int:
    mame = resolve_mame_binary()
    if not mame:
        print("MAME no encontrado")
        return 2
    if not (ROOT / "roms" / "tehkanwc.zip").is_file():
        print("Falta roms/tehkanwc.zip")
        return 2

    lua = patch_lua()
    CSV_PATH.parent.mkdir(parents=True, exist_ok=True)
    if CSV_PATH.exists():
        CSV_PATH.unlink()
    # Cabecera escrita desde Python por si el Lua falla al abrir en "w"
    CSV_PATH.write_text(
        "frame,boot,accum_x,accum_y,player_sx,player_sy,delta_sx,delta_sy,fldx,fldy,fldbtn\n",
        encoding="utf-8",
    )

    cmd = [
        mame,
        "tehkanwc",
        "-rompath",
        str(ROOT / "roms"),
        "-cfg_directory",
        str(ROOT / "cfg"),
        "-inipath",
        f"{ROOT / 'cfg'};.",
        "-autoboot_script",
        str(lua),
        "-autoboot_delay",
        "2",
        "-window" if window else "-nowindow",
        "-sound",
        "none",
    ]
    print("Lanzando MAME control-proof (una sola vez)...")
    print(" ", " ".join(cmd[:6]), "...")
    try:
        proc = subprocess.run(
            cmd,
            env=mame_env(),
            cwd=str(ROOT),
            timeout=PROOF_TIMEOUT_S,
            check=False,
        )
        return proc.returncode
    except subprocess.TimeoutExpired:
        print(f"Timeout {PROOF_TIMEOUT_S}s — matando MAME")
        subprocess.run(["pkill", "-f", "mame.*tehkanwc"], check=False)
        return 124


def analyze(csv_path: Path) -> dict:
    if not csv_path.is_file() or csv_path.stat().st_size < 50:
        return {
            "status": "FAIL",
            "reason": "CSV ausente o vacío — el script Lua no llegó a loguear",
            "windows_pass": 0,
            "rows": 0,
            "sample": [],
        }

    raw = csv_path.read_text(encoding="utf-8").strip().splitlines()
    header = "frame,boot,accum_x,accum_y,player_sx,player_sy,delta_sx,delta_sy,fldx,fldy,fldbtn"
    if not raw[0].startswith("frame,"):
        raw = [header, *raw]

    rows = list(csv.DictReader(raw))

    post = [r for r in rows if r.get("boot") == "1"]
    windows_pass = 0
    window_details: list[str] = []
    i = 0
    while i + WINDOW <= len(post):
        chunk = post[i : i + WINDOW]
        moved = 0
        for r in chunk:
            try:
                d = abs(int(r["delta_sx"])) + abs(int(r["delta_sy"]))
            except (KeyError, ValueError):
                d = 0
            if d >= MOTION_THRESH:
                moved += 1
        ok = moved >= 3  # al menos 3 frames con movimiento en la ventana
        if ok:
            windows_pass += 1
        window_details.append(
            f"frames {chunk[0]['frame']}-{chunk[-1]['frame']}: "
            f"motion_frames={moved}/{WINDOW} {'PASS' if ok else 'fail'}"
        )
        i += WINDOW

    status = "PASS" if windows_pass >= MIN_WINDOWS else "FAIL"
    sample = []
    for r in post[:: max(1, len(post) // 8)][:8]:
        sample.append(
            f"f={r['frame']} p=({r['player_sx']},{r['player_sy']}) "
            f"d=({r['delta_sx']},{r['delta_sy']}) accum=({r['accum_x']},{r['accum_y']})"
        )

    fld = post[0] if post else (rows[0] if rows else {})
    return {
        "status": status,
        "reason": (
            f"{windows_pass} ventanas PASS (mínimo {MIN_WINDOWS})"
            if status == "PASS"
            else f"solo {windows_pass} ventanas con movimiento (hace falta ≥{MIN_WINDOWS})"
        ),
        "windows_pass": windows_pass,
        "window_details": window_details[:12],
        "rows": len(rows),
        "post_boot_rows": len(post),
        "fields": f"fldx={fld.get('fldx')} fldy={fld.get('fldy')} fldbtn={fld.get('fldbtn')}",
        "sample": sample,
    }


def write_result(result: dict) -> None:
    lines = [
        "# Tehkan control proof result",
        "",
        f"**ESTADO: {result['status']}**",
        "",
        f"- Criterio: |Δsx|+|Δsy|≥{MOTION_THRESH} en ≥{MIN_WINDOWS} ventanas de {WINDOW} frames (post-boot)",
        f"- Motivo: {result['reason']}",
        f"- Filas CSV: {result.get('rows', 0)} (post-boot: {result.get('post_boot_rows', 0)})",
        f"- Fields: {result.get('fields', '?')}",
        f"- CSV: `{CSV_PATH}`",
        f"- Summary: `{SUMMARY}`",
        "",
        "## Ventanas",
        "",
    ]
    for w in result.get("window_details") or ["(ninguna)"]:
        lines.append(f"- {w}")
    lines.extend(["", "## Muestra", ""])
    for s in result.get("sample") or ["(vacío)"]:
        lines.append(f"- `{s}`")
    lines.extend(
        [
            "",
            "## Si FAIL — siguiente paso único",
            "",
            "Repetir este mismo proof en **Linux x86_64** (MAMEToolkit / linux-lab).",
            "No reescribir `tehkanwc_ai.lua` hasta PASS. Ver `docs/mame_control_support.md`.",
            "",
        ]
    )
    RESULT_MD.parent.mkdir(parents=True, exist_ok=True)
    RESULT_MD.write_text("\n".join(lines), encoding="utf-8")
    print("\n".join(lines[:12]))


def main() -> None:
    parser = argparse.ArgumentParser(description="Tehkan trackball control proof")
    parser.add_argument("--no-window", action="store_true")
    parser.add_argument("--analyze-only", action="store_true")
    args = parser.parse_args()

    if not args.analyze_only:
        rc = run_mame(window=not args.no_window)
        print(f"MAME exit code: {rc}")

    result = analyze(CSV_PATH)
    write_result(result)
    if SUMMARY.is_file():
        print("--- summary ---")
        print(SUMMARY.read_text(encoding="utf-8")[-800:])
    print(f"\nESTADO: {result['status']}")
    print(f"EVIDENCIA: {RESULT_MD}")
    sys.exit(0 if result["status"] == "PASS" else 1)


if __name__ == "__main__":
    main()
