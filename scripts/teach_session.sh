#!/usr/bin/env bash
# Modo enseñanza: TÚ juegas, se graban movimientos para la IA.
# Uso: ./scripts/teach_session.sh [tehkan_world_cup|wonder_boy]
set -euo pipefail
cd "$(dirname "$0")/.."

GAME_KEY="${1:-tehkan_world_cup}"
case "$GAME_KEY" in
  tehkan_world_cup|tehkanwc) GAME_ID="tehkanwc"; LUA="record_play.lua" ;;
  wonder_boy|wboy)           GAME_ID="wboy";     LUA="wboy_record_play.lua" ;;
  *)
    echo "Juego no soportado: $GAME_KEY"
    echo "Usa: tehkan_world_cup | wonder_boy"
    exit 1
    ;;
esac

echo "=== Modo enseñanza — $GAME_KEY ==="
echo ""
echo "  • Debe verse REC+TEACH arriba a la izquierda"
echo "  • Otra terminal:"
echo "      python3 scripts/teach.py status"
echo "      python3 scripts/teach.py mark \"paso...\""
echo "      python3 scripts/teach.py goal \"gol...\""
echo "  • Al cerrar (ESC):"
echo "      python3 scripts/learn_from_demos.py"
echo ""

mkdir -p logs/demos
exec ./bin/mame "$GAME_ID" -rompath roms \
  -cfg_directory cfg \
  -autoboot_script "scripts/mame/$LUA" \
  -autoboot_delay 1 \
  -window
