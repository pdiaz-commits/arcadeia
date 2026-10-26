#!/usr/bin/env python3
"""Entrenador de Wonder Boy: afina las constantes de la heuristica por
busqueda evolutiva (hill climbing con re-evaluacion), igual que el de Tehkan.

Fitness = puntuacion alcanzada antes del primer game over (BCD 0xc304:0xc305,
vidas 0xc302), medida jugando partidas reales sin ventana.

Uso:
    python3 scripts/train_wboy_params.py --rounds 8
    python3 scripts/train_wboy_params.py --apply     # copia best.json al agente

Resultados en logs/wboy_training/: history.jsonl y best.json.
"""
from __future__ import annotations

import argparse
import json
import os
import random
import re
import shutil
import subprocess
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
AGENT_LUA = ROOT / "scripts" / "mame" / "wboy_ai.lua"
MAME = ROOT / "vendor" / "mame" / "mame0288-arm64" / "mame"
OUT_DIR = ROOT / "logs" / "wboy_training"

# nombre: (minimo, maximo, paso de mutacion)
PARAMS = {
    "SCAN_AHEAD":       (90, 170, 10),
    "GROUND_TOL":       (30, 60, 6),
    "JUMP_HOLD":        (14, 30, 2),
    "JUMP_COOLDOWN":    (6, 22, 4),
    "COLLECT_DX":       (80, 140, 10),
    "LOOT_DX":          (70, 130, 10),
    "SNAIL_JUMP_DX":    (28, 60, 4),
    "AXE_RANGE":        (70, 120, 6),
    "ENEMY_LANE_DY":    (24, 50, 4),
    "AXE_MIN_DX":       (2, 16, 2),
    "ATTACK_STALL_JUMP": (10, 30, 4),
    "ENEMY_JUMP_DX":    (30, 64, 4),
}

# Mide el score alcanzado antes del primer game over (vidas 0xc302 -> 0).
SCORE_LUA = """
dofile("{agent}")
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local function bcd(b) return math.floor(b / 16) * 10 + b % 16 end
local function score() return bcd(mem:read_u8(0xc304)) * 100 + bcd(mem:read_u8(0xc305)) end
local n, best, done, alive = 0, 0, false, false
emu.register_frame_done(function() n = n + 1
  if n < 300 then return end
  local lv = mem:read_u8(0xc302)
  if lv > 0 and lv <= 3 then alive = true end
  if not done then
    if alive and lv == 0 then done = true
    else local s = score(); if s > best then best = s end end
  end
  if n % 300 == 0 then local f = _G.io.open("{out}", "w"); f:write(best .. "\\n"); f:close() end
end)
"""


def read_current_params() -> dict[str, int]:
    text = AGENT_LUA.read_text(encoding="utf-8")
    cur = {}
    for name in PARAMS:
        m = re.search(rf"^local {name}\s*=\s*(-?\d+)", text, re.M)
        if not m:
            raise SystemExit(f"No encuentro {name} en {AGENT_LUA}")
        cur[name] = int(m.group(1))
    return cur


def render_agent(params: dict[str, int]) -> str:
    text = AGENT_LUA.read_text(encoding="utf-8")
    for name, val in params.items():
        text = re.sub(rf"^(local {name}\s*=\s*)-?\d+", rf"\g<1>{val}", text, flags=re.M)
    return text


def play_match(agent_path: Path, work: Path, idx: int, delay: int) -> int:
    out = work / f"score_{idx}.txt"
    wrap = work / f"wrap_{idx}.lua"
    wrap.write_text(SCORE_LUA.format(agent=agent_path, out=out), encoding="utf-8")
    env = dict(os.environ, DYLD_FRAMEWORK_PATH=str(ROOT / "vendor" / "Frameworks"),
               SDL_VIDEODRIVER="dummy", SDL_AUDIODRIVER="dummy")
    subprocess.run(
        [str(MAME), "wboy", "-rompath", str(ROOT / "roms"), "-cfg_directory", str(ROOT / "cfg"),
         "-autoboot_script", str(wrap), "-autoboot_delay", str(delay),
         "-video", "none", "-sound", "none", "-nothrottle",
         "-keyboardprovider", "none", "-mouseprovider", "none", "-joystickprovider", "none",
         "-seconds_to_run", str(90 + delay), "-skip_gameinfo"],
        cwd=ROOT, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
    )
    try:
        return int(out.read_text().split()[0])
    except (OSError, ValueError, IndexError):
        return 0


