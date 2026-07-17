#!/usr/bin/env python3
"""Graba la demo de atract mode de Tehkan (antes de moneda) y aprende tácticas."""

from __future__ import annotations

import argparse
import json
import os
import statistics
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

from arcade_ai.envs.mame_env import resolve_mame_binary

LUA_SRC = ROOT / "scripts" / "mame" / "record_attract.lua"
DEMO_DIR = ROOT / "logs" / "demos"
OUT_YAML = ROOT / "config" / "attract_tactics.yaml"
OUT_LUA = ROOT / "scripts" / "mame" / "attract_tactics.lua"

POSSESSION_DIST = 17
SPRINT = 58
CROWD_PANEL_X = 200


def patch_lua(frames: int) -> Path:
    text = LUA_SRC.read_text(encoding="utf-8")
    text = text.replace('local ROOT = "/Users/pablo/Documents/arcade-ai"', f'local ROOT = "{ROOT}"')
    text = text.replace("local RECORD_FRAMES = 3600", f"local RECORD_FRAMES = {frames}")
    out = ROOT / "scripts" / "mame" / ".record_attract.lua"
    out.write_text(text, encoding="utf-8")
    return out


def record_attract(frames: int = 3000) -> Path | None:
    mame = resolve_mame_binary()
    if not mame:
        print("MAME no encontrado")
        return None

    lua = patch_lua(frames)
    env = os.environ.copy()
    frameworks = ROOT / "vendor" / "Frameworks"
    if frameworks.is_dir():
        env["DYLD_FRAMEWORK_PATH"] = str(frameworks) + (
            f":{env['DYLD_FRAMEWORK_PATH']}" if env.get("DYLD_FRAMEWORK_PATH") else ""
        )

    print(f"Grabando demo atract mode (~{frames // 60}s)...")
    subprocess.run(
        [
            mame,
            "tehkanwc",
            "-rompath",
            str(ROOT / "roms"),
            "-cfg_directory",
            str(ROOT / "cfg"),
            "-autoboot_script",
            str(lua),
            "-autoboot_delay",
            "1",
            "-window",
            "-mouse",
            "-sound",
            "none",
        ],
        env=env,
        cwd=str(ROOT),
        check=False,
    )

    files = sorted(DEMO_DIR.glob("attract_*.jsonl"), key=lambda p: p.stat().st_mtime, reverse=True)
    for f in files:
        if f.stat().st_size > 500:
            print(f"Grabado: {f} ({f.stat().st_size} bytes)")
            return f
    print("No se generó archivo attract")
    return None


def load_rows(path: Path) -> list[dict]:
    rows = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        row = json.loads(line)
        if row.get("type") in ("meta", "end"):
            continue
        rows.append(row)
    return rows


def sanitize_rows(rows: list[dict]) -> list[dict]:
    """Descarta frames con balón en panel lateral (detección antigua)."""
    clean = []
    for r in rows:
        ball = r.get("ball", {})
        bx, by = ball.get("x", -1), ball.get("y", -1)
        if bx >= CROWD_PANEL_X:
            continue
        if bx < 0 and r.get("players", 0) < 4:
            continue
        clean.append(r)
    return clean


def carrier_dist(r: dict) -> int:
    dist = r.get("carrier_dist")
    if dist is not None and dist >= 0:
        return dist
    ball, player = r.get("ball", {}), r.get("player", {})
    if ball.get("x", -1) < 0 or player.get("x", -1) < 0:
        return 9999
    return abs(ball["x"] - player["x"]) + abs(ball["y"] - player["y"])


def infer_motion(rows: list[dict]) -> list[dict]:
    """Estima dx/dy del portador frame a frame (la demo no usa nuestro trackball)."""
    enriched = []
    prev = None
    for r in rows:
        p = r.get("player", {})
        if p.get("x", -1) < 0:
            enriched.append(r)
            prev = None
            continue
        if prev:
            r = dict(r)
            r["motion"] = {
                "dx": p["x"] - prev["x"],
                "dy": p["y"] - prev["y"],
            }
        prev = p
        enriched.append(r)
    return enriched


