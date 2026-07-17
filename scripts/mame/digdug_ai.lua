-- Dig Dug (digdug, 1982 Namco) — agente heurístico v1
-- Objetivo: cavar túneles, reventar enemigos con la bomba.
-- Controles: joystick 4 direcciones + 1 botón (bomba/inflar).

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
local fld_up    = field(in0, 0x10)
local fld_down  = field(in0, 0x20)
local fld_left  = field(in0, 0x40)
local fld_right = field(in0, 0x80)
local fld_pump  = field(in0, 0x04)

local frame = 0
local boot_done = false

local function press(f, on)
    if f then f:set_value(on and 1 or 0) end
end

local function clear_p1()
    press(fld_up, false); press(fld_down, false)
    press(fld_left, false); press(fld_right, false)
    press(fld_pump, false)
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
    local r = frame % 33
    if r < 6 then press(fld_up, true)
    elseif r < 12 then press(fld_down, true)
    elseif r < 18 then press(fld_left, true)
    elseif r < 24 then press(fld_right, true)
    elseif r < 28 then press(fld_pump, true)
    end
end

-- Heurístico: cavar hacia abajo (estrategia segura en Dig Dug),
-- bombear periódicamente. Alternar izquierda/derecha para cubrir suelo.
local function act_heuristic()
    clear_p1()
    local phase = frame % 160
    if phase < 40 then
        press(fld_down, true)
        press(fld_left, true)
    elseif phase < 80 then
        press(fld_down, true)
        press(fld_right, true)
    elseif phase < 120 then
        press(fld_left, true)
    else
        press(fld_right, true)
    end
    -- Bombear cada ~30 frames
    if frame % 30 < 8 then
        press(fld_pump, true)
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
