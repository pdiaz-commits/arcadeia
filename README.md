# Arcade AI

Juegos arcade clásicos + agentes de IA con distintos niveles (random → heurístico → reinforcement learning).

Inspirado en [Columns AI / machinelearning.pablodiaz.eu](https://machinelearning.pablodiaz.eu).

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

En producción corre como servicio `systemd` (`deploy/arcadeia-web.service`) tras
un reverse proxy `nginx` con TLS de Let's Encrypt/Certbot — mismo patrón que
[Columns AI](https://machinelearning.pablodiaz.eu). Ver `deploy/README.md` para
los pasos exactos.

## Requisitos

- Python 3.9+
- ROMs Atari: incluidas vía `gymnasium[atari,accept-rom-license]`
- ROMs MAME: debes poseerlas legalmente

## Próximos pasos

1. Entrenar DQN/PPO con Stable Baselines3
2. Integrar MAME + Lua (patrón ArcadeAI) para Tempest / Pac-Man cabinet
3. Publicar demo web al estilo Columns AI
