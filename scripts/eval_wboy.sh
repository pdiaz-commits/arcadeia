#!/usr/bin/env bash
# Mide el agente de Wonder Boy: juega N partidas sin ventana y reporta la
# puntuacion alcanzada antes del primer game over.
# Verificado por sonda (2026-10-26): vidas en 0xc302 (empieza 3, baja a 0),
# score BCD en 0xc304 (alto) : 0xc305 (bajo), se resetea en el game over.
# El valor es el par BCD (score real del juego ~x100); sirve como fitness relativo.
# Uso: ./scripts/eval_wboy.sh [partidas]
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
N="${1:-6}"
TMP="$(mktemp -d)"
export DYLD_FRAMEWORK_PATH="$ROOT/vendor/Frameworks"
# SDL dummy: MAME no toca la pantalla del Mac
export SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy

for i in $(seq 1 "$N"); do
  D=$((i + 1))   # distinto retraso de arranque -> partida distinta
  cat > "$TMP/w$i.lua" <<LUA
dofile("$ROOT/scripts/mame/wboy_ai.lua")
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local function bcd(b) return math.floor(b / 16) * 10 + b % 16 end
local function score() return bcd(mem:read_u8(0xc304)) * 100 + bcd(mem:read_u8(0xc305)) end
local n, best, done, alive = 0, 0, false, false
emu.register_frame_done(function() n = n + 1
  if n < 300 then return end                 -- dejar arrancar
  local lv = mem:read_u8(0xc302)
  if lv > 0 and lv <= 3 then alive = true end -- partida en marcha
  if not done then
    if alive and lv == 0 then done = true      -- primer game over: congelar
    else local s = score(); if s > best then best = s end end
  end
  if n % 300 == 0 then local f = _G.io.open("$TMP/s$i.txt", "w"); f:write(best .. "\n"); f:close() end
end)
LUA
  ./vendor/mame/mame0288-arm64/mame wboy -rompath roms -cfg_directory cfg \
    -autoboot_script "$TMP/w$i.lua" -autoboot_delay "$D" -video none -sound none \
    -nothrottle -keyboardprovider none -mouseprovider none -joystickprovider none \
    -seconds_to_run $((90 + D)) -skip_gameinfo >/dev/null 2>&1 &
done
wait

cat "$TMP"/s*.txt | awk '{s += $1; if ($1 > mx) mx = $1; n++; printf "  partida %d: score %d\n", NR, $1}
  END {if (n > 0) printf "wboy: %d partidas - score medio %.0f - mejor %d\n", n, s / n, mx}'
rm -rf "$TMP"
