#!/usr/bin/env bash
# Modo enseñanza: TÚ juegas, se graban movimientos para la IA.
# Tehkan WC: MANTÉN pulsada la diagonal (↑+← o ↑+→), no un solo toque.
# Uso: ./scripts/teach_session.sh [tehkan_world_cup|wonder_boy]
set -euo pipefail
cd "$(dirname "$0")/.."

GAME_KEY="${1:-tehkan_world_cup}"
case "$GAME_KEY" in
  tehkan_world_cup|tehkanwc) GAME_ID="tehkanwc"; LUA="record_play.lua" ;;
  wonder_boy|wboy)           GAME_ID="wboy";     LUA="wboy_record_play.lua" ;;
  ghosts_n_goblins|gngb|gng) GAME_ID="gngb";      LUA="gngb_record_play.lua" ;;
  outrun)                    GAME_ID="outrun";    LUA="outrun_record_play.lua" ;;
  superman)                  GAME_ID="superman";  LUA="superman_record_play.lua" ;;
  tapper)                    GAME_ID="tapper";    LUA="tapper_record_play.lua" ;;
  frogger)                   GAME_ID="frogger";   LUA="frogger_record_play.lua" ;;
  galaga)                    GAME_ID="galaga";    LUA="galaga_record_play.lua" ;;
  windjammers|windjamm)      GAME_ID="windjamm";  LUA="windjammers_record_play.lua" ;;
  pacman)                    GAME_ID="pacman";    LUA="pacman_record_play.lua" ;;
  dig_dug|digdug)            GAME_ID="digdug";    LUA="digdug_record_play.lua" ;;
  moon_patrol|moonpatl)      GAME_ID="moonpatl";  LUA="moonpatl_record_play.lua" ;;
  blood_bros|bloodbro)       GAME_ID="bloodbro";  LUA="bloodbro_record_play.lua" ;;
  smash_tv|smash)            GAME_ID="smash";     LUA="smash_record_play.lua" ;;
  sunset_riders|sunsetr)     GAME_ID="sunsetr";   LUA="sunsetr_record_play.lua" ;;
  *)
    echo "Juego no soportado: $GAME_KEY"
    echo "Usa: tehkan_world_cup | wonder_boy | ghosts_n_goblins | outrun | superman | tapper | frogger | galaga | windjammers | pacman | dig_dug | moon_patrol | blood_bros | smash_tv | sunset_riders"
    exit 1
    ;;
esac

echo "=== Modo enseñanza — $GAME_KEY ==="
echo ""
if [[ "$GAME_ID" == "tehkanwc" ]]; then
  echo "  TEHKAN WORLD CUP — trackball"
  echo "  • Mantén pulsada la DIAGONAL: ↑+← o ↑+→ (no sueltes al instante)"
  echo "  • O arrastra el ratón en diagonal (flag -mouse)"
  echo "  • Botón disparo: Ctrl / click"
  echo "  • Debe verse REC+TEACH arriba a la izquierda"
  echo ""
fi
echo "  • Otra terminal:"
echo "      python3 scripts/teach.py status"
echo "      python3 scripts/teach.py mark \"paso...\""
echo "      python3 scripts/teach.py goal \"gol...\""
echo "  • Al cerrar (ESC):"
echo "      python3 scripts/learn_from_demos.py"
echo ""

mkdir -p logs/demos
EXTRA=(-trackball_device keyboard)
if [[ "$GAME_ID" == "tehkanwc" ]]; then
  EXTRA+=(-mouse)
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_ARGS=()
PLUGINS="$ROOT/vendor/mame/mame0288-arm64/plugins"
if [[ -d "$PLUGINS" ]]; then
  PLUGIN_ARGS+=(
    -pluginspath "$PLUGINS"
    -homepath "$ROOT"
    -inipath "$ROOT/cfg;."
    -plugin "hiscore,console"
  )
fi
exec ./bin/mame "$GAME_ID" -rompath roms \
  -cfg_directory cfg \
  -autoboot_script "scripts/mame/$LUA" \
  -autoboot_delay 1 \
  -window "${PLUGIN_ARGS[@]}" "${EXTRA[@]}"
