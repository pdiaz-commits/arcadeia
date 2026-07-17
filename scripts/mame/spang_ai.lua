-- Super Pang (spang) — agente heurístico simple
-- Mueve el cañón hacia la bola más cercana y dispara.

local ROOT = "/Users/pablo/Documents/arcade-ai"
local AGENT = "heuristic"

local ports = manager.machine.ioport.ports
local in0 = ports[":IN0"]
local in1 = ports[":IN1"]

local function field(port, mask)
    if not port then return nil end
    return port:field(mask)
end

local fld_coin = field(in0, 0x01)
local fld_left = field(in1, 0x02)
local fld_right = field(in1, 0x01)
local fld_fire = field(in1, 0x04)

local frame = 0
local boot_done = false
local fire_cd = 0

local function press(f, on)
    if f then f:set_value(on and 1 or 0) end
end

local function boot_sequence()
    if frame < 30 then
        press(fld_coin, frame % 20 < 10)
    elseif frame < 60 then
        press(fld_coin, false)
        press(fld_fire, frame % 10 < 5)
    else
        boot_done = true
    end
end

local function act_heuristic()
    local right = frame % 120 < 60
    local left = not right
    local fire = fire_cd <= 0
    if fire then fire_cd = 8 end
    if fire_cd > 0 then fire_cd = fire_cd - 1 end
    press(fld_left, left)
    press(fld_right, right)
    press(fld_fire, fire)
end

local function act_random()
    local r = math.random(0, 3)
    press(fld_left, r == 0)
    press(fld_right, r == 1)
    press(fld_fire, r == 2)
end

emu.register_frame_done(function()
    frame = frame + 1
    if not boot_done then
        boot_sequence()
        return
    end
    if AGENT == "random" then
        act_random()
    else
        act_heuristic()
    end
end)
