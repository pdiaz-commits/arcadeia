#!/usr/bin/env bash
# Lanza un juego MAME manualmente (requiere ROM en roms/)
# Uso: ./scripts/mame_play.sh tecmo_world_cup
#      ./scripts/mame_play.sh atetris
set -euo pipefail
cd "$(dirname "$0")/.."

GAME_KEY="${1:-atetris}"
ROMPATH="roms"

case "$GAME_KEY" in
  atetris|tetris_mame)   GAME_ID="atetris" ;;
  tecmo_world_cup|twcup90|tecmo) GAME_ID="twcup90" ;;
  tehkan_world_cup|tehkanwc|tehkan) GAME_ID="tehkanwc" ;;
  wonder_boy|wboy)               GAME_ID="wboy" ;;
  ghosts_n_goblins|gngb|gng)     GAME_ID="gngb" ;;
  outrun)                GAME_ID="outrun" ;;
  superman)              GAME_ID="superman" ;;
  pacman)                GAME_ID="pacman" ;;
  tempest)               GAME_ID="tempest" ;;
  dkong)                 GAME_ID="dkong" ;;
  tapper|tapper_mame)        GAME_ID="tapper" ;;
  frogger)               GAME_ID="frogger" ;;
  galaga|galaga_mame)    GAME_ID="galaga" ;;
  windjammers|windjamm)  GAME_ID="windjamm" ;;
  pacman_mame)           GAME_ID="pacman" ;;
  dig_dug|digdug)        GAME_ID="digdug" ;;
  moon_patrol|moonpatl)  GAME_ID="moonpatl" ;;
  blood_bros|bloodbro)   GAME_ID="bloodbro" ;;
  smash_tv|smash)        GAME_ID="smash" ;;
  sunset_riders|sunsetr) GAME_ID="sunsetr" ;;
  *)
    echo "Juego MAME desconocido: $GAME_KEY"
    echo "Usa: atetris, tehkan_world_cup, tecmo_world_cup, tapper, frogger, galaga, windjammers, pacman_mame, dig_dug, moon_patrol, blood_bros, smash_tv, sunset_riders, pacman, tempest, dkong, outrun, superman"
    exit 1
    ;;
esac

ROM_FILE="roms/${GAME_ID}.zip"
if [[ ! -f "$ROM_FILE" ]]; then
  echo "Falta ROM: $ROM_FILE"
  echo "Coloca el zip legal en arcade-ai/roms/"
  exit 1
fi

echo "MAME → $GAME_ID ($GAME_KEY)"
echo "  Plugins: hiscore + autofire (juego manual)"
echo "  (sin IA — solo manual. Para IA: ./run.sh $GAME_KEY heuristic --render)"
PLUGIN_ARGS=()
ROOT="$(pwd)"
PLUGINS="$ROOT/vendor/mame/mame0288-arm64/plugins"
if [[ -d "$PLUGINS" ]]; then
  PLUGIN_ARGS+=(
    -pluginspath "$PLUGINS"
    -homepath "$ROOT"
    -inipath "$ROOT/cfg;."
    -plugin "hiscore,autofire,inputmacro"
  )
fi
# Wonder Boy (wboy) mappings live in cfg/wboy.cfg (auto-load).
# X=jump, Z=shoot, arrows. NOTE: -ctrlr wboy_mac is intentionally removed
# (was overriding the project cfg with legacy Option/Ctrl codes that fail
# on macOS SDL2). The legacy cfg/wboy_mac.cfg file is kept as historical
# reference only — do not load it.
exec ./bin/mame "$GAME_ID" -rompath "$ROMPATH" -cfg_directory cfg -window "${PLUGIN_ARGS[@]}"
