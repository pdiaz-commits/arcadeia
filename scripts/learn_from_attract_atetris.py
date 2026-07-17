#!/usr/bin/env python3
"""Aprende place rules de la demo de atract mode de Atari Tetris.

v2 — correcciones del thinker review:
  1. NEW_PIECE_TOP_DROP bajado a 3 (antes 8). Con stack corto, el drop
     puede ser de sólo 4-7 filas al entrar la nueva pieza; el umbral
     8 fallaba silenciosamente y no detectaba nuevas vidas.
  2. target_left extraído rastreando piece_cells estable durante K=6
     frames (no solo piece_left derivado de find_active_piece, que se
     confunde cuando la pieza settle se mezcla con stack).
  3. Clustering por moda (voto mayoritario), no promedio — evita
     promediar columnas inventadas (15.3 ≠ ninguna col válida).
  4. Merge con reglas existentes preservando demo_place_1..4 y _18;
     las nuevas entran en los huecos 5..17.

Pipeline análogo a `learn_from_attract.py` (Tehkan World Cup):
    learn_from_attract.py   → Tehkan (trackball continuo)
    learn_from_attract_atetris.py → Tetris (placement discreto)

Uso::

    # CI sin MAME/ROM: frames sintéticos verifican la cadena completa.
    python3 scripts/learn_from_attract_atetris.py --dry-run

    # Capturar demo real (lanza MAME).
    python3 scripts/learn_from_attract_atetris.py --record --frames 5000

    # Re-extraer desde un JSONL ya grabado (sin tocar MAME).
    python3 scripts/learn_from_attract_atetris.py --file logs/demos/attract_atetris_*.jsonl
"""

from __future__ import annotations

import argparse
import json
import os
import re
import statistics
import subprocess
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

from arcade_ai.envs.mame_env import resolve_mame_binary

LUA_SRC = ROOT / "scripts" / "mame" / "record_attract_atetris.lua"
DEMO_DIR = ROOT / "logs" / "demos"
OUT_LUA = ROOT / "scripts" / "mame" / "atetris_attract_tactics.lua"
OUT_YAML = ROOT / "config" / "atetris_attract_tactics.yaml"

# Constantes del playfield (deben coincidir con record_attract_atetris.lua).
N_COLS = 14  # COL_HI - COL_LO = 27 - 14
ROW_HI = 24
ROW_LO = 8
COL_LO = 14
COL_HI = 27

# Detección de pieza.
NEW_PIECE_TOP_DROP = 3   # >3 rows = nueva pieza entró al playfield (antes 8; bug).
SETTLE_STABLE_FRAMES = 6 # frames consecutivos con piece_cells idénticos = settle.

# Reglas.
DEPTH_SUM_TOL = 48
PIECE_LEFT_TOL = 8
GAP_SLOTS = (5, 17)      # huecos a rellenar en la numeración demo_place_N.
PRESERVED_SLOTS = (1, 2, 3, 4, 18)  # reglas manuales / de otro extractor.


# ---------------------------------------------------------------------------
# Lua patcher + MAME spawner.
# ---------------------------------------------------------------------------

def patch_lua(frames: int) -> Path:
    text = LUA_SRC.read_text(encoding="utf-8")
    text = text.replace(
        'local ROOT = "/Users/pablo/Documents/arcade-ai"',
        f'local ROOT = "{ROOT}"',
    )
    text = text.replace("if frame >= 5000", f"if frame >= {frames}")
    out = ROOT / "scripts" / "mame" / ".record_attract_atetris.lua"
    out.write_text(text, encoding="utf-8")
    return out


def record_attract(frames: int) -> Path | None:
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
    print(f"Grabando demo atract mode atetris (~{frames // 60}s)...")
    subprocess.run(
        [
            mame, "atetris",
            "-rompath", str(ROOT / "roms"),
            "-cfg_directory", str(ROOT / "cfg"),
            "-autoboot_script", str(lua),
            "-autoboot_delay", "1",
            "-window", "-sound", "none",
        ],
        env=env, cwd=str(ROOT), check=False,
    )
    files = sorted(DEMO_DIR.glob("attract_atetris_*.jsonl"), key=lambda p: p.stat().st_mtime, reverse=True)
    for f in files:
        if f.stat().st_size > 500:
            print(f"Grabado: {f} ({f.stat().st_size} bytes)")
            return f
    print("No se generó archivo attract_atetris")
    return None


