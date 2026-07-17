-- Frogger (frogger, 1981 Konami) — agente heurístico v1
-- Objetivo: cruzar la carretera y el río hasta la meta.
-- Controles: joystick 4 direcciones (↑↓←→), sin botones.

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

local frame = 0
local boot_done = false

local function press(f, on)
    if f then f:set_value(on and 1 or 0) end
end

local function clear_p1()
    press(fld_up, false); press(fld_down, false)
    press(fld_left, false); press(fld_right, false)
end

local function boot_sequence()
    if frame == 60 then press(fld_coin, true)
    elseif frame == 70 then press(fld_coin, false)
    elseif frame == 90 then press(fld_start, true)
    elseif frame == 100 then press(fld_start, false)
    elseif frame == 110 then press(fld_start, true)
    elseif frame == 120 then press(fld_start, false)
    elseif frame == 200 then boot_done = true
    end
end

local function act_random()
    local r = frame % 25
    clear_p1()
    if r < 5 then press(fld_up, true)
    elseif r < 10 then press(fld_down, true)
    elseif r < 15 then press(fld_left, true)
    elseif r < 20 then press(fld_right, true)
    end
end

-- Heurístico: avanzar hacia arriba (meta) esquivando. Frogger tiene
-- 5 carriles de carretera + 5 de río. El agente sube en ráfagas,
-- esperando entre carriles.
local HOP_FRAMES = 15
local WAIT_FRAMES = 8

local function act_heuristic()
    clear_p1()
    local phase = frame % (HOP_FRAMES + WAIT_FRAMES)
    if phase < HOP_FRAMES then
        press(fld_up, true)
    else
        -- Pequeño desplazamiento lateral para evitar tráfico
        if phase % 3 == 0 then press(fld_left, true)
        elseif phase % 3 == 1 then press(fld_right, true) end
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
