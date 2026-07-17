-- Snow Bros — agente heurístico
-- Puertos reales (Kaneko/Toaplan): P1 en :DSW1 (bits altos), moneda/start en :SYSTEM.

local ROOT = "/Users/pablo/Documents/arcade-ai"
local AGENT = "heuristic"

local dsw1 = manager.machine.ioport.ports[":DSW1"]
local sys = manager.machine.ioport.ports[":SYSTEM"]

local function field(port, mask)
    if not port then return nil end
    return port:field(mask)
end

local fld_coin = field(sys, 0x0400)
local fld_start = field(sys, 0x0100)
local fld_up = field(dsw1, 0x0100)
local fld_down = field(dsw1, 0x0200)
local fld_left = field(dsw1, 0x0400)
local fld_right = field(dsw1, 0x0800)
local fld_shot = field(dsw1, 0x1000)
local fld_jump = field(dsw1, 0x4000)

local frame = 0
local boot_done = false
local jump_cd = 0
local shot_cd = 0

local function press(f, on)
    if f then f:set_value(on and 1 or 0) end
end

local function clear_p1()
    press(fld_up, false)
    press(fld_down, false)
    press(fld_left, false)
    press(fld_right, false)
    press(fld_shot, false)
    press(fld_jump, false)
end

local function boot_sequence()
    clear_p1()
    -- Esperar fin del POST (RAM OK / OBJ OK / PLT OK) antes de moneda.
    if frame == 180 then press(fld_coin, true)
    elseif frame == 200 then press(fld_coin, false)
    elseif frame == 240 then press(fld_start, true)
    elseif frame == 300 then press(fld_start, false)
    elseif frame == 330 then press(fld_start, true)
    elseif frame == 380 then press(fld_start, false)
    elseif frame == 420 then boot_done = true
    end
end

local function act_heuristic()
    local right = frame % 90 < 45
    local left = not right
    local jump = jump_cd <= 0 and frame % 45 == 0
    local shot = shot_cd <= 0 and frame % 20 == 0
    if jump then jump_cd = 12 end
    if shot then shot_cd = 10 end
    if jump_cd > 0 then jump_cd = jump_cd - 1 end
    if shot_cd > 0 then shot_cd = shot_cd - 1 end
    press(fld_left, left)
    press(fld_right, right)
    press(fld_jump, jump)
    press(fld_shot, shot)
end

local function act_random()
    local r = math.random(0, 4)
    press(fld_left, r == 0)
    press(fld_right, r == 1)
    press(fld_jump, r == 2)
    press(fld_shot, r == 3)
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