# ---------------------------------------------------------------------------
# Parsing / validación.
# ---------------------------------------------------------------------------

def load_rows(path: Path) -> list[dict]:
    rows: list[dict] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        row = json.loads(line)
        if row.get("type") in ("meta", "end"):
            continue
        rows.append(row)
    return rows


def parse_piece_cells(s: str) -> list[tuple[int, int]]:
    """Decodifica "row:col;row:col;..." → [(row, col), ...]."""
    if not s:
        return []
    out = []
    for token in s.split(";"):
        if not token:
            continue
        r, c = token.split(":")
        out.append((int(r), int(c)))
    return out


def validate_frame(row: dict) -> bool:
    required = ("frame", "heights", "depths", "piece_sig",
                "piece_cells", "piece_left", "piece_right", "piece_top")
    for k in required:
        if k not in row:
            return False
    if not isinstance(row["heights"], list) or len(row["heights"]) != N_COLS:
        return False
    if not isinstance(row["depths"], list) or len(row["depths"]) != N_COLS:
        return False
    return True


# ---------------------------------------------------------------------------
# Detección de vidas de pieza + extracción de (depth_sum, target_left).
# ---------------------------------------------------------------------------

def detect_piece_lives(frames: list[dict]) -> list[list[dict]]:
    """Una vida = frames donde piece_top pertenece a una misma pieza.

    Transición: piece_top baja > NEW_PIECE_TOP_DROP entre frames
    consecutivos (la nueva pieza entró al playfield mientras la
    anterior seguía marcada como activa en find_active_piece).
    """
    lives: list[list[dict]] = []
    current: list[dict] = []
    last_top: int | None = None

    for f in frames:
        if not validate_frame(f):
            continue
        pt = f["piece_top"]
        if pt == -1:
            if current:
                lives.append(current)
                current = []
            last_top = None
            continue
        if last_top is not None and pt < last_top - NEW_PIECE_TOP_DROP:
            if current:
                lives.append(current)
            current = []
        last_top = pt
        current.append(f)

    if current:
        lives.append(current)
    return lives


def find_settle_index(life: list[dict]) -> int | None:
    """Frame índice dentro de la vida donde la pieza quedó settle.

    piece_cells crudo se vuelve estable (idéntico durante K frames
    consecutivos) justo cuando la pieza toca fondo. Mientras la pieza
    cae, piece_cells cambia posición cada frame; al settle, se congela
    (al menos durante los frames previos a que la siguiente entre al
    playfield y la confunda con stack).
    """
    K = SETTLE_STABLE_FRAMES
    for i in range(len(life) - K):
        sig = life[i]["piece_cells"]
        if all(life[i + k]["piece_cells"] == sig for k in range(K)):
            return i
    return None


def piece_life_signal(life: list[dict]) -> dict | None:
    """Reduce una vida a (depth_sum_at_spawn, target_left).

    depth_sum_at_spawn = sum(depths[]) en el PRIMER frame. depths[]
    ya viene del recorder con la misma fórmula que stack_depths() del
    agente → coincide con lo que match_attract_tactic evalúa cuando
    la pieza entra al playfield.

    target_left = min col de piece_cells cuando la pieza está estable
    (settle). Es la columna donde el demo colocó la pieza, calculada
    desde piece_cells crudo (no piece_left derivado, que se confunde
    con el stack).
    """
    if len(life) < SETTLE_STABLE_FRAMES + 2:
        return None
    settle_i = find_settle_index(life)
    if settle_i is None:
        return None
    cells = parse_piece_cells(life[settle_i]["piece_cells"])
    if not cells:
        return None
    target_left = min(c[1] for c in cells)
    return {
        "depth_sum": sum(int(d) for d in life[0]["depths"]),
        "target_left": int(target_left),
        "frames": len(life),
        "first_frame": int(life[0]["frame"]),
        "last_frame": int(life[-1]["frame"]),
        "settle_frame": int(life[settle_i]["frame"]),
    }


