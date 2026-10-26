#!/usr/bin/env bash
# Juega N partidos de Tehkan World Cup sin ventana y muestra el marcador.
# Uso: ./scripts/eval_tehkan.sh [agente] [partidos]
#      ./scripts/eval_tehkan.sh heuristic 12   # v19 (actual)
#      ./scripts/eval_tehkan.sh v18 12         # versión antigua
# Marcador leído de RAM: 0xc100 = rojo (IA), 0xc101 = máquina.
# Solo cuenta el primer partido (si el rojo gana, el juego empieza otro).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
AGENT="${1:-heuristic}"
N="${2:-6}"
TMP="$(mktemp -d)"
export DYLD_FRAMEWORK_PATH="$ROOT/vendor/Frameworks"
# sin ventanas ni robo de foco en macOS
export SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy

sed -e "s|^local ROOT = \".*|local ROOT = \"$ROOT\"|" \
    -e "s|^local AGENT = \".*|local AGENT = \"$AGENT\"|" \
    scripts/mame/tehkanwc_ai.lua > "$TMP/agent.lua"

for i in $(seq 1 "$N"); do
  D=$((i + 1))   # distinto retraso de arranque → partido distinto
  cat > "$TMP/w$i.lua" <<LUA
dofile("$TMP/agent.lua")
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local n, us, them, done = 0, 0, 0, false
emu.register_frame_done(function() n = n + 1
  if n > 900 and not done then
    local a, b = mem:read_u8(0xc100), mem:read_u8(0xc101)
    if a + b < us + them then done = true
    elseif a < 20 and b < 20 then us, them = a, b end
  end
  if n % 600 == 0 then local f = _G.io.open("$TMP/s$i.txt", "w"); f:write(us .. " " .. them .. "\n"); f:close() end
end)
LUA
  ./vendor/mame/mame0288-arm64/mame tehkanwc -rompath roms -cfg_directory cfg \
    -autoboot_script "$TMP/w$i.lua" -autoboot_delay "$D" -video none -sound none \
    -nothrottle -keyboardprovider none -mouseprovider none -joystickprovider none -seconds_to_run $((150 + D)) -skip_gameinfo >/dev/null 2>&1 &
done
wait

cat "$TMP"/s*.txt | awk -v a="$AGENT" '{u+=$1; t+=$2; if($1>$2)w++; else if($1==$2)e++; else l++
  printf "  partido %d: rojo %d - máquina %d\n", NR, $1, $2}
  END {printf "%s: %d partidos · goles %d-%d · ganados %d, empatados %d, perdidos %d\n", a, NR, u, t, w+0, e+0, l+0}'
rm -rf "$TMP"