def find_attack_segments(rows: list[dict]) -> list[list[dict]]:
    """Tramos con balón: portador cerca del balón y avanzando hacia portería rival."""
    segments: list[list[dict]] = []
    current: list[dict] = []
    for r in rows:
        ball = r.get("ball", {})
        player = r.get("player", {})
        if ball.get("x", -1) < 0 or player.get("x", -1) < 0:
            if len(current) > 12:
                segments.append(current)
            current = []
            continue
        dist = carrier_dist(r)
        m = r.get("motion", {})
        advancing = m.get("dy", 0) < 0 or player["y"] < 130
        if dist < POSSESSION_DIST + 6 and advancing:
            current.append(r)
        elif len(current) > 12:
            segments.append(current)
            current = []
        else:
            current = []
    if len(current) > 12:
        segments.append(current)
    segments.sort(key=len, reverse=True)
    return segments


def find_shoot_moments(rows: list[dict]) -> list[dict]:
    """Momentos de disparo: balón se separa rápido del jugador hacia arriba."""
    shots = []
    for i in range(2, len(rows) - 2):
        a, b, c = rows[i - 1], rows[i], rows[i + 1]
        pb, pa, pc = a.get("player", {}), b.get("player", {}), c.get("player", {})
        bb, ba, bc = a.get("ball", {}), b.get("ball", {}), c.get("ball", {})
        if ba.get("y", 99) < 0 or pa.get("y", 99) < 0:
            continue
        if ba.get("x", -1) >= CROWD_PANEL_X:
            continue
        before = abs(bb["x"] - pb["x"]) + abs(bb["y"] - pb["y"])
        after = abs(bc["x"] - pc["x"]) + abs(bc["y"] - pc["y"])
        ball_up = ba["y"] - bb["y"]  # y menor = sube
        if before < POSSESSION_DIST + 4 and after > 22 and ball_up < -3:
            shots.append(b)
    return shots


def motion_to_trackball(dx: float, dy: float, *, kick: bool = False) -> tuple[int, int]:
    """Convierte delta sprite/frame (~30fps efectivo) a magnitud trackball."""
    scale = 2.8
    tdx = int(max(-SPRINT, min(SPRINT, dx * scale)))
    tdy = int(max(-SPRINT, min(SPRINT, dy * scale)))
    mag = max(abs(tdx), abs(tdy), 1)
    if mag < SPRINT - 8:
        factor = SPRINT / mag
        tdx = int(max(-SPRINT, min(SPRINT, tdx * factor)))
        tdy = int(max(-SPRINT, min(SPRINT, tdy * factor)))
    if tdy > -20:
        tdy = -SPRINT if not kick else -40
    return tdx, tdy


def segment_dominant_motion(seg: list[dict]) -> tuple[int, int]:
    dxs, dys = [], []
    for r in seg:
        m = r.get("motion")
        if not m:
            continue
        if m["dx"] != 0:
            dxs.append(m["dx"])
        if m["dy"] != 0:
            dys.append(m["dy"])
    raw_dx = statistics.mean(dxs) if dxs else 0
    raw_dy = statistics.mean(dys) if dys else -8
    return motion_to_trackball(raw_dx, raw_dy)


def build_tactics(rows: list[dict]) -> list[dict]:
    rows = infer_motion(rows)
    tactics = []

    for i, seg in enumerate(find_attack_segments(rows)[:8], 1):
        bx = int(statistics.mean([r["ball"]["x"] for r in seg]))
        by = int(statistics.mean([r["ball"]["y"] for r in seg]))
        py = int(statistics.mean([r["player"]["y"] for r in seg]))
        dx, dy = segment_dominant_motion(seg)
        tactics.append({
            "name": f"attract_run_{i}",
            "description": f"Demo arcade: carrera diagonal #{i}",
            "trigger": {
                "ball_x": bx, "ball_y": by,
                "ball_x_tol": 36, "ball_y_tol": 36,
                "player_y_max": min(220, py + 55),
            },
            "action": {"dx": dx, "dy": dy, "kick": False},
        })

    for i, shot in enumerate(find_shoot_moments(rows)[:6], 1):
        ball, player = shot["ball"], shot["player"]
        m = shot.get("motion", {"dx": 0, "dy": -12})
        dx, dy = motion_to_trackball(m["dx"], m["dy"], kick=True)
        if dy > -25:
            dy = -40
        tactics.append({
            "name": f"attract_shot_{i}",
            "description": f"Demo arcade: disparo #{i}",
            "trigger": {
                "ball_x": ball["x"], "ball_y": ball["y"],
                "ball_x_tol": 28, "ball_y_tol": 24,
                "player_y_max": min(220, player["y"] + 35),
            },
            "action": {"dx": dx, "dy": dy, "kick": True},
        })

    return tactics


