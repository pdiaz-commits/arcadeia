-- Blood Bros. (bloodbro, 1990 TAD) — agente heurístico v1
-- Objetivo: shooter western — avanzar, disparar a enemigos, esquivar balas.
-- Controles: joystick 8 direcciones, 2 botones (disparo, bomba).

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

local fld_coin   = field(in0, 0x01)
local fld_start  = field(in0, 0x02)
local fld_up     = field(in0, 0x10)
local fld_down   = field(in0, 0x20)
local fld_left   = field(in0, 0x40)
local fld_right  = field(in0, 0x80)
local fld_fire   = field(in0, 0x04)
local fld_bomb   = field(in0, 0x08)

local frame = 0
local boot_done = false

local function press(f, on)
    if f then f:set_value(on and 1 or 0) end
end

local function clear_p1()
    press(fld_up, false); press(fld_down, false)
    press(fld_left, false); press(fld_right, false)
    press(fld_fire, false); press(fld_bomb, false)
end

local function boot_sequence()
    if frame == 60 then press(fld_coin, true)
    elseif frame == 70 then press(fld_coin, false)
    elseif frame == 100 then press(fld_start, true)
    elseif frame == 110 then press(fld_start, false)
    elseif frame == 200 then boot_done = true
    end
end

local function act_random()
    clear_p1()
    local r = frame % 37
    if r < 5 then press(fld_up, true)
    elseif r < 10 then press(fld_down, true)
    elseif r < 15 then press(fld_left, true)
    elseif r < 20 then press(fld_right, true)
    elseif r < 26 then press(fld_fire, true)
    elseif r < 30 then press(fld_bomb, true)
    end
end

-- Heurístico: avanzar a la derecha, disparar constantemente,
-- saltar/bombas periódicas.
local function act_heuristic()
    clear_p1()
    press(fld_right, true)

    -- Disparar siempre que podamos
    if frame % 4 < 2 then
        press(fld_fire, true)
    end

    -- Bombas cada ~150 frames
    if frame % 150 < 5 then
        press(fld_bomb, true)
    end

    -- Micro movimientos verticales para esquivar
    if frame % 40 < 10 then
        press(fld_up, true)
    elseif frame % 40 < 20 then
        press(fld_down, true)
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
