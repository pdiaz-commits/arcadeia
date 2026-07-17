-- Smash TV (smash, 1990 Williams) — agente heurístico v1
-- Objetivo: arena shooter — moverte, disparar en todas direcciones,
-- recoger power-ups, sobrevivir oleadas.
-- Controles: DUAL JOYSTICK — uno para movimiento, otro para dirección
-- de disparo. Botón de bomba.
-- En MAME: IN0=joystick P1 (movimiento), IN1=joystick P2 (disparo).

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
local in1 = ports[":IN1"]
local in2 = ports[":IN2"]

local fld_coin    = field(in0, 0x01)
local fld_start   = field(in0, 0x02)

-- Joystick 1 (movimiento)
local fld_mv_up   = field(in1, 0x01)
local fld_mv_down = field(in1, 0x02)
local fld_mv_left = field(in1, 0x04)
local fld_mv_right= field(in1, 0x08)

-- Joystick 2 (dirección de disparo)
local fld_fire_up   = field(in2, 0x01)
local fld_fire_down = field(in2, 0x02)
local fld_fire_left = field(in2, 0x04)
local fld_fire_right= field(in2, 0x08)

local fld_bomb = field(in1, 0x10)

local frame = 0
local boot_done = false

local function press(f, on)
    if f then f:set_value(on and 1 or 0) end
end

local function clear_all()
    press(fld_mv_up, false); press(fld_mv_down, false)
    press(fld_mv_left, false); press(fld_mv_right, false)
    press(fld_fire_up, false); press(fld_fire_down, false)
    press(fld_fire_left, false); press(fld_fire_right, false)
    press(fld_bomb, false)
end

local function boot_sequence()
    if frame == 90 then press(fld_coin, true)
    elseif frame == 100 then press(fld_coin, false)
    elseif frame == 140 then press(fld_start, true)
    elseif frame == 150 then press(fld_start, false)
    elseif frame == 180 then press(fld_start, true)
    elseif frame == 190 then press(fld_start, false)
    elseif frame == 300 then boot_done = true
    end
end

local function act_random()
    clear_all()
    local r = frame % 45
    if r < 5 then press(fld_mv_up, true)
    elseif r < 10 then press(fld_mv_down, true)
    elseif r < 15 then press(fld_mv_left, true)
    elseif r < 20 then press(fld_mv_right, true)
    elseif r < 25 then press(fld_fire_up, true)
    elseif r < 30 then press(fld_fire_down, true)
    elseif r < 35 then press(fld_fire_left, true)
    elseif r < 40 then press(fld_fire_right, true)
    end
end

-- Heurístico: moverse en un patrón circular por la arena, disparar
-- siempre hacia el centro. Smash TV es un arena shooter; disparar
-- constantemente y moverse evita ser acorralado.
local FIRE_DIR = 0

local function act_heuristic()
    clear_all()

    -- Disparar siempre en la dirección actual del ciclo
    FIRE_DIR = FIRE_DIR + 1
    local fd = (FIRE_DIR // 60) % 4
    if fd == 0 then press(fld_fire_right, true)
    elseif fd == 1 then press(fld_fire_down, true)
    elseif fd == 2 then press(fld_fire_left, true)
    elseif fd == 3 then press(fld_fire_up, true)
    end

    -- Moverse en un patrón circular por la arena
    local md = (frame // 90) % 4
    if md == 0 then press(fld_mv_right, true); press(fld_mv_up, true)
    elseif md == 1 then press(fld_mv_left, true); press(fld_mv_up, true)
    elseif md == 2 then press(fld_mv_left, true); press(fld_mv_down, true)
    elseif md == 3 then press(fld_mv_right, true); press(fld_mv_down, true)
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
