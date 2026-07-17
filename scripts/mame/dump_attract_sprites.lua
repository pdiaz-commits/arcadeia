-- Dump sprites un frame durante atract mode (debug)
local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]
local SPRITE_BASE = 0xe800
local frame = 0
local dumped = false

emu.register_frame_done(function()
    frame = frame + 1
    if dumped or frame ~= 1600 then return end
    dumped = true
    local f = io.open("/Users/pablo/Documents/arcade-ai/logs/demos/attract_sprite_dump.txt", "w")
    if not f then return end
    f:write("frame " .. frame .. "\n")
    for offs = 0, 0x3fc, 4 do
        local b = SPRITE_BASE + offs
        local code = mem:read_u8(b)
        if code ~= 0 then
            local attr = mem:read_u8(b + 1)
            local sx = mem:read_u8(b + 2) + ((attr & 0x20) * 8) - 128
            local sy = mem:read_u8(b + 3)
            f:write(string.format("offs=%03x code=%02x sx=%d sy=%d\n", offs, code, sx, sy))
        end
    end
    f:close()
    manager.machine:exit()
end)