def cluster_rules(pieces: list[dict]) -> list[dict]:
    """Agrupa reglas con depth_sum cercano usando MODA en target_left.

    Bug fix v3: antes promediaba target_left, generando columnas
    inventadas (15.3). Ahora voto mayoritario dentro de cada bucket
    depth_sum ± tol/2.
    """
    buckets: list[dict] = []
    for p in pieces:
        placed = False
        for b in buckets:
            if abs(p["depth_sum"] - b["depth_sum_center"]) <= DEPTH_SUM_TOL // 2:
                b["depth_sum_center"] = (b["depth_sum_center"] * b["count"] + p["depth_sum"]) / (b["count"] + 1)
                b["target_lefts"].append(p["target_left"])
                b["count"] += 1
                placed = True
                break
        if not placed:
            buckets.append({
                "depth_sum_center": float(p["depth_sum"]),
                "target_lefts": [p["target_left"]],
                "count": 1,
            })

    rules = []
    for b in buckets:
        mode_tl = Counter(b["target_lefts"]).most_common(1)[0][0]
        rules.append({
            "depth_sum": int(round(b["depth_sum_center"])),
            "target_left": int(mode_tl),
            "count": b["count"],
        })
    rules.sort(key=lambda r: r["depth_sum"])
    return rules


# ---------------------------------------------------------------------------
# Merge con reglas existentes (preserva demo_place_1..4 y _18).
# ---------------------------------------------------------------------------

RULE_BLOCK_RE = re.compile(
    r"\{\s*name\s*=\s*\"(?P<name>[^\"]+)\"\s*,[^}]*?\}",
    re.DOTALL,
)


def load_existing_rules(path: Path) -> list[dict]:
    """Parsea atetris_attract_tactics.lua sin ejecutar Lua.

    Devuelve las reglas existentes tal cual (con sus nombres originales
    intactos). Si el archivo no existe o no parsea, devuelve [].
    """
    if not path.exists():
        return []
    text = path.read_text(encoding="utf-8")
    out: list[dict] = []
    for m in RULE_BLOCK_RE.finditer(text):
        block = m.group(0)
        ds = re.search(r"depth_sum\s*=\s*(-?\d+)", block)
        tol = re.search(r"depth_sum_tol\s*=\s*(-?\d+)", block)
        plt = re.search(r"piece_left_tol\s*=\s*(-?\d+)", block)
        tl = re.search(r"target_left\s*=\s*(-?\d+)", block)
        if ds and tl:
            out.append({
                "name": m.group("name"),
                "depth_sum": int(ds.group(1)),
                "depth_sum_tol": int(tol.group(1)) if tol else DEPTH_SUM_TOL,
                "piece_left_tol": int(plt.group(1)) if plt else PIECE_LEFT_TOL,
                "target_left": int(tl.group(1)),
                "preserved": True,
            })
    return out


def merge_with_existing(
    preserved: list[dict], new_rules: list[dict]
) -> list[dict]:
    """Inserción por huecos: nuevas reglas ocupan demo_place_5..17.

    BUGFIX v2: antes preservaba TODAS las reglas existentes por nombre
    (incluyendo demo_place_5..17 si el archivo ya las tuviera con
    basura). Ahora solo se preservan las reglas en PRESERVED_SLOTS
    (1..4, 18); las de los huecos se sobrescriben con las nuevas
    extraídas. Si el extractor genera más de 13 reglas, las que sobran
    se numeran empezando en 19.
    """
    PRESERVED_NAMES = {f"demo_place_{i}" for i in PRESERVED_SLOTS}
    preserved_filtered = [r for r in preserved if r["name"] in PRESERVED_NAMES]

    gap = list(range(GAP_SLOTS[0], GAP_SLOTS[1] + 1))
    extras_start = 19
    used_names = {r["name"] for r in preserved_filtered}

    out: list[dict] = list(preserved_filtered)

    for r in new_rules:
        if gap:
            slot = gap.pop(0)
            name = f"demo_place_{slot}"
        else:
            name = f"demo_place_{extras_start}"
            extras_start += 1
        if name in used_names:
            continue
        used_names.add(name)
        out.append({
            "name": name,
            "depth_sum": r["depth_sum"],
            "depth_sum_tol": DEPTH_SUM_TOL,
            "piece_left_tol": PIECE_LEFT_TOL,
            "target_left": r["target_left"],
            "preserved": False,
        })

    out.sort(key=lambda r: _rule_sort_key(r["name"]))
    return out


