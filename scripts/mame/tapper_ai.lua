-- Tapper (tapper, 1983 Bally/Midway) — agente heurístico v1
-- Objetivo: servir cervezas, recoger vacíos, subir propinas.
-- Controles: joystick 4 posiciones (↑↓←→) + botón de servir.
-- El juego tiene 4 posiciones de barra; el jugador se mueve entre ellas.

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
local in2 = ports[":IN2"]

local fld_coin  = field(in2, 0x01)
local fld_start = field(in2, 0x04)
local fld_up    = field(in0, 0x01)
local fld_down  = field(in0, 0x02)
local fld_left  = field(in0, 0x04)
local fld_right = field(in0, 0x08)
local fld_btn1  = field(in0, 0x10)

local frame = 0
local boot_done = false

local function press(f, on)
    if f then f:set_value(on and 1 or 0) end
end

local function clear_p1()
    press(fld_up, false); press(fld_down, false)
    press(fld_left, false); press(fld_right, false)
    press(fld_btn1, false)
end

local function boot_sequence()
    if frame == 60 then press(fld_coin, true)
    elseif frame == 70 then press(fld_coin, false)
    elseif frame == 90 then press(fld_start, true)
    elseif frame == 100 then press(fld_start, false)
    elseif frame == 200 then boot_done = true
    end
end

local function act_random()
    local r = frame % 31
    clear_p1()
    if r < 6 then press(fld_left, true)
    elseif r < 12 then press(fld_right, true)
    elseif r < 16 then press(fld_up, true)
    elseif r < 20 then press(fld_down, true)
    elseif r < 26 then press(fld_btn1, true)
    end
end

-- Heurístico: moverse entre posiciones del bar, servir y recoger.
-- Tapper tiene ~4 posiciones de barra. El agente cicla entre izquierda
-- y derecha, sirviendo periódicamente.
local CYCLE_FRAMES = 60
local SERVE_FRAMES = 25

local function act_heuristic()
    clear_p1()
    local phase = frame % (CYCLE_FRAMES * 2)
    if phase < CYCLE_FRAMES then
        press(fld_right, true)
    else
        press(fld_left, true)
    end
    if frame % SERVE_FRAMES < 5 then
        press(fld_btn1, true)
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
