#!/usr/bin/env python3
"""Entrenador de Tehkan World Cup: busca los mejores ajustes del agente v19.

Prueba variantes de los ajustes V19_* de scripts/mame/tehkanwc_ai.lua,
juega partidos reales sin ventana contra la máquina y se queda con lo
que da mejor diferencia de goles. Es una búsqueda por prueba y error
(hill climbing con re-evaluación para no premiar la suerte).

Uso:
    python3 scripts/train_tehkan_params.py --rounds 15
    python3 scripts/train_tehkan_params.py --apply     # copia los mejores al .lua

Resultados en logs/tehkan_training/: history.jsonl y best.json.
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
AGENT_LUA = ROOT / "scripts" / "mame" / "tehkanwc_ai.lua"
MAME = ROOT / "vendor" / "mame" / "mame0288-arm64" / "mame"
OUT_DIR = ROOT / "logs" / "tehkan_training"
TOUR = False

# nombre: (mínimo, máximo, paso de mutación)
PARAMS = {
    "V19_POSSESS": (8, 22, 2),
    "V19_MM_SHOOT": (3, 16, 2),
    "V19_GOAL_X": (96, 128, 6),
    "V19_SHOT_SPEED": (16, 24, 2),  # tope 24: más rápido levanta el balón
    "V19_KICK_TAP": (2, 6, 1),
    "V19_KICK_COOLDOWN": (6, 40, 6),
    "V19_DRIBBLE_SPEED": (24, 58, 8),
    "V19_DRIBBLE_DX": (10, 58, 8),
    "V19_DODGE_AHEAD": (16, 60, 8),
    "V19_DODGE_LAT": (10, 40, 6),
    "V19_DODGE_FWD": (0, 58, 10),
    "V19_LEAD": (0, 14, 2),
    "V19_TACKLE_DIST": (8, 30, 4),
}

SCORE_LUA = """
dofile("{agent}")
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local n, us, them, done = 0, 0, 0, false
emu.register_frame_done(function() n = n + 1
  if n > 900 and not done then
    local a, b = mem:read_u8(0xc100), mem:read_u8(0xc101)
    if a + b < us + them then done = true
    elseif a < 20 and b < 20 then us, them = a, b end
  end
  if n % 600 == 0 then
    local f = _G.io.open("{out}", "w"); f:write(us .. " " .. them .. "\\n"); f:close()
  end
end)
"""


# Modo torneo: juega seguido hasta perder (empate = eliminado).
# 0xc0c0 = partidos ganados en el torneo (medido). Un partido dura ~7500
# frames: si pasan 9500 sin que suba, la partida ha terminado y salimos.
SCORE_LUA_TOUR = """
dofile("{agent}")
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local n, won, last_change = 0, 0, 900
local us, them, tot_us, tot_them = 0, 0, 0, 0
local function save()
  local f = _G.io.open("{out}", "w")
  f:write(won .. " " .. (tot_us + us) .. " " .. (tot_them + them) .. "\\n"); f:close()
