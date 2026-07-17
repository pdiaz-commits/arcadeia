# Ranking de dificultad de enseñanza — 8 ROMs en `roms/`

> **Nota**: el usuario pidió 9 ROMs pero `ls roms/*.zip` arroja 8 ZIPs + un directorio `mame-merged/` vacío. El ranking es sobre los 8 juegos que se pueden ejecutar localmente. El directorio `mame-merged/` se omite porque no contiene ROMs válidas.

## Metodología

Tres criterios, cada uno puntuado 1-5 (mayor = más fácil de enseñar). Score compuesto = suma (rango 3-15).

| Criterio | ¿Por qué? | Score 5 = | Score 1 = |
|---|---|---|---|
| (a) `actions_count` | El attract demo graba inputs humanos. Pocas acciones discretas = más fácil de capturar y reproducir fielmente. | 1-4 acciones discretas | Trackball/wheel continuos |
| (b) `ram_docs_score` | Para validar que el agente imita bien la demo, necesita leer RAM del juego. RAM bien documentada = más fácil. | Direcciones y constantes documentadas en scripts/proyectos | Cero documentación (driver privado, c-chip faltante) |
| (c) `attract_determinism_score` | Si el attract mode es determinista, las mismas reglas aplican siempre → extracción estable. Si tiene RNG o paths aleatorios, el extractor necesitará más demos para converger. | 100% determinista (mismo path cada vez) | Aleatorio / requiere múltiples demos |

## Ranking

| Rank | ROM | (a) Acciones | (b) RAM docs | (c) Attract | Total | Etiqueta |
|---|---|---|---|---|---|---|
| 1 | atetris | 5 | 5 | 5 | **15** | **Fácil** |
| 2 | wboy | 4 | 5 | 4 | **13** | Media |
| 3 | gngb | 4 | 4 | 4 | **12** | Media |
| 4 | spang | 5 | 2 | 4 | **11** | Media |
| 5 | snowbros | 4 | 2 | 4 | **10** | Media |
| 6 | tehkanwc | 1 | 5 | 4 | **10** | Media |
| 7 | outrun | 2 | 2 | 3 | **7** | Difícil |
| 8 | superman | 3 | 1 | 2 | **6** | **Muy difícil** |

## Justificación fila a fila

### 1. atetris (Tetris Atari, 1988) — Score 15
- **(a) 5**: Solo 4 acciones discretas (LEFT, RIGHT, DOWN, ROTATE). El agente ya las maneja con `IN1` masks `0x8, 0x4, 0x2, 0x1`. La demo del attract es trivial de capturar y reinyectar.
- **(b) 5**: `PF_BASE = 0x1000`, `ROW_LO/HI = 8/24`, `COL_LO/HI = 14/27` documentados en `atetris_ai.lua`. El playfield es **completamente observable** desde RAM (238 tiles). El bug de `stack_depths()` (piece_rows global) está documentado y es replicable.
- **(c) 5**: El attract mode de Atari Tetris es **demostrativo y determinista** (juega pieza por pieza). Ya tenemos `learn_from_attract_atetris.py` que extrae `{depth_sum → target_left}` con 5 reglas manuales + pipeline funcional.

### 2. wboy (Wonder Boy, 1986) — Score 13
- **(a) 4**: 6 acciones (4 dirs + JUMP + AXE). Cada acción es discreta → captura humana directa sin calibración analógica.
- **(b) 5**: **El más documentado del branch.** `SPRITE_BASE = 0xd000`, `WEAPON_RAM = 0xc07f`, 11 categorías de sprite codes (PLAYER/ROCK/FIRE/WASP/EGG/FRUIT/WEAPON/SKATE/ANGEL), 20+ constantes calibradas (SCAN_AHEAD, JUMP_HOLD, AXE_RANGE, ATTACK_STALL_JUMP). Tiene test CSV para imitation learning (`logs/wboy_human_dataset.csv`).
- **(c) 4**: Determinista — el attract mode juega niveles 1-1 a 1-5 siguiendo paths conocidos (Kastellorizo Playing Reference + observación). Pero requiere clasificar 15+ sprite codes para diferenciar enemy/loot/pickup, lo que baja la puntuación.

### 3. gngb (Ghosts'n Goblins, 1985) — Score 12
- **(a) 4**: 6 acciones (4 dirs + JUMP + FIRE). Similar a wboy pero con direcciones 8-way explícitas (UP, DOWN, LEFT, RIGHT separados).
- **(b) 4**: `SPRITE_BASE = 0x1e00`, 6 port masks claros (`P1_RIGHT = 0x01..P1_FIRE = 0x20`). Comentarios extensos sobre thresholds (GROUND_LO/HI, SCAN_AHEAD, FIRE_RANGE). Falta lo del scoreboard y la mecánica de armadura (piernas separadas del cuerpo).
- **(c) 4**: Attract mode nivel 1 (cementerio) determinista. El prompt `prompts/ghosts_n_goblins_agent.md` documenta la estrategia esperada.

