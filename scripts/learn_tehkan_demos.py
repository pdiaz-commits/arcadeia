#!/usr/bin/env python3
"""Convierte tus partidas grabadas (modo humano) en memoria de imitación.

Lee logs/tehkan_demos/*.csv y escribe scripts/mame/tehkan_imitation_data.lua:
una tabla de situaciones CON BALÓN y lo que hiciste en cada una. El agente
busca las situaciones más parecidas (k vecinos) y copia tu decisión.

Todo va orientado al ataque, así que sirve ataques hacia arriba o abajo.

Uso:
    python3 scripts/learn_tehkan_demos.py              # todas las grabaciones
    python3 scripts/learn_tehkan_demos.py --every 2    # 1 de cada 2 frames
"""

from __future__ import annotations

import argparse
import csv
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEMOS = ROOT / "logs" / "tehkan_demos"
OUT = ROOT / "scripts" / "mame" / "tehkan_imitation_data.lua"

POSSESS = 16       # frames con el balón pegado (algo más amplio que el agente)
GOAL_WINDOW = 150  # frames antes de un gol tuyo que se marcan como "jugada de gol"


def clip(v: int, lim: int = 60) -> int:
    return max(-lim, min(lim, v))


def features(r: dict[str, int]) -> list[int]:
    """Situación orientada al ataque (mismo cálculo que en el .lua)."""
    d = r["dir"]
    prog = (121 - r["mm_y"]) * (-d)              # >0 = campo rival, ~16 = línea de fondo
    return [
        prog,
        r["me_x"],
        r["ball_x"] - r["me_x"],
        (r["ball_y"] - r["me_y"]) * (-d),
        clip(r["r1dx"]), clip(r["r1dy"]),
        clip(r["r2dx"]), clip(r["r2dy"]),
    ]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--every", type=int, default=1, help="usar 1 de cada N frames")
    args = ap.parse_args()

    files = sorted(DEMOS.glob("*.csv"))
    if not files:
        raise SystemExit(f"No hay grabaciones en {DEMOS}")

    samples = []
    total_goals = 0
    for f in files:
        rows = [{k: int(v) for k, v in r.items()} for r in csv.DictReader(f.open())]
        goal_idx = [i for i in range(1, len(rows))
                    if rows[i]["us"] > rows[i - 1]["us"] and rows[i]["us"] < 20]
        total_goals += len(goal_idx)
        near_goal = set()
        for g in goal_idx:
            near_goal.update(range(max(0, g - GOAL_WINDOW), g))
        for i, r in enumerate(rows):
            if i % args.every or r["my_d"] > POSSESS or r["my_d"] > r["foe_d"]:
                continue
            d = r["dir"]
            fwd = r["tb_dy"] * d                    # >0 = hacia la portería rival
            samples.append((features(r), r["tb_dx"], fwd, r["btn"], 1 if i in near_goal else 0))

    with OUT.open("w", encoding="utf-8") as out:
        out.write("-- Generado por scripts/learn_tehkan_demos.py — no editar a mano.\n")
        out.write(f"-- {len(files)} grabaciones, {total_goals} goles, {len(samples)} situaciones con balón.\n")
        out.write("-- {prog, me_x, ball_dx, ball_dy, r1dx, r1dy, r2dx, r2dy, tb_dx, tb_fwd, btn, gol}\n")
        out.write("return {\n")
        for feat, ax, fwd, btn, goal in samples:
            out.write("{" + ",".join(map(str, feat + [ax, fwd, btn, goal])) + "},\n")
        out.write("}\n")
    goals_s = sum(s[4] for s in samples)
    print(f"{len(files)} grabaciones · {total_goals} goles · {len(samples)} situaciones con balón "
          f"({goals_s} de jugadas de gol) → {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