def _rule_sort_key(name: str) -> tuple[int, str]:
    m = re.match(r"demo_place_(\d+)", name)
    if m:
        return (0, f"{int(m.group(1)):08d}")
    return (1, name)


# ---------------------------------------------------------------------------
# Writers Lua + YAML.
# ---------------------------------------------------------------------------

def to_lua_entry(rule: dict) -> str:
    return (
        "  {\n"
        f'    name = "{rule["name"]}",\n'
        f"    depth_sum = {rule['depth_sum']},\n"
        f"    depth_sum_tol = {rule.get('depth_sum_tol', DEPTH_SUM_TOL)},\n"
        f"    piece_left_tol = {rule.get('piece_left_tol', PIECE_LEFT_TOL)},\n"
        f"    target_left = {rule['target_left']},\n"
        "  },\n"
    )


def to_yaml_entry(rule: dict) -> str:
    src = "manual / preservada" if rule.get("preserved") else "auto: learn_from_attract_atetris"
    return (
        f"  - name: {rule['name']}\n"
        f"    depth_sum: {rule['depth_sum']}\n"
        f"    depth_sum_tol: {rule.get('depth_sum_tol', DEPTH_SUM_TOL)}\n"
        f"    piece_left_tol: {rule.get('piece_left_tol', PIECE_LEFT_TOL)}\n"
        f"    target_left: {rule['target_left']}\n"
        f"    source: {src}\n"
    )


def write_outputs(rules: list[dict]) -> None:
    header_lua = (
        "-- Auto-generado desde demo atract mode de Atari Tetris.\n"
        "-- Pipeline: scripts/learn_from_attract_atetris.py (v2 con merge).\n"
        "-- El extractor preserva las reglas manuales con nombre\n"
        "-- demo_place_1..4 y _18; las nuevas llenan los huecos 5..17.\n"
        "-- Cada nueva grabación regenera las huecas; las preservadas\n"
        "-- no se tocan. El agente (atetris_ai.lua) aplica\n"
        "-- match_attract_tactic con depth_sum_tol = 48; sobre esos\n"
        "-- buckets, la columna elegida por la demo gana sobre el\n"
        "-- heurístico puro.\n"
        "local ATTRACT = {\n"
    )
    body_lua = "".join(to_lua_entry(r) for r in rules)
    OUT_LUA.write_text(header_lua + body_lua + "}\nreturn ATTRACT\n", encoding="utf-8")

    header_yaml = "# Auto-generado desde demo atract Atari Tetris\nrules:\n"
    body_yaml = "".join(to_yaml_entry(r) for r in rules)
    OUT_YAML.parent.mkdir(parents=True, exist_ok=True)
    OUT_YAML.write_text(header_yaml + body_yaml, encoding="utf-8")


# ---------------------------------------------------------------------------
# Dry-run: frames sintéticos que cubren los caminos críticos.
# ---------------------------------------------------------------------------

