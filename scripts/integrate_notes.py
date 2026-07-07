#!/usr/bin/env python3
"""Integra anotaciones de texto (sin frames) en tácticas jugables."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MARKERS = ROOT / "logs" / "demos" / "markers.jsonl"
OUT_YAML = ROOT / "config" / "learned_tactics.yaml"
OUT_LUA = ROOT / "scripts" / "mame" / "learned_tactics.lua"

# Patrones de lenguaje natural → reglas de juego
PATTERNS = [
    {
        "match": re.compile(r"izquierda.*centro|centro.*izquierda", re.I),
        "name": "kickoff_left",
        "trigger": {"ball_x": 128, "ball_y": 112, "ball_x_tol": 28, "ball_y_tol": 28, "player_y_max": 200},
        "action": {"dx": -38, "dy": -52, "kick": True},
        "desc": "Saque desde izquierda del centro",
    },
    {
        "match": re.compile(r"diagonal.*palo.*derech", re.I),
        "name": "diag_far_post_right",
        "trigger": {"ball_x": 100, "ball_y": 112, "ball_x_tol": 40, "ball_y_tol": 35, "player_y_max": 180},
        "action": {"dx": 54, "dy": -58, "kick": True},
        "desc": "Diagonal al palo derecho",
    },
    {
        "match": re.compile(r"saque inicial|gol.*inicio|centro.*campo", re.I),
        "name": "kickoff_goal",
        "trigger": {"ball_x": 128, "ball_y": 112, "ball_x_tol": 30, "ball_y_tol": 30, "player_y_max": 200},
        "action": {"dx": 50, "dy": -58, "kick": True},
        "desc": "Gol desde saque inicial",
    },
    {
        "match": re.compile(r"segunda franja|franja verde", re.I),
        "name": "green_stripe_cross",
        "trigger": {"ball_x": 128, "ball_y": 72, "ball_x_tol": 50, "ball_y_tol": 25, "player_y_max": 95},
        "action": {"dx": 0, "dy": -58, "kick": True},
        "desc": "Centro desde 2ª franja verde",
    },
    {
        "match": re.compile(r"palo.*izquierd|diagonal.*izquierd", re.I),
        "name": "diag_far_post_left",
        "trigger": {"ball_x": 156, "ball_y": 90, "ball_x_tol": 45, "ball_y_tol": 40, "player_y_max": 120},
        "action": {"dx": -54, "dy": -58, "kick": True},
        "desc": "Diagonal al palo izquierdo",
    },
]


def load_markers() -> list[dict]:
    if not MARKERS.is_file():
        return []
    rows = []
    for line in MARKERS.read_text(encoding="utf-8").splitlines():
        if line.strip():
            rows.append(json.loads(line))
    return rows


def tactics_from_text(rows: list[dict]) -> list[dict]:
    seen = set()
    tactics = []
    all_text = " ".join(r["text"] for r in rows)

    for p in PATTERNS:
        if p["match"].search(all_text) and p["name"] not in seen:
            seen.add(p["name"])
            steps = [r["text"] for r in rows if r["kind"] == "step"]
            goals = [r["text"] for r in rows if r["kind"] == "goal"]
            desc = goals[0] if goals else p["desc"]
            tactics.append({
                "name": p["name"],
                "description": desc,
                "steps": steps,
                "trigger": p["trigger"],
                "action": p["action"],
            })
    return tactics


def write_outputs(tactics: list[dict]) -> None:
    yaml_lines = ["# Generado desde tus anotaciones de partida\n", "tactics:\n"]
    for t in tactics:
        yaml_lines.append(f"  - name: {t['name']}\n")
        yaml_lines.append(f"    description: \"{t['description']}\"\n")
        if t.get("steps"):
            yaml_lines.append("    steps:\n")
            for s in t["steps"]:
                yaml_lines.append(f"      - \"{s.replace(chr(34), chr(39))}\"\n")
        tr = t["trigger"]
        yaml_lines.append("    trigger:\n")
        for k, v in tr.items():
            yaml_lines.append(f"      {k}: {v}\n")
        ac = t["action"]
        yaml_lines.append("    action:\n")
        yaml_lines.append(f"      dx: {ac['dx']}\n")
        yaml_lines.append(f"      dy: {ac['dy']}\n")
        yaml_lines.append(f"      kick: {'true' if ac['kick'] else 'false'}\n")

    OUT_YAML.parent.mkdir(parents=True, exist_ok=True)
    OUT_YAML.write_text("".join(yaml_lines), encoding="utf-8")

    lua = ["-- Tácticas aprendidas de tus notas de partida\n", "local LEARNED = {\n"]
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


def main() -> None:
    rows = load_markers()
    if not rows:
        print("No hay anotaciones en markers.jsonl")
        sys.exit(1)

    tactics = tactics_from_text(rows)
    if not tactics:
        print("Anotaciones guardadas pero sin patrón reconocido.")
        print("Textos:", [r["text"] for r in rows])
        sys.exit(1)

    write_outputs(tactics)
    print(f"Integradas {len(tactics)} táctica(s) desde tus notas:")
    for t in tactics:
        print(f"  • {t['name']}: {t['description']}")
    print(f"\n→ {OUT_LUA}")
    print("Prueba: ./run.sh tehkan_world_cup heuristic --render")


if __name__ == "__main__":
    main()
