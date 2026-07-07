#!/usr/bin/env python3
"""Aprende tácticas de las demos anotadas y genera reglas para la IA."""

from __future__ import annotations

import json
import statistics
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEMO_DIR = ROOT / "logs" / "demos"
MARKERS_FILE = DEMO_DIR / "markers.jsonl"
OUT_YAML = ROOT / "config" / "learned_tactics.yaml"
OUT_LUA = ROOT / "scripts" / "mame" / "learned_tactics.lua"

WINDOW = 90  # frames antes del gol a analizar


def latest_session_with_data() -> Path | None:
    sessions = sorted(
        DEMO_DIR.glob("session_*.jsonl"),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    for path in sessions:
        if path.stat().st_size > 100:
            return path
    return None


def load_frames(session_path: Path) -> dict[int, dict]:
    frames = {}
    if not session_path.is_file():
        return frames
    for line in session_path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        row = json.loads(line)
        frames[row["frame"]] = row
    return frames


def dominant_input(rows: list[dict]) -> dict:
    if not rows:
        return {"dx": 0, "dy": 0, "kick_frames": 0}
    if "dx" in rows[0].get("input", {}):
        dx = [r["input"]["dx"] for r in rows if r["input"].get("dx", 0) != 0]
        dy = [r["input"]["dy"] for r in rows if r["input"].get("dy", 0) != 0]
        btn = sum(r["input"].get("btn", 0) for r in rows)
        return {
            "dx": int(statistics.mean(dx)) if dx else 0,
            "dy": int(statistics.mean(dy)) if dy else 0,
            "kick_frames": btn,
        }
    right = sum(r["input"].get("right", 0) for r in rows)
    jump = sum(r["input"].get("jump", 0) for r in rows)
    return {"dx": right - sum(r["input"].get("left", 0) for r in rows), "dy": -jump, "kick_frames": jump}


def avg_pos(rows: list[dict], key: str) -> tuple[int, int]:
    xs = [r[key]["x"] for r in rows if key in r and r[key].get("x", -1) >= 0]
    ys = [r[key]["y"] for r in rows if key in r and r[key].get("y", -1) >= 0]
    if not xs:
        return -1, -1
    return int(statistics.mean(xs)), int(statistics.mean(ys))


def main() -> None:
    if not MARKERS_FILE.is_file():
        print("No hay markers.jsonl — juega y anota con teach.py")
        sys.exit(1)

    goals = []
    steps_by_session: dict[str, list[str]] = {}

    for line in MARKERS_FILE.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        m = json.loads(line)
        if m["kind"] == "goal":
            goals.append(m)
        elif m["kind"] == "step":
            steps_by_session.setdefault(m.get("session", ""), []).append(m["text"])

    if not goals:
        print("No hay goles marcados. Usa: python scripts/teach.py goal \"...\"")
        sys.exit(1)

    tactics = []
    fallback_session = latest_session_with_data()
    for i, g in enumerate(goals, 1):
        session = Path(g.get("session", ""))
        frames = load_frames(session)
        gf = g["frame"]
        if (gf < 0 or not frames) and fallback_session:
            print(f"Gol {i}: usando sesión reciente {fallback_session.name}")
            session = fallback_session
            frames = load_frames(session)
        if gf < 0 and frames:
            gf = max(frames.keys())
            print(f"  → frame estimado: {gf}")
        if not frames:
            print(f"Saltando gol {i}: sin frames (¿sesión {session}?)")
            continue

        window = [frames[f] for f in range(max(1, gf - WINDOW), gf) if f in frames]
        if len(window) < 10:
            print(f"Saltando gol {i}: ventana muy corta ({len(window)} frames)")
            continue

        ball_x, ball_y = avg_pos(window, "ball")
        if ball_x < 0:
            ball_x, ball_y = avg_pos(window, "player")
        player_x, player_y = avg_pos(window, "player")
        inp = dominant_input(window)
        steps = steps_by_session.get(g.get("session", ""), [])

        tactics.append({
            "name": f"learned_goal_{i}",
            "description": g["text"],
            "steps": steps,
            "trigger": {
                "ball_x": ball_x,
                "ball_y": ball_y,
                "ball_x_tol": 28,
                "ball_y_tol": 28,
                "player_y_max": min(220, player_y + 40),
            },
            "action": {
                "dx": inp["dx"],
                "dy": inp["dy"],
                "kick": inp["kick_frames"] > 2,
            },
        })
        print(f"Aprendido: {g['text'][:50]}… (dx={inp['dx']}, dy={inp['dy']})")

    if not tactics:
        sys.exit(1)

    yaml_lines = ["# Generado por learn_from_demos.py — no editar a mano\n", "tactics:\n"]
    for t in tactics:
        yaml_lines.append(f"  - name: {t['name']}\n")
        yaml_lines.append(f"    description: \"{t['description']}\"\n")
        if t["steps"]:
            yaml_lines.append("    steps:\n")
            for s in t["steps"]:
                yaml_lines.append(f"      - \"{s.replace(chr(34), chr(39))}\"\n")
        tr = t["trigger"]
        yaml_lines.append("    trigger:\n")
        yaml_lines.append(f"      ball_x: {tr['ball_x']}\n")
        yaml_lines.append(f"      ball_y: {tr['ball_y']}\n")
        yaml_lines.append(f"      ball_x_tol: {tr['ball_x_tol']}\n")
        yaml_lines.append(f"      ball_y_tol: {tr['ball_y_tol']}\n")
        yaml_lines.append(f"      player_y_max: {tr['player_y_max']}\n")
        ac = t["action"]
        yaml_lines.append("    action:\n")
        yaml_lines.append(f"      dx: {ac['dx']}\n")
        yaml_lines.append(f"      dy: {ac['dy']}\n")
        yaml_lines.append(f"      kick: {'true' if ac['kick'] else 'false'}\n")

    OUT_YAML.parent.mkdir(parents=True, exist_ok=True)
    OUT_YAML.write_text("".join(yaml_lines), encoding="utf-8")

    lua = ['-- Auto-generado desde tus demos\n', "local LEARNED = {\n"]
    for t in tactics:
        tr, ac = t["trigger"], t["action"]
        lua.append("  {\n")
        lua.append(f'    name = "{t["name"]}",\n')
        lua.append(f'    desc = "{t["description"].replace(chr(34), chr(39))}",\n')
        lua.append(f"    bx = {tr['ball_x']}, by = {tr['ball_y']},\n")
        lua.append(f"    bx_tol = {tr['ball_x_tol']}, by_tol = {tr['ball_y_tol']},\n")
        lua.append(f"    py_max = {tr['player_y_max']},\n")
        lua.append(f"    dx = {ac['dx']}, dy = {ac['dy']}, kick = {str(ac['kick']).lower()},\n")
        lua.append("  },\n")
    lua.append("}\nreturn LEARNED\n")
    OUT_LUA.write_text("".join(lua), encoding="utf-8")

    print(f"\nGuardado: {OUT_YAML}")
    print(f"Guardado: {OUT_LUA}")
    print("La IA cargará estas tácticas en el próximo partido.")


if __name__ == "__main__":
    main()