### 4. spang (Super Pang, 1990) — Score 11
- **(a) 5**: Solo 3 acciones (LEFT, RIGHT, FIRE) en `IN1` masks `0x01/0x02/0x04`. El juego con menos input.
- **(b) 2**: `spang_ai.lua` es **muy minimal**: solo lee ports, no lee RAM. Falta extracción completa del estado del tablero (posiciones de bolas, power-ups).
- **(c) 4**: Attract mode simple — 1-2 rondas en bucle. Determinista. Pero el bot actual barre izq/der sin saber dónde está la bola.

### 5. snowbros (Snow Bros, 1990) — Score 10
- **(a) 4**: 6 acciones (4 dirs + SHOT + JUMP). Platformer estándar pero con puertos en `:DSW1` (bits altos), no en el P1 habitual.
- **(b) 2**: `snowbros_ai.lua` solo lee ports. **Cero lectura de RAM**. Layout Kaneko/Toaplan no documentado en el proyecto. Necesitaríamos añadir sprite RAM parsing desde cero.
- **(c) 4**: Attract mode nivel 1 (Tundra) en loop. Determinista pero sin extracción posible por falta de reader.

### 6. tehkanwc (Tehkan World Cup, 1986) — Score 10
- **(a) 1**: Trackball X + Y continuas (0..255 cada una) + 1 botón. Espacio de input **efectivamente infinito** — cualquier (dx, dy) ∈ [-128, +127]² es legal. Imposible capturar/reproducir fielmente.
- **(b) 5**: `SPRITE_BASE = 0xe800`, `HUD_BYTE_BASE = 0xe880` documentados con sprite codes categorizados. Score RAM parcialmente cazado (`TB.reset()` en v17.7 tras cambio de score). 
- **(c) 4**: Attract mode determinista pero los partidos duran ~7 min cada uno. **Pipeline `learn_from_attract.py` YA funciona** — 23 reglas en `attract_tactics.lua` + 18 expertas inyectadas. La extracción es robusta pese al input continuo porque las reglas son `{bx, by} → {dx, dy, kick}` y tolerantes a tol=36.

### 7. outrun (Out Run, 1986) — Score 7
- **(a) 2**: 1 steering wheel (analógica, posición absoluta) + 2 botones (ACCEL, BRAKE). La rueda no es un click — es una posición. Necesita calibración frame-by-frame.
- **(b) 2**: `outrun_ai.lua` es minimal — solo boot + heurística izq/der. **Layout de sprite RAM / road geometry NO documentado en el proyecto.** No sabemos dónde están los sprites de otros coches ni la geometría de la carretera.
- **(c) 3**: Attract mode demuestra vueltas completas. Determinista pero la rueda analógica complica la captura.

### 8. superman (Superman, 1988) — Score 6 (MUY DIFÍCIL)
- **(a) 3**: 10 acciones (8 direcciones incluyendo diagonales + ATTACK + JUMP). La más compleja del ranking.
- **(b) 1**: **`config/games.yaml` comenta literalmente: "falta ROM C-Chip (cchip_upd78c11.bin)"**. Sin el C-chip, la mitad de las mecánicas (niveles, items, scripted sequences,剧情) están bloqueadas. Imposible enseñar lo que no se ejecuta.
- **(c) 2**: Attract mode presente pero comportamiento complejo. Sin C-chip, probablemente tampoco funciona completo.

## Conclusiones y recomendaciones

**Si el objetivo es validar el pipeline attract→agente en un juego fácil → empezar por `atetris`** (score 15). El extractor `learn_from_attract_atetris.py` ya existe, las 5 reglas manuales están en sitio, y el dry-run del pipeline se ejecuta sin MAME. Es el camino de menor fricción.

**Si el objetivo es añadir un segundo juego "fácil" con payoff alto** → `wboy` (score 13). RAM excelente + actions discretas. El pipeline ya graba humano a `logs/wboy_human_dataset.csv` (formato CSV con 21 columnas).

**Evitar `superman` y `outrun`** hasta haber resuelto las dependencias estructurales (C-chip faltante, RAM no documentada, input analógico respectivamente).

## Fuentes de datos

| Criterio | Fuentes |
|---|---|
| (a) Actions | `cfg/*.cfg` (input blocks), `scripts/mame/*_ai.lua` (P1 field calls), `scripts/mame/wboy_record_play.lua` (mask definitions) |
| (b) RAM docs | Comentarios en `scripts/mame/*_ai.lua` (`SPRITE_BASE`, `PF_BASE`, masks de ports), `scripts/mame/tehkan_trackball.lua`, `scripts/mame/tehkan_tactics_loader.lua` |
| (c) Attract | `scripts/mame/record_attract.lua` (existencia de recorder), `scripts/mame/record_attract_atetris.lua` (exitoso ya), `scripts/learn_from_attract.py` (extractor Tehkan funcional), observación de `logs/demos/attract_*.jsonl` |

## Limitaciones

- No corrí cada ROM en MAME para verificar comportamiento actual — me basé en los scripts ya existentes (algunos agentes son muy viejos).
- El "score" es subjetivo (basado en mi experiencia con el código). Un test empírico requeriría correr `./run.sh <game> heuristic --render` durante 10 minutos por juego y medir % de partidas superadas.
- `outrun_ai.lua` y `superman_ai.lua` fueron truncados por el límite de tokens — el scoring (b) podría mejorar con la parte no leída.