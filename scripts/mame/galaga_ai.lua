-- Galaga (galaga, 1981 Namco) — agente heurístico v1
-- Objetivo: destruir formaciones de galagas, esquivar ataques.
-- Controles: joystick izquierda/derecha, 1 botón (disparo).

local ROOT = "/Users/pablo/Documents/arcade-ai"
local AGENT = "heuristic"

local function field(port, mask)
    if not port then return nil end
    local ok, f = pcall(function() return port:field(mask) end)
    if ok then return f end
    return nil
end

local ports = manager.machine.ioport.ports
local in0 = ports[":IN0"]

local fld_coin  = field(in0, 0x01)
local fld_start = field(in0, 0x02)
local fld_left  = field(in0, 0x04)
local fld_right = field(in0, 0x08)
local fld_fire  = field(in0, 0x10)

local frame = 0
local boot_done = false
local dir_timer = 0

local function press(f, on)
    if f then f:set_value(on and 1 or 0) end
end

local function clear_p1()
    press(fld_left, false); press(fld_right, false)
    press(fld_fire, false)
end

local function boot_sequence()
    if frame == 60 then press(fld_coin, true)
    elseif frame == 70 then press(fld_coin, false)
    elseif frame == 100 then press(fld_start, true)
    elseif frame == 110 then press(fld_start, false)
    elseif frame == 140 then press(fld_start, true)
    elseif frame == 150 then press(fld_start, false)
    elseif frame == 300 then boot_done = true
    end
end

local function act_random()
    clear_p1()
    local r = frame % 37
    if r < 10 then press(fld_left, true)
    elseif r < 20 then press(fld_right, true)
    end
    if frame % 3 == 0 then press(fld_fire, true) end
end

-- Heurístico: moverse de lado a lado continuamente, disparar siempre.
-- Galaga tiene formaciones que se acercan en patrones; moverse evita
-- el fuego enemigo mientras se dispara hacia arriba.
local function act_heuristic()
    clear_p1()
    dir_timer = dir_timer + 1
    local sweep = 90
    local phase = dir_timer % (sweep * 2)
    if phase < sweep then
        press(fld_left, true)
    else
        press(fld_right, true)
    end
    -- Siempre disparar (cada 3 frames para rate-limit)
    if frame % 3 == 0 then
        press(fld_fire, true)
    end
end

local function draw_overlay()
    local screen = manager.machine.screens[":screen"]
    if not screen then return end
    local mode = boot_done and ("AI " .. AGENT) or "AI boot..."
    screen:draw_text(4, 4, string.format("%s  f%d", mode, frame), 0xffffffff, 0xff000000)
end

emu.register_frame_done(function()
    frame = frame + 1
    if not boot_done then boot_sequence(); draw_overlay(); return end
    if AGENT == "random" then act_random() else act_heuristic() end
    draw_overlay()
end)
