-- Windjammers (windjamm, 1994 Data East) — agente heurístico v1
-- Objetivo: lanzar el frisbee a la portería rival, interceptar los del rival.
-- Controles: joystick 8 direcciones, 2 botones (lanzar/servir, pase/special).

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
local fld_btn1  = field(in0, 0x04)
local fld_btn2  = field(in0, 0x08)

local frame = 0
local boot_done = false

local function press(f, on)
    if f then f:set_value(on and 1 or 0) end
end

local function clear_p1()
    press(fld_up, false); press(fld_down, false)
    press(fld_left, false); press(fld_right, false)
    press(fld_btn1, false); press(fld_btn2, false)
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
    elseif r < 25 then press(fld_btn1, true)
    elseif r < 30 then press(fld_btn2, true)
    end
end

-- Heurístico: moverse en diagonal hacia la portería rival (arriba),
-- lanzar al llegar al tercio ofensivo.
local THROW_CD = 0

local function act_heuristic()
    clear_p1()
    if THROW_CD > 0 then THROW_CD = THROW_CD - 1 end

    -- Diagonal arriba-derecha siempre
    local phase = frame % 180
    if phase < 90 then
        press(fld_up, true)
        press(fld_right, true)
    else
        press(fld_up, true)
        press(fld_left, true)
    end

    -- Lanzar periódicamente
    if THROW_CD == 0 and frame % 60 < 5 then
        press(fld_btn1, true)
        THROW_CD = 20
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
