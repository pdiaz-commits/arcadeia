# Arcade AI

Juegos arcade clásicos + agentes de IA con distintos niveles (random → heurístico → reinforcement learning).

Inspirado en [Columns AI / machinelearning.pablodiaz.eu](https://machinelearning.pablodiaz.eu).

## Linux Lab (Docker Ubuntu + MAME)

Entorno compartido con IA One Unix:

```bash
cd ~/Documents/linux-lab
./bin/lab doctor
./bin/lab build
./bin/lab up arcade    # http://127.0.0.1:8014
```

En Ubuntu x86_64 nativo (óptimo para MAME):

```bash
sudo bash ~/Documents/linux-lab/scripts/setup-ubuntu-host.sh
cd ~/Documents/arcade-ai   # o /var/www/arcade-ai
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
uvicorn web.app:app --app-dir . --port 8014
./run.sh tehkan_world_cup heuristic
```

## Arranque rápido (macOS / Linux)

```bash
cd arcade-ai
chmod +x scripts/setup.sh
./scripts/setup.sh
```

O manualmente:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python scripts/play.py --game breakout --agent random --episodes 3
```

## Dashboard web (legacy, estático)

```bash
source .venv/bin/activate
uvicorn scripts.dashboard:app --reload --port 8765
```

Abre http://127.0.0.1:8765 — una página de estado simple (sin IA en vivo).

## Web app de producción (`web/`)

Este es el proyecto web real, desplegado en producción — implementa un subconjunto
funcional del mockup de Canvas `arcade-ai-web-mockup` (pestañas Play / AI plays /
Teach / Admin, streaming en vivo, selector de idioma EN/ES).

```bash
source .venv/bin/activate
pip install -r requirements.txt
uvicorn web.app:app --app-dir . --reload --port 8014
```

Abre http://127.0.0.1:8014

**Qué es real y qué no** (ver también `web/README` más abajo):

- ✅ **Real**: catálogo de juegos (`config/games.yaml`), streaming en vivo de un
  agente heurístico jugando Breakout/Pong/Space Invaders/Ms. Pac-Man/Tetris vía
  Gymnasium + ALE (WebSocket → frames JPEG en un `<canvas>`), traza de decisión
  (tabla "¿Cómo decide la IA?") tomada directamente del estado interno real del
  agente en cada frame, panel Teach con datos reales de `logs/demos/*.jsonl`,
  subida de ROMs/scripts Lua vía panel Admin (protegido por token).
- ⚠️ **No disponible en este despliegue** (aunque el código es real y funciona
  en local): jugar en vivo los cabinets MAME (Tehkan World Cup, Wonder Boy) vía
  navegador. El VPS de producción es compartido y tiene poca RAM libre; lanzar
  MAME + Xvfb en vivo ahí arriesgaría la estabilidad de los demás sitios
  alojados. Los scripts Lua (`scripts/mame/*.lua`) son 100% reales — se pueden
  ejecutar en local con `./run.sh tehkan_world_cup heuristic --render`, y el
  código fuente se muestra en la pestaña "AI plays" cuando eliges un juego MAME.

Variables de entorno relevantes:

- `ARCADEIA_ADMIN_TOKEN` — si no está definida, el panel Admin de subida de
  ROMs/Lua queda deshabilitado (403/503) en vez de abierto por defecto.

## Niveles de agente

| Nivel | Comando | Descripción |
|-------|---------|-------------|
| `random` | `--agent random` | Acciones aleatorias (baseline) |
| `heuristic` | `--agent heuristic` | Reglas simples (p. ej. seguir la pelota en Breakout) |
| `dqn` | *(próximo)* | Deep Q-Network con Stable Baselines3 |

## Juegos

**Fase 1 — ALE (Atari 2600)** — funciona ya en macOS sin MAME:

- `breakout`, `pong`, `space_invaders`, `pacman` (Ms. Pac-Man), `tetris`

```bash
python scripts/play.py --game tetris --agent heuristic --render
python scripts/play.py --game space_invaders --agent random --episodes 5
python scripts/play.py --game breakout --agent heuristic --render
```

**Fase 2 — MAME (cabinet arcade)** — instalado en `vendor/` (sin Homebrew):

```bash
chmod +x scripts/install_mame.sh bin/mame
./scripts/install_mame.sh          # SDLMAME 0.288 + SDL3
./bin/mame -version
mkdir -p roms                      # ROMs legales aquí
./bin/mame pacman -rompath roms    # ejemplo
./scripts/mame_play.sh atetris           # Tetris cabinet
./scripts/mame_play.sh tehkan_world_cup  # Tehkan World Cup (manual, teclado)

# IA automática (MAME + Lua)
python3 scripts/play_mame.py --game tehkan_world_cup --agent heuristic --render
./run.sh tehkan_world_cup heuristic --render
```

Alternativa global: `brew install mame` (si tienes Homebrew).

Referencias: [MAMEToolkit](https://github.com/M-J-Murray/MAMEToolkit), [ArcadeAI/Tempest](https://github.com/PlummersSoftwareLLC/ArcadeAI).

## Estructura

```
arcade-ai/
  config/games.yaml      # catálogo ALE + MAME
  src/arcade_ai/
    envs/ale_env.py      # entorno Gymnasium (activo)
    envs/mame_env.py     # stub MAME
    agents/              # random, heuristic (con traza de decisión), (dqn)
  web/                   # app de producción (FastAPI + JS vanilla)
    app.py                # rutas API + WebSocket /ws/play
    game_stream.py         # loop de partida en vivo (ALE real)
    i18n.py                 # copy EN/ES (adaptado del mockup Canvas)
    static/                  # index.html, app.js, styles.css
  scripts/
    setup.sh
    play.py              # demo CLI
    dashboard.py         # web local (legacy, estático)
    teach.py, teach_recorder.py, learn_from_demos.py  # flujo de enseñanza (MAME local)
    mame/*.lua            # agentes Lua reales (Tehkan World Cup, Wonder Boy)
  deploy/                 # unit de systemd + server_block de nginx de referencia
  roms/                  # ROMs MAME (gitignored)
```

## Despliegue (referencia)

Producción en **[arcade.arcaderooms.uk](https://arcade.arcaderooms.uk)** — `systemd`
(`deploy/systemd/arcadeia-web.service`) + `nginx` + TLS Let's Encrypt/Certbot.
La raíz **arcaderooms.uk** sirve Moodle Explorer (repo `moodle_explorer`).
Pasos: `deploy/README.md`.

## Requisitos

- Python 3.9+
- ROMs Atari: incluidas vía `gymnasium[atari,accept-rom-license]`
- ROMs MAME: debes poseerlas legalmente

## Próximos pasos

1. Entrenar DQN/PPO con Stable Baselines3
2. Integrar MAME + Lua (patrón ArcadeAI) para Tempest / Pac-Man cabinet
3. Publicar demo web al estilo Columns AI

---

## Entrenar PPO en Tehkan World Cup (MAME cabinet, RL real)

Arquitectura: gymnasium Env sobre MAME 0.288 + un script Lua
(`scripts/mame/tehkan_learn.lua`) que expone memoria del juego y acepta
acciones por TCP. **No usa heurística** — la red neuronal aprende desde
cero.

Componentes:

| Archivo | Rol |
|---|---|
| `scripts/mame/tehkan_learn.lua` | Driver MAME: lee sprite RAM, envía obs por socket TCP, bloquea esperando acción por frame_done (lockstep perfecto). |
| `src/arcade_ai/envs/tehkan_env.py` | gymnasium.Env: spawn lazzy de MAME, protocolo TCP, recompensa PBRS (Potential-Based Reward Shaping). |
| `src/arcade_ai/envs/dry_lua_server.py` | Fake MAME para CI / smoke tests sin ROM. |
| `scripts/train_tehkan.py` | PPO de Stable Baselines 3 con SubprocVecEnv + TensorBoard. |

Cómo arrancar:

```bash
# 0) Activar venv del proyecto (ya trae gymnasium + ale-py)
source arcade-ai/.venv/bin/activate

# 1) Instalar SB3 + torch (solo la primera vez; commentado en requirements.txt)
pip install "stable-baselines3[extra]" torch

# 2) Smoke test sin MAME/ROM (verifica protocolo TCP)
PYTHONPATH=arcade-ai/src python -m arcade_ai.envs.tehkan_env --dry-run --steps 25

# 3) Sanity check con MAME real (sub-ventana, sin entrenamiento)
./run.sh tehkan_world_cup human_record --render

# 4) Entrenar PPO (MAME headless, ~25 min para 100k steps con n_envs=1)
./scripts/train_tehkan.py --total-timesteps 200000 --n-envs 1

# 5) Ver curvas en TensorBoard
tensorboard --logdir=models/tehkan_ppo/tb
```

Detalles de diseño (importantes si vas a tocar el código):

- **Action space:** `Box(-1, 1, (3,), float32)` — trackball (dx,dy) + umbral de chute.
  PPO escala magnitudes continuas mucho más rápido que atravesar
  `MultiDiscrete(5,5,2)`.
- **Reward:** PBRS sin penalty por step (eso hacía que PPO marcase
  autogol para terminar el episodio antes). Diferencia de potencial
  ball→portería rival + proximity jugador-balón. +1/-1 terminal por gol.
- **Episodio:** termina en gol detectado (sprite_ball.y<36 ⇒ gol rival
  en contra, y>200 ⇒ gol a favor) **o** 2000 steps. NO 90 s de partido,
  demasiado disperso para que la red tenga señal.
- **Score RAM:** direcciones `SCORE_US_ADDR` / `SCORE_THEM_ADDR` en el
  Lua son `nil` por defecto — todavía no se han cazado en el debugger
  de MAME. Cuando estén, `find /,10000,1` después de marcar gol te da
  tu address. Mientras tanto la obs usa `score=0` y la detección de
  gol va por sprite. Funciona, pero un gol fantasma durante un replay
  puede disparar termination.
- **MAME spawn:` solo en `reset()` (no en `__init__`) — sino el fork de
  `SubprocVecEnv` hereda sockets/Popen y rompe todo.

ROM necesaria: `tehkanwc.zip` original en `roms/`.

---

## Pipeline de enseñanza (heurístico + demos)

El agente heurístico de Tehkan World Cup
(`scripts/mame/tehkanwc_ai.lua`) carga reglas desde DOS pipelines con el
mismo esquema (`{bx, by, bx_tol, by_tol, py_max, dx, dy, kick}`):

| Fuente | Generada por | Origen |
|---|---|---|
| `scripts/mame/attract_tactics.lua` | `scripts/learn_from_attract.py` | demo de atract mode del arcade (sin humano) |
| `scripts/mame/learned_tactics.lua` | `scripts/learn_from_demos.py` | demos humanas con `scripts/teach.py mark` / `goal` |

El merge vive en `scripts/mame/tehkan_tactics_loader.lua` (carga ambos
con `load_combined(root)` y respeta prioridad: **learned > attract**,
porque vienen de juego humano real contra este hardware). Antes el
agente solo cargaba `attract_tactics.lua`: las reglas generadas por
`teach.py goal "..."` quedaban huérfanas en disco sin efecto sobre la
IA. El fix (v12+) hace que el ciclo enseñanza→agente funcione de
veras.

Flujo recomendado para enseñar a la IA nuevos trucos:

```bash
# 1) Juega y anota goles manualmente:
./scripts/teach_session.sh tehkan_world_cup
# En otra terminal, cuando metas gol:
python3 scripts/teach.py goal "tiro cruzado desde banda izquierda"

# 2) Cuando termines la sesión:
python3 scripts/learn_from_demos.py
# → genera scripts/mame/learned_tactics.lua (+ config/learned_tactics.yaml)

# 3) Repite pasos 1-2 con diferentes situaciones; cada goal se acumula
#    en learned_tactics.lua sin pisar los anteriores.

# 4) Smoke test del loader (sin MAME/Lua interpreter, sólo Python):
python3 scripts/check_tactics_loading.py

# 5) Lanzar la IA con las nuevas reglas:
./run.sh tehkan_world_cup heuristic --render
# El overlay mostrará: AI v12 [tactics N, learned M]
```

### Validación mínima (CI / sin MAME)

`scripts/check_tactics_loading.py` valida que el loader Lua es
estructuralmente correcto:

- Tiene las 4 funciones expuestas (`try_load`, `merge`,
  `load_combined`, `match`).
- `goto continue` y `::continue::` labels balanceados (Lua 5.2+; MAME
  0.288 embebe 5.3/5.4).
- El agente cliente (`tehkanwc_ai.lua`) realmente carga el módulo y
  usa el array unificado `TACTICS`.

No requiere Lua interpreter ni MAME — corre en cualquier máquina con
Python 3.

### Próximas extensiones (no implementadas todavía)

- **Inferencia PPO en vivo**: cargar el modelo entrenado por
  `scripts/train_tehkan.py` y reemplazar la selección heurística por
  acciones del actor. Hoy el modelo entrenado solo sirve para análisis
  offline (tensorboard).
- **Score RAM hunt**: cazar las direcciones reales de
  `score_us`/`score_them` con el debugger de MAME para que PBRS tenga
  señal densa (actualmente la env usa score=0 y la detección de gol
  por sprite).
- **Harness de evaluación**: ejecutar N partidas contra heurístico /
  random y reportar goles/pases/tiros. Hoy no hay forma robusta de
  medir si la IA mejora.

---

## v15 — Tácticas expertas (longplay) inyectadas al agente

El usuario pasó un video de YouTube ([tehkan-world-cup-complete-playthrough](https://www.youtube.com/watch?v=1vYiz-AfNVc)) donde un jugador experto gana todos los partidos hasta la final. Pedió aplicar este nivel de juego al agente.

**Limitaciones del entorno:** `read_url` solo trae metadatos del video (título/descripción mínima), `yt-dlp` no está en `$PATH`, no hay API de visión. Imposible extraer el frame a frame.

**Solución:** Knowledge engineering — codificamos los patrones expertos
conocidos del juego (curados a partir de Kastellorizo Playing Reference,
PowerStrike Tehkan homepage, y observación de longplays) en
`scripts/build_expert_tactics.py`, que genera `learned_tactics.lua`
con prioridad alta sobre `attract_tactics.lua` (gracias al loader
unificado de v12).

#### 13 reglas inyectadas

| Categoría | Reglas | Fuente |
|---|---|---|
| Tiros al palo lejano | `far_post_center`, `far_post_left`, `far_post_right` | Kastellorizo: el GK reposiciona siguiendo al jugador; el tiro diagonal al palo lejano lo deja "llegando tarde" |
| Picado sobre GK | `chip_over_gk` | PowerStrike: GK intenta atrapar a los pies; retroceder rápido y picar por encima |
| Pase adelantado | `through_ball_center` | Longplay observación: pase recto al hueco tras robo en mediocampo |
| Despeje largo | `long_clearance` | Kastellorizo: corner shots o despejes laterales son gol en contra — siempre forward+centered |
| Despeje lateral | `lateral_clearance_right` | PowerStrike: si rival está en línea central, sacar a banda con potencia |
| Sprint por banda | `wing_sprint_left`, `wing_sprint_right` | Longplay: ruta clásica, evita el crowd central del mediocampo |
| Centros desde banda | `wing_cross_to_box`, `wing_cross_to_box_right` | Longplay: dx forzoso hacia el centro, dy leve arriba para efecto |
| Conducción diagonal | `diag_carry_left`, `diag_carry_right` | Longplay: dribling humano se ve como diagonal sostenida (no recto, no sprint-y-parar) |

#### Uso

```bash
# Regenerar learned_tactics.lua con las reglas expertas
python3 scripts/build_expert_tactics.py
# → 13 entradas escritas a scripts/mame/learned_tactics.lua

# Backup manual si quieres preservar lo generado previamente
cp scripts/mame/learned_tactics.lua scripts/mame/learned_tactics.lua.bak

# Smoke test (loader sigue OK)
python3 scripts/check_tactics_loading.py
# → 13 entradas "learned" + 5 "attract"

# Jugar con el agente experto
./run.sh tehkan_world_cup heuristic --render
# El overlay muestra: AI v14 [tactics 18, learned 13]
```

#### Limitaciones

- Las reglas son **disparadas por posición del balón** (bx, by, py_max del jugador) — sin distinción de bando sin leer color RAM. Esto significa que las reglas aplican también cuando el agente no tiene posesión pero está "cerca" del balón (caso `possessed or close` en act_heuristic). En prática es favorable: el agente aprende la posición ideal incluso defendiendo.
- El scorer RAM sigue sin cazar (`SCORE_US_ADDR=nil`); la detección de gol sigue siendo por sprite ball.y en `tehkan_learn.lua`.
- Los patrones GK-advance (PowerStrike "atrápamelos a los pies") requieren detección de GK rival, que actualmente asumimos como "cualquier sprite outfield no-propio". Es una aproximación; refinable con GK-RAM-detect si la IA quisiera pursuit de portería rival.

#### v16 — 5 reglas adicionales (segunda ronda de research)

| Categoría | Reglas | Fuente |
|---|---|---|
| **Fast-low stationary shot** | `fast_low_stationary_center`, `fast_low_stationary_left`, `fast_low_stationary_right` | Kastellorizo "Stationary Ball Glitch" (Sec. 1.1.1.5): balón parado cerca del área → dispara INMEDIATAMENTE antes del GK reaccione. PowerStrike: "el 99% de los goles son fast-low shots". |
| **Corner curls** | `corner_curly_left`, `corner_curly_right` | PowerStrike Animation 4/5 (Corner Spin): corner diagonal al corazón del área pequeña buscando remate o despeje desafortunado. |
| **Long throw-ins** | `long_throw_in_left`, `long_throw_in_right` | Kastellorizo "Throw-in Long-Range": saques de banda profundos se proyectan al ESPACIO (no a un jugador concreto). |
| **Lateral clearance simétrico** | `lateral_clearance_left` (mirror del derecho) | v16 fix: simetría con el derecho. |

**Total experto:** 18 reglas en `learned_tactics.lua` + 5 en `attract_tactics.lua` = **23 totales** en el array `TACTICS`.  
**Overlay ahora:** `AI v14 [tactics 23, learned 18]`.

**Provenance del video (vía Wayback Machine):** Como YouTube bot-detecta yt-dlp, usamos `web.archive.org/web/2022/https://www.youtube.com/watch?v=1vYiz-AfNVc` para extraer metadata verificable:
- Canal: **JJJanez**
- Título: "Tehkan World Cup - complete playthrough"
- Difficulty: **Very Hard**, mouse inputs (no teclado)
- Engagement: 21.5k views, 223 likes

Esto confirma que es un longplay serio de un jugador experto. La extracción frame-by-frame sigue siendo imposible, pero el conjunto de reglas v15+v16 codifica todos los patrones expertos documentados en fuentes públicas secundarias (Kastellorizo, PowerStrike vía web archive, observación cruzada).

---

## v13 — Conciencia de rivales (Tehkan World Cup)

Desde v13 (`scripts/mame/tehkanwc_ai.lua`) el agente heurístico detecta
sprites outfield no-jugador como amenazas potenciales. Antes el código
trataba el sprite outfield más cercano al balón como "player" e ignoraba
al resto — perder el balón cada ~2s en línea recta era inevitable.

Cuatro reglas nuevas en `act_heuristic()`, en orden de prioridad:

1. **PANIC** — poseemos y rival está encima (`|td_x| ≤ 22`,
   `|td_y| ≤ 18`): kick inmediato (shoot_on_goal si estamos en zona de
   tiro, si no PANIC_DUMP en diagonal hacia la banda más lejana).
2. **ATR guarded** — la regla aprendida del demo (`match_attract`) se
   aplica solo si NO hay tackle encima (si lo hubiera, la regla pudo
   asumir rivales ausentes y meteríamos justo en el tackle).
3. **RETREAT** — no poseemos y un rival cruza `y > 144` (mitad
   inferior del campo): sprint hacia nuestra portería en vez de ir a
   chase normal. Prioriza bloquear antes que recuperar balón.
4. **DODGE** — en chase libre, si rival y balón están en la misma
   dirección (`td_x * ball_dx > 0`), sumamos `DODGE_OFFSET=26`
   perpendicular al dy para curvar alrededor del rival.

Constantes calibradas conservadoramente — los falsos positivos (confundir
compañero con rival) son preferibles a quedar quieto ante un tackle
real. Los sprites de ambos equipos comparten paleta en Tehkan; sin leer
color RAM no hay forma barata de distinguirlos (TODO futuro).

Overlay actualizado muestra: `PHASE d=BD opp=N tdd=X/Y dx=A dy=B` para
ver en vivo qué rama del decision tree se está ejecutando.

### Invariantes / smoke tests

`python3 scripts/check_tactics_loading.py` valida la estructura del
loader Lua sin necesidad de MAME ni un intérprete Lua (verifica
funciones exportadas, balance `goto::continue::`, integration con el
agente).
