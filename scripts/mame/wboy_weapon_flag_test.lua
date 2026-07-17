-- Log RAM 0xc07e/c07f durante recogida de hacha
local ROOT = "/Users/pablo/Documents/arcade-ai"
local LOG = ROOT .. "/logs/wboy_weapon_flag.log"
local sys = manager.machine.ioport.ports[":SYSTEM"]
local p1 = manager.machine.ioport.ports[":P1"]
local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]
local SPRITE_BASE = 0xd000
local frame = 0

local function press_sys(m, on)
    local f = sys:field(m)
    if f then f:set_value(on and 1 or 0) end
end

local function px()
    for offs = 0, 0x7f8, 8 do
        local c = mem:read_u8(SPRITE_BASE + offs)
        if c == 0x83 or c == 0x82 then
            return mem:read_u8(SPRITE_BASE + offs + 2) - 128
        end
    end
    return nil
end

local function axe_sprite()
    for offs = 0, 0x7f8, 8 do
        local c = mem:read_u8(SPRITE_BASE + offs)
        if c == 0x80 or c == 0x81 then
            return mem:read_u8(SPRITE_BASE + offs + 2) - 128
        end
    end
    return nil
end

os.execute("mkdir -p " .. ROOT .. "/logs")
local logf = io.open(LOG, "w")

emu.register_frame_done(function()
    frame = frame + 1
    if frame == 30 then press_sys(0x01, true)
    elseif frame == 38 then press_sys(0x01, false)
    elseif frame == 70 then press_sys(0x10, true)
    elseif frame == 82 then press_sys(0x10, false)
    end
    local r = p1:field(0x40)
    if frame >= 250 and r then r:set_value(1) end

    if frame >= 400 and frame % 5 == 0 and logf then
        logf:write(string.format(
            "f%d px=%s ax_sx=%s c07e=%02x c07f=%02x\n",
            frame, tostring(px()), tostring(axe_sprite()),
            mem:read_u8(0xc07e), mem:read_u8(0xc07f)
        ))
        logf:flush()
    end
    if frame >= 2000 then
        if logf then logf:close() end
        manager.machine:exit()
    end
end)