def write_outputs(tactics: list[dict]) -> None:
    yaml_lines = ["# Generado por learn_from_attract.py — demo arcade\n", "tactics:\n"]
    for t in tactics:
        tr, ac = t["trigger"], t["action"]
        yaml_lines.append(f"  - name: {t['name']}\n")
        yaml_lines.append(f"    description: \"{t['description']}\"\n")
        yaml_lines.append("    trigger:\n")
        for k, v in tr.items():
            yaml_lines.append(f"      {k}: {v}\n")
        yaml_lines.append("    action:\n")
        yaml_lines.append(f"      dx: {ac['dx']}\n")
        yaml_lines.append(f"      dy: {ac['dy']}\n")
        yaml_lines.append(f"      kick: {'true' if ac['kick'] else 'false'}\n")
    OUT_YAML.parent.mkdir(parents=True, exist_ok=True)
    OUT_YAML.write_text("".join(yaml_lines), encoding="utf-8")

    lua = ["-- Auto-generado desde demo atract mode del arcade\n", "local ATTRACT = {\n"]
    for t in tactics:
        tr, ac = t["trigger"], t["action"]
        lua.append("  {\n")
        lua.append(f'    name = "{t["name"]}",\n')
        lua.append(f"    bx = {tr['ball_x']}, by = {tr['ball_y']},\n")
        lua.append(f"    bx_tol = {tr['ball_x_tol']}, by_tol = {tr['ball_y_tol']},\n")
        lua.append(f"    py_max = {tr['player_y_max']},\n")
        lua.append(f"    dx = {ac['dx']}, dy = {ac['dy']}, kick = {str(ac['kick']).lower()},\n")
        lua.append("  },\n")
    lua.append("}\nreturn ATTRACT\n")
    OUT_LUA.write_text("".join(lua), encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description="Aprende de la demo atract mode de Tehkan")
    parser.add_argument("--record", action="store_true", help="Grabar demo antes de analizar")
    parser.add_argument("--frames", type=int, default=3000, help="Frames a grabar (~50s)")
    parser.add_argument("--file", type=Path, help="JSONL ya grabado")
    args = parser.parse_args()

    path = args.file
    if args.record or path is None:
        path = record_attract(args.frames)
    if not path or not path.is_file():
        sys.exit(1)

    rows = sanitize_rows(load_rows(path))
    if len(rows) < 100:
        print(f"Muy pocos frames ({len(rows)}) — ¿hubo demo en pantalla?")
        sys.exit(1)

    dists = [carrier_dist(r) for r in rows if carrier_dist(r) < 9999]
    if dists:
        under = sum(1 for d in dists if d < POSSESSION_DIST + 6)
        print(f"Frames válidos: {len(rows)}, carrier_dist min={min(dists)}, bajo umbral: {under}")

    tactics = build_tactics(rows)
    if not tactics:
        print("No se detectaron patrones en la demo")
        sys.exit(1)

    write_outputs(tactics)
    print(f"\n{len(tactics)} tácticas desde demo arcade")
    print(f"Guardado: {OUT_YAML}")
    print(f"Guardado: {OUT_LUA}")
    for t in tactics[:5]:
        ac = t["action"]
        print(f"  • {t['description']}: dx={ac['dx']}, dy={ac['dy']}, kick={ac['kick']}")


if __name__ == "__main__":
    main()