def evaluate(params: dict[str, int], matches: int, workers: int, rng: random.Random) -> list[int]:
    work = Path(tempfile.mkdtemp(prefix="wboy_"))
    try:
        agent = work / "agent.lua"
        agent.write_text(render_agent(params), encoding="utf-8")
        delays = [rng.randint(2, 20) for _ in range(matches)]
        with ThreadPoolExecutor(max_workers=workers) as ex:
            return list(ex.map(lambda a: play_match(agent, work, a[0], a[1]), enumerate(delays)))
    finally:
        shutil.rmtree(work, ignore_errors=True)


def fitness(results: list[int]) -> float:
    return sum(results) / len(results) if results else -1.0


def summary(results: list[int]) -> str:
    return f"score medio {fitness(results):.0f}, mejor {max(results)}, muestras {results}"


def mutate(params: dict[str, int], rng: random.Random) -> dict[str, int]:
    child = dict(params)
    for name in rng.sample(list(PARAMS), k=rng.randint(1, 3)):
        lo, hi, step = PARAMS[name]
        child[name] = max(lo, min(hi, child[name] + rng.choice([-2, -1, 1, 2]) * step))
    return child


def apply_best() -> None:
    best = json.loads((OUT_DIR / "best.json").read_text())
    text = AGENT_LUA.read_text(encoding="utf-8")
    for name, val in best["params"].items():
        text = re.sub(rf"^(local {name}\s*=\s*)-?\d+", rf"\g<1>{val}", text, flags=re.M)
    AGENT_LUA.write_text(text, encoding="utf-8")
    print(f"Aplicados a {AGENT_LUA.name}: {best['params']}")
    print(f"Puntuacion: {best['fitness']:.0f} ({best['summary']})")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--rounds", type=int, default=8)
    ap.add_argument("--candidates", type=int, default=3)
    ap.add_argument("--matches", type=int, default=3)
    ap.add_argument("--workers", type=int, default=max(2, (os.cpu_count() or 4) - 2))
    ap.add_argument("--seed", type=int, default=None)
    ap.add_argument("--apply", action="store_true")
    args = ap.parse_args()

    if args.apply:
        apply_best()
        return

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    rng = random.Random(args.seed)
    hist = (OUT_DIR / "history.jsonl").open("a", encoding="utf-8")

    def log(kind, params, res, fit):
        hist.write(json.dumps({"t": time.strftime("%Y-%m-%d %H:%M:%S"), "kind": kind,
                               "params": params, "results": res, "fitness": round(fit, 2)}) + "\n")
        hist.flush()

    def save_best(params, res, fit):
        (OUT_DIR / "best.json").write_text(json.dumps(
            {"params": params, "fitness": fit, "summary": summary(res), "matches": len(res)}, indent=2))

    champ = read_current_params()
    t0 = time.time()
    champ_res = evaluate(champ, args.matches * 2, args.workers, rng)
    champ_fit = fitness(champ_res)
    log("base", champ, champ_res, champ_fit)
    save_best(champ, champ_res, champ_fit)
    print(f"[base] {champ_fit:.0f}  {summary(champ_res)}  ({time.time() - t0:.0f}s)", flush=True)

    for rnd in range(1, args.rounds + 1):
        for c in range(args.candidates):
            cand = mutate(champ, rng)
            res = evaluate(cand, args.matches, args.workers, rng)
            fit = fitness(res)
            log("candidate", cand, res, fit)
            changed = {k: v for k, v in cand.items() if v != champ[k]}
            print(f"[ronda {rnd} - {c + 1}] {fit:.0f}  mejor {max(res)}  cambios {changed}", flush=True)
            if fit > champ_fit:
                res2 = res + evaluate(cand, args.matches, args.workers, rng)
                fit2 = fitness(res2)
                log("confirm", cand, res2, fit2)
                if fit2 > champ_fit:
                    champ, champ_res, champ_fit = cand, res2, fit2
                    save_best(champ, champ_res, champ_fit)
                    print(f"   NUEVO MEJOR {fit2:.0f}  {summary(res2)}", flush=True)
                else:
                    print(f"   no se confirma ({fit2:.0f})", flush=True)
    print(f"\nMejor: {champ_fit:.0f}  {summary(champ_res)}\n{json.dumps(champ, indent=2)}")
    print(f"Tiempo total {(time.time() - t0) / 60:.1f} min. Aplica con: --apply")


if __name__ == "__main__":
    main()
