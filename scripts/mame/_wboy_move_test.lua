-- Test: ¿mueve el personaje con máscara 0x40?
local LOG = "/Users/pablo/Documents/arcade-ai/logs/wboy_move_test.log"
local p1 = manager.machine.ioport.ports[":P1"]
local sys = manager.machine.ioport.ports[":SYSTEM"]
local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]
local SPRITE_BASE = 0xd000
local frame = 0
local boot_done = false
local logf = io.open(LOG, "w")

local function player_x()
    for offs = 0, 0x7f8, 8 do
        local code = mem:read_u8(SPRITE_BASE + offs)
        if code == 0x83 or code == 0x82 or code == 0x84 then
            return mem:read_u8(SPRITE_BASE + offs + 2) - 128
        end
    end
    return nil
end

local function press_sys(mask, on)
    local f = sys:field(mask)
    if f then f:set_value(on and 1 or 0) end
end

emu.register_frame_done(function()
    frame = frame + 1
    if frame == 40 then press_sys(0x01, true)
    elseif frame == 50 then press_sys(0x01, false)
    elseif frame == 90 then press_sys(0x10, true)
    elseif frame == 105 then press_sys(0x10, false)
    elseif frame == 180 then press_sys(0x10, true)
    elseif frame == 195 then press_sys(0x10, false)
    elseif frame >= 260 then boot_done = true end

    if boot_done then
        local r = p1:field(0x40)
        if r then r:set_value(1) end
    end

    if frame % 30 == 0 and logf then
        local x = player_x()
        local r = p1:field(0x40)
        logf:write(string.format(
            "f=%d boot=%s x=%s field=%s\n",
            frame, tostring(boot_done), tostring(x), r and "ok" or "nil"
        ))
        logf:flush()
    end

    if frame >= 900 then
        if logf then logf:close() end
        manager.machine:exit()
    end
end)
