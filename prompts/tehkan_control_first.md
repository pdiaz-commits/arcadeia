# Prompt de dirección — Arcade AI / Tehkan World Cup

Copia este bloque completo a Cursor, OpenCode, FreeBuff o ChatGPT Desktop.
Un solo agente. Un solo objetivo. Sin reinicios en bucle.

---

## Rol

Eres un ingeniero senior trabajando en el repo local:

`/Users/pablo/Documents/arcade-ai`

El proyecto es **Arcade AI**: MAME + agentes (heurístico → RL) sobre Tehkan World Cup (`tehkanwc`). Llevamos meses sin que el jugador tome el control. El overlay de la IA muestra decisiones (`dx`/`dy`), pero el sprite **no se mueve**.

No eres un product manager. No rediseñas el producto. No lanzas MAME en bucle. Arreglas el pathway de control.

---

## Objetivo único (Definition of Done)

**Prueba mínima superada:**

1. Script Lua mínimo (sin heurística, sin tácticas, sin attract learning).
2. Cada N frames inyecta un delta grande al trackball P1 (`:P1X` / `:P1Y`).
3. Mides sprite RAM (base `0xe800`) **antes y después**.
4. Demuestras con log que el sprite del jugador cambió de `sx`/`sy` de forma reproducible.
5. Escribes el resultado en `/tmp/tehkan_control_proof.log` (o equivalente en el repo bajo `logs/`).

Hasta que eso pase, **está prohibido**:

- entrenar PPO / Stable-Baselines3
- regenerar `attract_tactics.lua` / `learned_tactics.lua`
- reescribir `tehkanwc_ai.lua` v19 “completo”
- relanzar `./run.sh` en bucle desde el agente
- tocar la web (`web/`), ALE, u otros juegos

---

## Contexto técnico (hechos, no hipótesis)

- ROM: `roms/tehkanwc.zip`
- MAME vendor: `vendor/mame/mame0288-arm64/mame` (0.288)
- Agente actual: `scripts/mame/tehkanwc_ai.lua` (+ runtime `scripts/mame/.runtime_ai.lua`)
- Trackball helper: `scripts/mame/tehkan_trackball.lua`
  - Usa accumulator + `fld:set_value()` porque `set_value(const)` cada frame → delta 0
  - Hubo bugs de wrap 8-bit (v17.6) que MAME rechazaba
- Config: `cfg/tehkanwc.cfg`, `mame.ini` → `trackball_device none` (el teclado no debe pisar `set_value`)
- Env RL (futuro, no ahora): `src/arcade_ai/envs/tehkan_env.py` + `scripts/mame/tehkan_learn.lua` (TCP lockstep)
- Referencias externas útiles: [MAMEToolkit](https://github.com/M-J-Murray/MAMEToolkit), ArcadeAI/Tempest
- En macOS el pathway Lua→trackball ha fallado de forma intermitente; Linux x86_64 es el plan B documentado en el README

Síntoma observado: overlay `v18.0 DIAG↑ d=0 dx=+42 dy=-58` mientras el jugador permanece quieto (con o sin balón).

---

## Plan de trabajo (ordenado, no saltes pasos)

### Paso 0 — No molestar

- No relances MAME automáticamente más de **una** vez por sesión, y solo si el usuario lo pide.
- Mata procesos huérfanos solo si el usuario lo autoriza o si bloquean el test único.

### Paso 1 — Harness de prueba (prioridad absoluta)

Ya existe (aplicar / ejecutar, no reinventar):

```bash
python3 scripts/prove_tehkan_control.py          # una sola vez
# o headless:
python3 scripts/prove_tehkan_control.py --no-window
```

- Lua: `scripts/mame/tehkan_control_proof.lua`
- Launcher: `scripts/prove_tehkan_control.py`
- Resultado: `logs/tehkan_control_proof_result.md` + CSV `logs/tehkan_control_proof.csv`
- Soporte repos/libs: `docs/mame_control_support.md`, `./scripts/fetch_mame_support.sh`
- Sin cascada heurística. Boot fijo documentado en el Lua.
- Criterio PASS: `|delta_sx| + |delta_sy| >= 2` en al menos 3 ventanas de 30 frames.

### Paso 2 — Si FAIL en macOS

- Comprueba campos reales del ioport (`:P1X` Trackball X, `:P1Y` Trackball Y, `:P1BUT`).
- Comprueba que no haya otro input device pisando el port.
- Documenta el fallo en 10 líneas en `logs/tehkan_control_proof_result.md`.
- Propón **una** alternativa (no cinco): p.ej. inyectar vía el mismo mecanismo que MAMEToolkit, o repetir el proof en Linux lab (`linux-lab` / Ubuntu x86_64).

### Paso 3 — Solo tras PASS

1. Reconectar `tehkan_trackball.inject_trackball` al agente mínimo (2 ramas: chase / diagonal).
2. Smoke test manual **una** partida (usuario mira).
3. Entonces, y solo entonces, RL (`tehkan_env` + PPO).

---

## Reglas de colaboración (si hay varios agentes)

- **Un dueño** del bug de control. Los demás solo revisan el mismo diff.
- Prohibido que OpenCode / FreeBuff / ChatGPT / Meta reescriban el agente “para que juegue mejor” mientras el proof esté en rojo.
- Cualquier PR/cambio debe citar: `prompts/tehkan_control_first.md` y el resultado PASS/FAIL del proof.

---

## Estilo de cambios

- Diffs pequeños y medibles.
- No borrar `tehkanwc_ai.lua`; el proof es un camino paralelo hasta PASS.
- No commits ni deploys salvo que el usuario lo pida.
- No spam de ventanas MAME.

---

## Respuesta esperada del agente

Al terminar (o al bloquearse), responde en este formato:

```
ESTADO: PASS | FAIL | BLOCKED
EVIDENCIA: <ruta del log + 3 líneas clave>
CAUSA RAÍZ (si FAIL): <1-3 frases>
SIGUIENTE PASO ÚNICO: <una acción concreta>
```

---

## Frase de arranque (para pegar)

> Lee `prompts/tehkan_control_first.md` y ejecuta solo el Paso 1 (harness de prueba de control trackball en Tehkan). No relances MAME en bucle. No toques PPO ni tácticas. Cuando tengas PASS o FAIL con log, para y reporta en el formato ESTADO/EVIDENCIA/CAUSA/SIGUIENTE.