def synthetic_frames(n_pieces: int = 8) -> list[dict]:
    """Frames sintéticos que ejercitan los caminos del extractor.

    Simula N piezas I-verticales cayendo una a una sobre el mismo
    playfield, donde cada pieza se asienta en una columna target que
    rota cada 4 piezas (ciclo 14→17). Sirve para validar que la
    detección de vida, la extracción de target_left vía piece_cells
    estable, el clustering con moda y el merge con huecos funcionan
    extremo a extremo sin necesidad de MAME.

    BUGFIX v2: depths[] está indexado por offset de columna (0..13),
    no por columna absoluta (14..27). El código original usaba
    `depths[target_left]` que crasheaba con IndexError.
    """
    frames: list[dict] = []
    frame_idx = 0

    bg = 0
    heights = [ROW_HI + 1] * N_COLS
    depths = [0] * N_COLS

    for piece_no in range(n_pieces):
        target_left = COL_LO + (piece_no // 4) % 4   # ciclo 14→17
        target_offset = target_left - COL_LO          # 0..13 (índice en depths)
        duration = 80

        for tick in range(duration):
            falling_top = min(5 + tick, ROW_HI - 3)
            piece_top_curr = falling_top
            cells = [(piece_top_curr + dy, target_left) for dy in range(4)]
            cells_sorted = sorted(cells)
            sig_str = ",".join(f"{r}:{c}" for r, c in cells_sorted)
            cells_str = ";".join(f"{r}:{c}" for r, c in cells_sorted)

            frames.append({
                "frame": frame_idx,
                "bg": bg,
                "heights": list(heights),
                "depths": list(depths),
                "piece_sig": sig_str,
                "piece_cells": cells_str,
                "piece_left": target_left,
                "piece_right": target_left,
                "piece_top": piece_top_curr,
            })
            frame_idx += 1

        new_h = max(ROW_LO, ROW_HI - depths[target_offset] - 3)
        heights[target_offset] = new_h
        depths[target_offset] += 4

    return frames


# ---------------------------------------------------------------------------
# Top-level pipeline.
# ---------------------------------------------------------------------------

def extract_rules(frames: list[dict]) -> tuple[list[dict], list[dict]]:
    lives = detect_piece_lives(frames)
    pieces = []
    for life in lives:
        sig = piece_life_signal(life)
        if sig is not None:
            pieces.append(sig)
    pieces.sort(key=lambda p: p["depth_sum"])
    rules = cluster_rules(pieces)
    return rules, pieces


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Aprende place rules de la demo atract mode de Atari Tetris",
    )
    parser.add_argument("--record", action="store_true",
                        help="Grabar demo antes de analizar (lanza MAME).")
    parser.add_argument("--frames", type=int, default=5000,
                        help="Frames a grabar (~83 s a 60 fps).")
    parser.add_argument("--file", type=Path,
                        help="JSONL ya grabado (logs/demos/attract_atetris_*.jsonl).")
    parser.add_argument("--dry-run", action="store_true",
                        help="Genera frames sintéticos y valida el pipeline sin MAME. "
                             "BUGFIX v2.2: escribe a /tmp, NO sobreescribe los archivos reales.")
    parser.add_argument("--dry-pieces", type=int, default=8,
                        help="Número de piezas sintéticas para dry-run.")
    args = parser.parse_args()

    dry_run = args.dry_run
    # out_* = paths de ESCRITURA (real normalmente, /tmp en dry-run).
    # in_*  = paths de LECTURA de reglas existentes (siempre el real).
    out_lua = OUT_LUA
    out_yaml = OUT_YAML
    in_lua = OUT_LUA
    # in_yaml = OUT_YAML  # no usado; el extractor solo carga reglas del .lua
    if dry_run:
        out_lua = Path("/tmp/atetris_attract_tactics.lua")
        out_yaml = Path("/tmp/atetris_attract_tactics.yaml")
        # BUGFIX v2.4: write_outputs() debe apuntar a /tmp, pero
        # load_existing_rules() debe seguir leyendo del archivo REAL
        # (si no, en dry-run no hay reglas que preservar y el output
        # sale vacío aunque el archivo real tenga 5 reglas manuales).
        # Solo reasignamos OUT_LUA/OUT_YAML, no las constantes in_*.
        globals()["OUT_LUA"] = out_lua
        globals()["OUT_YAML"] = out_yaml

    if dry_run:
        frames = synthetic_frames(args.dry_pieces)
        print(f"[dry-run] {len(frames)} frames sintéticos ({args.dry_pieces} piezas)")
    else:
        path = args.file
        if args.record or path is None:
            path = record_attract(args.frames)
        if not path or not path.is_file():
            print("Acción cancelada: ningún archivo de demo disponible. "
                  "Usa --dry-run para CI sin MAME/ROM.")
            return 1
        frames = load_rows(path)
        if len(frames) < 50:
            print(f"Demo demasiado corta ({len(frames)} frames). ¿MAME arrancó bien?")
            return 1

    rules, pieces = extract_rules(frames)
    if not pieces:
        print("No se detectaron piezas colocables en la demo.")
        return 1

    preserved = load_existing_rules(in_lua)
    final_rules = merge_with_existing(preserved, rules)
    write_outputs(final_rules)

    print(f"\n{len(pieces)} vidas detectadas → {len(rules)} nuevas reglas clustered")
    print(f"Preservadas: {len(preserved)} (manual / de otro extractor)")
    print(f"Total: {len(final_rules)} reglas")
    print(f"Lua:  {out_lua}")
    print(f"YAML: {out_yaml}")
    if rules:
        ds_min = min(r["depth_sum"] for r in rules)
        ds_max = max(r["depth_sum"] for r in rules)
        print(f"Rango depth_sum nuevas: {ds_min}..{ds_max}  (tol={DEPTH_SUM_TOL})")
        print("\nPrimeras 8 reglas finales:")
        for r in final_rules[:8]:
            tag = "[preservada]" if r.get("preserved") else "[nueva]    "
            print(f"  {tag} {r['name']}: depth_sum={r['depth_sum']}, "
                  f"target_left={r['target_left']}")

    if args.dry_run:
        # Sanity: el output debe tener reglas con depth_sum en rango válido
        # y al menos algunas "preservadas" si el archivo ya tenía reglas.
        # BUGFIX v2.3: leer de out_lua (la variable local, que apunta a
        # /tmp en dry-run) — NO del global OUT_LUA, que ahora apunta al
        # archivo real tras el redirect via globals().
        text = out_lua.read_text(encoding="utf-8")
        assert "return ATTRACT" in text, "Output Lua debe retornar tabla"
        n_entries = text.count("depth_sum =")
        n_preserved = text.count('name = "demo_place_1"')
        n_18 = text.count('name = "demo_place_18"')
        # v2.1 — asserts para evitar regresiones silenciosas en el merge:
        # las reglas manuales demo_place_1 (208) y demo_place_18 (28)
        # deben conservar sus valores originales.
        assert "depth_sum = 208" in text, (
            "demo_place_1 esperaba depth_sum=208 (no preservado o sobreescrito)"
        )
        assert "depth_sum = 28" in text, (
            "demo_place_18 esperaba depth_sum=28 (no preservado o sobreescrito)"
        )
        # v2.5 — el sintético solo genera 1 regla clustered, así que solo
        # rellena 1 slot (el primero disponible, demo_place_5). Comprobar
        # que al menos UNA nueva regla cae en slots 5..17, no exigir los
        # 13. Si en una corrida real el extractor genera 13+, todas se
        # rellenarán; si genera menos, los huecos restantes quedan vacíos
        # (el match_attract_tactic sigue funcionando con menos reglas).
        filled_gaps = [
            slot for slot in range(GAP_SLOTS[0], GAP_SLOTS[1] + 1)
            if f'name = "demo_place_{slot}"' in text
        ]
        assert filled_gaps, (
            f"Ninguna nueva regla cayó en los huecos {GAP_SLOTS[0]}..{GAP_SLOTS[1]}"
        )
        # v2.3 — verificación cruzada: el archivo real NO debe haberse tocado.
        # BUGFIX v2.4: leer via in_lua (la variable local capturada ANTES
        # del redirect), no via OUT_LUA que ahora apunta a /tmp.
        real_text = in_lua.read_text(encoding="utf-8")
        assert "depth_sum = 208" in real_text, (
            "BUG: dry-run sobreescribió el archivo real (depth_sum=208 perdido)"
        )
        print(f"\n[dry-run] Lua OK: {n_entries} entradas totales en /tmp, "
              f"demo_place_1 preservada={n_preserved}, demo_place_18 preservada={n_18}, "
              f"huecos rellenos={filled_gaps}, valores preservados ✓, archivo real intacto ✓")
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())