end
emu.register_frame_done(function() n = n + 1
  if n < 900 then return end
  local w = mem:read_u8(0xc0c0)
  if w > won and w < 20 then won = w; last_change = n end
  local a, b = mem:read_u8(0xc100), mem:read_u8(0xc101)
  if a + b < us + them then tot_us, tot_them = tot_us + us, tot_them + them; us, them = 0, 0 end
  if a < 20 and b < 20 and a + b >= us + them then us, them = a, b end
  if n % 600 == 0 then save() end
  if n - last_change > 9500 then save(); manager.machine:exit() end
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
    text = re.sub(r'^local ROOT = ".*', f'local ROOT = "{ROOT}"', text, flags=re.M)
    text = re.sub(r'^local AGENT = ".*', 'local AGENT = "heuristic"', text, flags=re.M)
    for name, val in params.items():
        text = re.sub(rf"^local {name}\s*=\s*-?\d+", f"local {name} = {val}", text, flags=re.M)
    return text


def play_match(agent_path: Path, work: Path, idx: int, delay: int, tour: bool = False) -> tuple[int, ...]:
    out = work / f"score_{idx}.txt"
    wrap = work / f"wrap_{idx}.lua"
    tpl = SCORE_LUA_TOUR if tour else SCORE_LUA
    wrap.write_text(tpl.format(agent=agent_path, out=out), encoding="utf-8")
    # SDL "dummy": MAME no toca la pantalla del Mac (sin ventanas ni robo de foco)
    env = dict(os.environ, DYLD_FRAMEWORK_PATH=str(ROOT / "vendor" / "Frameworks"),
               SDL_VIDEODRIVER="dummy", SDL_AUDIODRIVER="dummy")
    subprocess.run(
        [str(MAME), "tehkanwc", "-rompath", str(ROOT / "roms"), "-cfg_directory", str(ROOT / "cfg"),
         "-autoboot_script", str(wrap), "-autoboot_delay", str(delay),
         "-video", "none", "-sound", "none", "-nothrottle",
         "-keyboardprovider", "none", "-mouseprovider", "none", "-joystickprovider", "none",
         "-seconds_to_run", str((1300 if tour else 150) + delay), "-skip_gameinfo"],
        cwd=ROOT, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
    )
    try:
        vals = tuple(map(int, out.read_text().split()))
    except (OSError, ValueError):
        vals = ()
    if tour:
        return vals if len(vals) == 3 else (0, 0, 0)
    return vals if len(vals) == 2 else (0, 0)


def evaluate(params: dict[str, int], matches: int, workers: int, rng: random.Random) -> list[tuple[int, ...]]:
    work = Path(tempfile.mkdtemp(prefix="tehkan_"))
    try:
        agent = work / "agent.lua"
        agent.write_text(render_agent(params), encoding="utf-8")
        delays = [rng.randint(2, 40) for _ in range(matches)]
        with ThreadPoolExecutor(max_workers=workers) as ex:
            return list(ex.map(lambda a: play_match(agent, work, a[0], a[1], TOUR), enumerate(delays)))
    finally:
        shutil.rmtree(work, ignore_errors=True)


def fitness(results: list[tuple[int, ...]]) -> float:
    """Partido suelto: diferencia de goles media + medio punto por victoria.
    Torneo: rondas ganadas de media + 0,1 por gol de diferencia."""
    if not results:
        return -99.0
    if TOUR:
        n = len(results)
        return sum(r[0] for r in results) / n + 0.1 * sum(r[1] - r[2] for r in results) / n
    gd = sum(u - t for u, t in results) / len(results)
    wins = sum(1 for u, t in results if u > t) / len(results)
    losses = sum(1 for u, t in results if u < t) / len(results)
    return gd + 0.5 * wins - 0.5 * losses


def summary(results: list[tuple[int, ...]]) -> str:
    if TOUR:
        rounds = sorted(r[0] for r in results)
        return (f"rondas ganadas media {sum(rounds) / len(rounds):.2f}, mejor {rounds[-1]}, "
                f"goles {sum(r[1] for r in results)}-{sum(r[2] for r in results)}")
    gf = sum(u for u, _ in results)
    gc = sum(t for _, t in results)
    w = sum(1 for u, t in results if u > t)
    e = sum(1 for u, t in results if u == t)
    l = sum(1 for u, t in results if u < t)
    return f"goles {gf}-{gc}, G/E/P {w}/{e}/{l}"


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
    print(f"Puntuación: {best['fitness']:.2f} ({best['summary']})")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--rounds", type=int, default=10)
    ap.add_argument("--candidates", type=int, default=4, help="variantes por ronda")
    ap.add_argument("--matches", type=int, default=12, help="partidos por evaluación")
    ap.add_argument("--workers", type=int, default=max(2, (os.cpu_count() or 4) - 2))
    ap.add_argument("--seed", type=int, default=None)
    ap.add_argument("--apply", action="store_true", help="copia best.json al agente y sale")
    ap.add_argument("--tour", action="store_true", help="modo torneo: jugar hasta perder")
    ap.add_argument("--out", default=None, help="carpeta de resultados (por defecto logs/tehkan_training)")
    args = ap.parse_args()

    global TOUR, OUT_DIR
    TOUR = args.tour
    if args.out:
        OUT_DIR = ROOT / args.out
    if args.apply:
        apply_best()
        return

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    rng = random.Random(args.seed)
    hist = (OUT_DIR / "history.jsonl").open("a", encoding="utf-8")

    def log(kind: str, params: dict, res: list, fit: float) -> None:
        hist.write(json.dumps({"t": time.strftime("%Y-%m-%d %H:%M:%S"), "kind": kind, "params": params,
                               "results": res, "fitness": round(fit, 3)}) + "\n")
        hist.flush()

    def save_best(params: dict, res: list, fit: float) -> None:
        (OUT_DIR / "best.json").write_text(json.dumps(
            {"params": params, "fitness": fit, "summary": summary(res), "matches": len(res)}, indent=2))

    champ = read_current_params()
    t0 = time.time()
    champ_res = evaluate(champ, args.matches * 2, args.workers, rng)
    champ_fit = fitness(champ_res)
    log("base", champ, champ_res, champ_fit)
    save_best(champ, champ_res, champ_fit)
    print(f"[base] {champ_fit:+.2f}  {summary(champ_res)}  ({time.time() - t0:.0f}s)", flush=True)

    for rnd in range(1, args.rounds + 1):
        for c in range(args.candidates):
            cand = mutate(champ, rng)
            res = evaluate(cand, args.matches, args.workers, rng)
            fit = fitness(res)
            log("candidate", cand, res, fit)
            changed = {k: v for k, v in cand.items() if v != champ[k]}
            print(f"[ronda {rnd} · {c + 1}] {fit:+.2f}  {summary(res)}  cambios {changed}", flush=True)
            if fit > champ_fit:
                # confirmar con otra tanda para no premiar la suerte
                res2 = res + evaluate(cand, args.matches, args.workers, rng)
                fit2 = fitness(res2)
                log("confirm", cand, res2, fit2)
                if fit2 > champ_fit:
                    champ, champ_res, champ_fit = cand, res2, fit2
                    save_best(champ, champ_res, champ_fit)
                    print(f"   ✓ NUEVO MEJOR {fit2:+.2f}  {summary(res2)}", flush=True)
                else:
                    print(f"   ✗ no se confirma ({fit2:+.2f})", flush=True)
    print(f"\nMejor: {champ_fit:+.2f}  {summary(champ_res)}\n{json.dumps(champ, indent=2)}")
    print(f"Tiempo total {(time.time() - t0) / 60:.1f} min. Aplica con: --apply")


if __name__ == "__main__":
    main()
