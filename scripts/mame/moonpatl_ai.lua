-- Moon Patrol (moonpatl, 1982 Irem) — agente heurístico v1
-- Objetivo: conducir el lunar rover hacia la derecha, saltar obstáculos,
-- disparar a enemigos aéreos y terrestres.
-- Controles: joystick izquierda/derecha, botón salto, botón disparo.

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
local fld_left   = field(in0, 0x10)
local fld_right  = field(in0, 0x20)
local fld_jump   = field(in0, 0x40)
local fld_fire   = field(in0, 0x80)

local frame = 0
local boot_done = false

local function press(f, on)
    if f then f:set_value(on and 1 or 0) end
end

local function clear_p1()
    press(fld_left, false); press(fld_right, false)
    press(fld_jump, false); press(fld_fire, false)
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
    local r = frame % 29
    if r < 6 then press(fld_right, true)
    elseif r < 10 then press(fld_left, true)
    elseif r < 16 then press(fld_jump, true)
    elseif r < 22 then press(fld_fire, true)
    end
end

-- Heurístico: avanzar siempre a la derecha, saltar y disparar a
-- intervalos regulares (Moon Patrol tiene cráteres y enemigos
-- periódicos). Sin lectura de sprite RAM, usamos temporización.
local JUMP_CD = 0
local FIRE_CD = 0

local function act_heuristic()
    clear_p1()
    if JUMP_CD > 0 then JUMP_CD = JUMP_CD - 1 end
    if FIRE_CD > 0 then FIRE_CD = FIRE_CD - 1 end

    -- Siempre avanzar
    press(fld_right, true)

    -- Saltar cada ~80 frames
    if JUMP_CD == 0 and (frame % 80) < 8 then
        press(fld_jump, true)
        JUMP_CD = 15
    end

    -- Disparar cada ~15 frames
    if FIRE_CD == 0 then
        press(fld_fire, true)
        FIRE_CD = 10
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
