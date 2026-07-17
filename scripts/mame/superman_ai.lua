-- Superman (Taito, 1988) — agente heurístico EXPERIMENTAL / best-effort
--
-- IMPORTANTE: el dump de ROM disponible para este juego sigue INCOMPLETO.
-- El nuevo dump aporta las 11 ROMs de placa (incluida b61_11.m11, la eprom
-- de sonido que antes faltaba), pero AÚN falta 1 de las 12 ROMs requeridas
-- por el set "superman" de MAME 0.288: cchip_upd78c11.bin (4096 bytes,
-- CRC 43021521) -- firmware interno de la MCU uPD78C11 del C-Chip de
-- protección de Taito, expuesto por MAME como dispositivo "cchip". MAME
-- aborta el arranque con "Required files are missing" mientras no se
-- aporte esa ROM (dentro de superman.zip o en un cchip.zip en el rompath).
-- `mame -verifyroms superman` sigue dando "BAD", así que este script NO ha
-- podido arrancarse ni verificarse localmente contra el hardware real; se
-- ha escrito a partir del código fuente del driver de
-- MAME (taito/taito_x.cpp) pero sin poder confirmar en ejecución los
-- nombres exactos de los campos de ioport ni el layout de la RAM de
-- sprites (chip de sprites Seta/Taito X1-001, RAM Y en 0xd00000-0xd005ff,
-- control en 0xd00600). Por eso, a diferencia de tehkanwc_ai.lua /
-- wboy_ai.lua / outrun_ai.lua / atetris_ai.lua, NO intentamos leer la RAM
-- de sprites para detectar obstáculos: sería pura especulación no
-- verificable. En su lugar usamos un heurístico "runner" simple y honesto:
-- caminar a la derecha, saltar/atacar a intervalos fijos para tener
-- alguna chance de superar obstáculos y enemigos genéricos de un
-- plataformas de la época, y reintentar el arranque (moneda + botón)
-- periódicamente por si el primer intento no fue reconocido.
--
-- Superman ES un videojuego de acción/plataformas (Taito, hardware
-- "Taito X System" con C-Chip), NO una máquina de pinball, así que no
-- aplica el caso especial de pinball descrito para este proyecto.

local ROOT = "/Users/pablo/Documents/arcade-ai"
local AGENT = "heuristic"

local ports = manager.machine.ioport.ports
local in2 = ports[":IN2"]
local in0 = ports[":IN0"]

local fld_coin1 = in2 and in2:field(0x01)

-- Nombres estándar que MAME asigna a TAITO_JOY_UDLR_2_BUTTONS_START; se
-- resuelven de forma defensiva (pcall/nil-check) porque no se ha podido
-- verificar en ejecución con el dump incompleto.
local function safe_field(port, name)
    if not port then return nil end
    local ok, f = pcall(function() return port.fields[name] end)
    if ok then return f end
    return nil
end

local fld_right = safe_field(in0, "P1 Right")
local fld_left = safe_field(in0, "P1 Left")
local fld_up = safe_field(in0, "P1 Up")
local fld_down = safe_field(in0, "P1 Down")
local fld_b1 = safe_field(in0, "P1 Button 1")
local fld_b2 = safe_field(in0, "P1 Button 2")

local frame = 0
local boot_attempts = 0

local function press(field, on)
    if field then field:set_value(on and 1 or 0) end
end

local function boot_sequence()
    -- Reintenta moneda + botón cada ~3s por si el primer intento no cuajó
    -- (sin poder verificar el arranque real, mantenemos varios reintentos).
    local phase = frame % 180
    if phase == 0 then boot_attempts = boot_attempts + 1 end
    if phase == 10 then press(fld_coin1, true)
    elseif phase == 20 then press(fld_coin1, false)
    elseif phase == 40 then press(fld_b1, true)
    elseif phase == 50 then press(fld_b1, false)
    end
end

local function act_random()
    local r = frame % 37
    press(fld_right, r < 20)
    press(fld_left, false)
    press(fld_up, r == 25 or r == 26)
    press(fld_b1, r == 30)
    press(fld_b2, false)
end

-- Heurístico "runner" simple: avanzar a la derecha, saltar (arriba, en
-- plataformas Taito de esta época el salto suele ser "arriba" o un botón
-- dedicado) a intervalos regulares, y atacar (botón 1) periódicamente para
-- despejar enemigos genéricos por delante. Sin lectura de sprites no
-- podemos reaccionar a amenazas reales; es deliberadamente simple.
local JUMP_PERIOD = 50
local ATTACK_PERIOD = 27

local function act_heuristic()
    press(fld_right, true)
    press(fld_left, false)

    local jump_phase = frame % JUMP_PERIOD
    press(fld_up, jump_phase < 6)

    local attack_phase = frame % ATTACK_PERIOD
    press(fld_b1, attack_phase < 4)
    press(fld_b2, false)
end

local function draw_overlay()
    local screen = manager.machine.screens[":screen"]
    if not screen then return end
    screen:draw_text(4, 4,
        string.format("AI %s (EXPERIMENTAL) f%d boot#%d", AGENT, frame, boot_attempts),
        0xffffffff, 0xff000000)
end

emu.register_frame_done(function()
    frame = frame + 1
    boot_sequence()
    if AGENT == "random" then act_random() else act_heuristic() end
    draw_overlay()
end)
