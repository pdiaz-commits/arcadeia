-- Pac-Man (pacman, 1980 Namco) — agente heurístico v1
-- Objetivo: comer puntos, evitar fantasmas, comer power-pellets.
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
local sw = ports[":SW0"]
local p1 = ports[":P1"]

local fld_coin  = field(sw, 0x01)
local fld_start = field(sw, 0x04)
local fld_up    = field(p1, 0x01)
local fld_down  = field(p1, 0x02)
local fld_left  = field(p1, 0x04)
local fld_right = field(p1, 0x08)

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
    elseif frame == 100 then press(fld_start, true)
    elseif frame == 110 then press(fld_start, false)
    elseif frame == 200 then boot_done = true
    end
end

local function act_random()
    clear_p1()
    local r = frame % 25
    if r < 5 then press(fld_up, true)
    elseif r < 10 then press(fld_down, true)
    elseif r < 15 then press(fld_left, true)
    elseif r < 20 then press(fld_right, true)
    end
end

-- Heurístico simple: girar a la derecha en cada intersección (estrategia
-- clásica para pac-man: seguir la pared derecha para cubrir todo el mapa).
-- Como no podemos detectar intersecciones sin leer la RAM, alternamos
-- direcciones en un ciclo fijo que tiende a cubrir el laberinto.
local function act_heuristic()
    clear_p1()
    local phase = frame % 120
    if phase < 40 then
        press(fld_right, true)
    elseif phase < 70 then
        press(fld_up, true)
    elseif phase < 100 then
        press(fld_left, true)
    else
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
