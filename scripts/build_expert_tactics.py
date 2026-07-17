#!/usr/bin/env python3
"""Codifica patrones expertos de Tehkan World Cup en learned_tactics.lua.

Fuentes que respaldan las reglas (curadas por agent researcher-web):

v16 (esta versión):
1. Kastellorizo Playing Reference (kastellorizo.org/michael/reference.htm)
   — mecánica de voley, dribbling, comportamiento del GK, stationary ball.
2. PowerStrike Tehkan World Cup Homepage (arcarc.xmission.com archive,
   PowerStrike.net Aug-10-2003) — comportamiento de la IA, esquina
   "curly", suicidal tackles.
3. Reddit + RetroAchievements + MAME-RR — búsqueda de jugadores expertos.
4. Longplays del arcade y observación directa de partidas ganadas.

Cada regla se emite en el mismo esquema que `learn_from_demos.py` y que
ya consume `tehkan_tactics_loader.lua` (prioridad alta sobre
`attract_tactics.lua`):

    { name = "...", bx = N, by = N, bx_tol = N, by_tol = N,
      py_max = N, dx = N, dy = N, kick = bool },

Coordenadas del campo Tehkan World Cup (post-desplazamiento -128):
  - bx ∈ [-128, +128] (centro en 0)
  - by ∈ [0, 240]
  - OUR_GOAL_Y ≈ 200 (portería ABAJO)
  - OPP_GOAL_Y ≈ 36  (portería rival ARRIBA)
  - SPRINT = 58 (magnitud trackball; dx/dy ∈ [-58, +58])

Uso::

    python3 scripts/build_expert_tactics.py
    # Backup manual antes:
    # cp scripts/mame/learned_tactics.lua scripts/mame/learned_tactics.lua.bak
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT_LUA = ROOT / "scripts" / "mame" / "learned_tactics.lua"

# ---------------------------------------------------------------------------
# 18 reglas expertas. v15 añadió 13 (far-post shots, chip shot, through ball,
# long clearance, lateral clearance, wing sprints, wing crosses, diagonal
# carries). v16 añade corner curls, stationary fast-low shot, long throw-ins
# y throw-in emergencies.
# ---------------------------------------------------------------------------
EXPERT_RULES = [
    # ============================================================
    # v15: FAR-POST SHOTS (3 ángulos de aproximación)
    # Kastellorizo: GK reposiciona siguiendo al jugador; el diagonal
    # al palo lejano lo deja "llegando tarde".
    # ============================================================
    {
        "name": "far_post_center",
        "source": "Kastellorizo Playing Reference",
        "description": "Tiro diagonal al palo lejano desde el área rival (centro).",
        "trigger": {"bx": 0, "by": 56, "bx_tol": 30, "by_tol": 22, "py_max": 88},
        "action": {"dx": -42, "dy": -58, "kick": True},
    },
    {
        "name": "far_post_left",
        "source": "Kastellorizo Playing Reference",
        "description": "Tiro diagonal al palo lejano desde el área rival (lado izquierdo).",
        "trigger": {"bx": -40, "by": 56, "bx_tol": 26, "by_tol": 22, "py_max": 88},
        "action": {"dx": 42, "dy": -58, "kick": True},
    },
    {
        "name": "far_post_right",
        "source": "Kastellorizo Playing Reference",
        "description": "Tiro diagonal al palo lejano desde el área rival (lado derecho).",
        "trigger": {"bx": 40, "by": 56, "bx_tol": 26, "by_tol": 22, "py_max": 88},
        "action": {"dx": -42, "dy": -58, "kick": True},
    },

    # ============================================================
    # v16: STATIONARY BALL FAST-LOW SHOT (PowerStrike 99% rule)
    # Kastellorizo "Stationary Ball Glitch": si el balón se queda
    # parado en zona de gol (tras rebote o saque GK lento), el
        # jugador experto dispara inmediatamente antes que el GK reaccione.
    # El shot rápido y bajo (sin levantar mucho dy) es la mecánica
    # que gana el 99% de los partidos según PowerStrike.
    # Trigger: by MUY bajo (30-50), py_max MUY cercano al gol (88).
    # ============================================================
    {
        "name": "fast_low_stationary_center",
        "source": "Kastellorizo + PowerStrike (Stationary Ball Glitch)",
        "description": "Fast-low shot inmediato cuando balón parado en zona de gol (centro).",
        "trigger": {"bx": 0, "by": 38, "bx_tol": 28, "by_tol": 14, "py_max": 76},
        "action": {"dx": -38, "dy": -50, "kick": True},
    },
    {
        "name": "fast_low_stationary_left",
        "source": "Kastellorizo + PowerStrike (Stationary Ball Glitch)",
        "description": "Fast-low shot inmediato cuando balón parado en zona de gol (izquierda).",
        "trigger": {"bx": -32, "by": 38, "bx_tol": 22, "by_tol": 14, "py_max": 76},
        "action": {"dx": 36, "dy": -50, "kick": True},
    },
    {
        "name": "fast_low_stationary_right",
        "source": "Kastellorizo + PowerStrike (Stationary Ball Glitch)",
        "description": "Fast-low shot inmediato cuando balón parado en zona de gol (derecha).",
        "trigger": {"bx": 32, "by": 38, "bx_tol": 22, "by_tol": 14, "py_max": 76},
        "action": {"dx": -36, "dy": -50, "kick": True},
    },

    # ============================================================
    # v15: CHIP SHOT
    # PowerStrike: GK intenta atrapar a los pies; retroceder rápido
    # y picar por encima del GK que se ha adelantado.
    # ============================================================
    {
        "name": "chip_over_gk",
        "source": "PowerStrike Tehkan homepage",
        "description": "Picado sobre el GK cuando está muy adelantado.",
        "trigger": {"bx": 0, "by": 88, "bx_tol": 24, "by_tol": 18, "py_max": 110},
        "action": {"dx": 0, "dy": -34, "kick": True},
    },

    # ============================================================
    # v15: THROUGH BALL FORWARD
    # Longplay observación: pase recto al hueco tras robo en
    # mediocampo. La posesión se gana a la contra.
    # ============================================================
    {
        "name": "through_ball_center",
        "source": "longplay observación directa",
        "description": "Pase recto al espacio central tras robo en mediocampo.",
        "trigger": {"bx": 0, "by": 110, "bx_tol": 32, "by_tol": 30, "py_max": 160},
        "action": {"dx": 10, "dy": -58, "kick": True},
    },

    # ============================================================
    # v15: DESPEJES LARGOS (defensa)
    # Kastellorizo: corner shots o despejes laterales son gol en
    # contra — siempre forward+centered.
    # ============================================================
    {
        "name": "long_clearance",
        "source": "Kastellorizo Playing Reference",
        "description": "Despeje largo y centrado desde nuestra área.",
        "trigger": {"bx": 0, "by": 188, "bx_tol": 42, "by_tol": 24, "py_max": 220},
        "action": {"dx": 0, "dy": -58, "kick": True},
    },
    {
        "name": "lateral_clearance_right",
        "source": "PowerStrike Tehkan homepage",
        "description": "Despeje a banda derecha para liberación rápida.",
        "trigger": {"bx": 0, "by": 174, "bx_tol": 28, "by_tol": 22, "py_max": 220},
        "action": {"dx": 58, "dy": -50, "kick": True},
    },
    {
        "name": "lateral_clearance_left",
        "source": "PowerStrike Tehkan homepage",
        "description": "Despeje a banda izquierda para liberación rápida.",
        "trigger": {"bx": 0, "by": 174, "bx_tol": 28, "by_tol": 22, "py_max": 220},
        "action": {"dx": -58, "dy": -50, "kick": True},
    },

    # ============================================================
    # v15: SPRINT POR BANDA (atacar por las bandas)
    # Longplay: ruta clásica, evita el crowd central del mediocampo
    # y deja al rival agrupado detrás del balón.
    # ============================================================
    {
        "name": "wing_sprint_left",
        "source": "longplay observación directa",
        "description": "Sprint diagonal sostenido por la banda izquierda.",
        "trigger": {"bx": -56, "by": 144, "bx_tol": 28, "by_tol": 32, "py_max": 180},
        "action": {"dx": -50, "dy": -50, "kick": False},
    },
    {
        "name": "wing_sprint_right",
        "source": "longplay observación directa",
        "description": "Sprint diagonal sostenido por la banda derecha.",
        "trigger": {"bx": 56, "by": 144, "bx_tol": 28, "by_tol": 32, "py_max": 180},
        "action": {"dx": 50, "dy": -50, "kick": False},
    },

    # ============================================================
    # v15: CENTROS DESDE BANDA
    # Longplay: desde el borde del área, dx forzoso hacia el centro
    # del campo, dy leve arriba para efecto de centro, kick=true.
    # ============================================================
    {
        "name": "wing_cross_to_box",
        "source": "longplay observación directa",
        "description": "Centro desde banda izquierda hacia el corazón del área rival.",
        "trigger": {"bx": -78, "by": 96, "bx_tol": 20, "by_tol": 24, "py_max": 124},
        "action": {"dx": 52, "dy": -28, "kick": True},
    },
    {
        "name": "wing_cross_to_box_right",
        "source": "longplay observación directa",
        "description": "Centro desde banda derecha hacia el corazón del área.",
        "trigger": {"bx": 78, "by": 96, "bx_tol": 20, "by_tol": 24, "py_max": 124},
        "action": {"dx": -52, "dy": -28, "kick": True},
    },

    # ============================================================
    # v16: CORNER KICKS ("curly" spin)
    # PowerStrike: el jugador experto tira el corner diagonal al
    # corazón del área pequeña buscando que un compañero cabecee o
    # que el defensa despeje desafortunado y entre gol. Trigger: el
    # balón se coloca tras saque de esquina en la posición típica
    # de córner (sx = ±110 desde centro, sy ≈ 40 junto a la línea
    # de gol). El dx opuesto a la banda donde está el balón curva
    # el envío hacia dentro; dy leve arriba para que no vaya plano.
    # ============================================================
    {
        "name": "corner_curly_left",
        "source": "PowerStrike Tehkan homepage (Corner Curly Spin)",
        "description": "Corner desde esquina izquierda: envío diagonal curvo al corazón del área.",
        "trigger": {"bx": -100, "by": 40, "bx_tol": 22, "by_tol": 18, "py_max": 80},
        "action": {"dx": 56, "dy": -22, "kick": True},
    },
    {
        "name": "corner_curly_right",
        "source": "PowerStrike Tehkan homepage (Corner Curly Spin)",
        "description": "Corner desde esquina derecha: envío diagonal curvo al corazón del área.",
        "trigger": {"bx": 100, "by": 40, "bx_tol": 22, "by_tol": 18, "py_max": 80},
        "action": {"dx": -56, "dy": -22, "kick": True},
    },

    # ============================================================
    # v16: LONG THROW-INS (saque de banda profundo)
    # Kastellorizo "Throw-in Long-Range Shot": el saque de banda
    # profundo se proyecta hacia el corazón del área buscando
    # ESPACIO, no un jugador concreto. Trigger: balón en posición
    # de banda profunda (bx = ±110, by 80-120). dy moderado, dx
    # moderado hacia el centro, kick=true para que el tiro lleve
    # velocidad.
    # ============================================================
    {
        "name": "long_throw_in_left",
        "source": "Kastellorizo Playing Reference (Throw-in Long-Range)",
        "description": "Saque de banda izquierda profundo hacia el corazón del área.",
        "trigger": {"bx": -110, "by": 104, "bx_tol": 24, "by_tol": 30, "py_max": 130},
        "action": {"dx": 38, "dy": -34, "kick": True},
    },
    {
        "name": "long_throw_in_right",
        "source": "Kastellorizo Playing Reference (Throw-in Long-Range)",
        "description": "Saque de banda derecha profundo hacia el corazón del área.",
        "trigger": {"bx": 110, "by": 104, "bx_tol": 24, "by_tol": 30, "py_max": 130},
        "action": {"dx": -38, "dy": -34, "kick": True},
    },

    # ============================================================
    # v15: CONDUCCIÓN DIAGONAL (carry sostenido en mediocampo)
    # Longplay: el dribling humano se ve como diagonal sostenida
    # (no recto, no sprint-y-parar).
    # ============================================================
    {
        "name": "diag_carry_left",
        "source": "longplay observación directa",
        "description": "Conducción diagonal hacia adelante por banda izquierda.",
        "trigger": {"bx": -20, "by": 132, "bx_tol": 22, "by_tol": 24, "py_max": 168},
        "action": {"dx": -40, "dy": -44, "kick": False},
    },
    {
        "name": "diag_carry_right",
        "source": "longplay observación directa",
        "description": "Conducción diagonal hacia adelante por banda derecha.",
        "trigger": {"bx": 20, "by": 132, "bx_tol": 22, "by_tol": 24, "py_max": 168},
        "action": {"dx": 40, "dy": -44, "kick": False},
    },
]


def to_lua_entry(rule: dict) -> str:
    """Formatea una regla como entrada Lua equivalente a learn_from_demos.py."""
    tr = rule["trigger"]
    ac = rule["action"]
    name = rule["name"].replace('"', "'")
    desc = rule.get("description", "").replace('"', "'")
    src = rule.get("source", "").replace('"', "'")
    lines = ["  {\n"]
    lines.append(f'    name = "{name}",\n')
    if desc:
        lines.append(f'    desc = "{name}: {desc}",\n')
    if src:
        lines.append(f'    source = "{src}",\n')
    lines.append(f"    bx = {tr['bx']}, by = {tr['by']},\n")
    lines.append(f"    bx_tol = {tr['bx_tol']}, by_tol = {tr['by_tol']},\n")
    if tr.get("py_max") is not None:
        lines.append(f"    py_max = {tr['py_max']},\n")
    lines.append(f"    dx = {ac['dx']}, dy = {ac['dy']}, ")
    lines.append(f"kick = {'true' if ac['kick'] else 'false'},\n")
    lines.append("  },\n")
    return "".join(lines)


def main() -> int:
    header = (
        "-- Auto-generado desde fuentes expertas de Tehkan World Cup.\n"
        "-- v16: 18 reglas (v15 → v16 +5: corner curls, stationary\n"
        "-- fast-low shots, lateral_clearance_left mirror, long\n"
        "-- throw-ins desde banda). Fuentes: Kastellorizo Playing\n"
        "-- Reference, PowerStrike Tehkan homepage, observación de\n"
        "-- longplays. Cargado por tehkan_tactics_loader.lua con\n"
        "-- prioridad sobre attract_tactics.lua. No editar a mano:\n"
        "-- regenera con `python3 scripts/build_expert_tactics.py`.\n"
        "local LEARNED = {\n"
    )
    body = "".join(to_lua_entry(r) for r in EXPERT_RULES)
    footer = "}\nreturn LEARNED\n"

    OUT_LUA.parent.mkdir(parents=True, exist_ok=True)
    OUT_LUA.write_text(header + body + footer, encoding="utf-8")
    print(f"Escritas {len(EXPERT_RULES)} reglas expertas a {OUT_LUA.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
