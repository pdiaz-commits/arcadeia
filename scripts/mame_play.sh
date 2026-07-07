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
  pacman)                GAME_ID="pacman" ;;
  tempest)               GAME_ID="tempest" ;;
  dkong)                 GAME_ID="dkong" ;;
  *)
    echo "Juego MAME desconocido: $GAME_KEY"
    echo "Usa: atetris, tehkan_world_cup, tecmo_world_cup, pacman, tempest, dkong"
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
exec ./bin/mame "$GAME_ID" -rompath "$ROMPATH"
