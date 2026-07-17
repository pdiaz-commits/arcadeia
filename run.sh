#!/usr/bin/env bash
# Uso: ./run.sh [juego] [agente] [--render]
#      ./run.sh tehkan_world_cup heuristic --render   # MAME + IA
set -euo pipefail
cd "$(dirname "$0")"

GAME="${1:-breakout}"
AGENT="${2:-random}"
RENDER=""
if [[ "${3:-}" == "--render" ]]; then
  RENDER="--render"
elif [[ "${3:-}" != "--headless" ]] && [[ "$(uname -s)" == "Darwin" ]]; then
  # En Mac, ventana por defecto (sin ella parece que la IA no juega).
  RENDER="--render"
fi

MAME_GAMES="tehkan_world_cup wonder_boy tecmo_world_cup atetris tehkanwc wboy twcup90 ghosts_n_goblins gngb outrun superman tapper frogger galaga windjammers pacman dig_dug moon_patrol blood_bros smash_tv sunset_riders"

for g in $MAME_GAMES; do
  if [[ "$GAME" == "$g" ]]; then
    if [[ ! -d .venv ]]; then
      python3 -m venv .venv
      source .venv/bin/activate
      pip install -q -r requirements.txt
    else
      source .venv/bin/activate
    fi
    echo "MAME IA → $GAME | Agente: $AGENT"
    exec python3 scripts/play_mame.py --game "$GAME" --agent "$AGENT" $RENDER
  fi
done

if [[ ! -d .venv ]]; then
  echo "Primera vez: creando entorno..."
  python3 -m venv .venv
  source .venv/bin/activate
  pip install -q -r requirements.txt
else
  source .venv/bin/activate
fi

echo "Juego: $GAME | Agente: $AGENT"
exec python3 scripts/play.py --game "$GAME" --agent "$AGENT" --episodes 3 $RENDER
