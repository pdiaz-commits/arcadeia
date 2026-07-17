-- Dump sprites en varios frames del atract mode (debug detección balón)
local ROOT = "/Users/pablo/Documents/arcade-ai"
local OUT = ROOT .. "/logs/demos/attract_multi_dump.txt"
local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]
local SPRITE_BASE = 0xe800
local frame = 0
local prev = {}
local targets = { [800]=true, [1200]=true, [1600]=true, [2000]=true, [2400]=true }

local function motion(offs, sx, sy)
    local p = prev[offs]
    if not p then return 0 end
    return math.abs(sx - p.sx) + math.abs(sy - p.sy)
end

emu.register_frame_done(function()
    frame = frame + 1
    for offs = 0, 0x3fc, 4 do
        local b = SPRITE_BASE + offs
        local code = mem:read_u8(b)
        if code ~= 0 then
            local attr = mem:read_u8(b + 1)
            local sx = mem:read_u8(b + 2) + ((attr & 0x20) * 8) - 128
            local sy = mem:read_u8(b + 3)
            prev[offs] = { sx = sx, sy = sy }
        end
    end
    if not targets[frame] then return end
    local f = io.open(OUT, "a")
    if not f then return end
    f:write(string.format("\n=== frame %d ===\n", frame))
    for offs = 0, 0x3fc, 4 do
        local b = SPRITE_BASE + offs
        local code = mem:read_u8(b)
        if code ~= 0 then
            local attr = mem:read_u8(b + 1)
            local sx = mem:read_u8(b + 2) + ((attr & 0x20) * 8) - 128
            local sy = mem:read_u8(b + 3)
            local m = motion(offs, sx, sy)
            if code <= 0x1f or (code >= 0x84 and code <= 0x8f) or m > 0 then
                f:write(string.format("offs=%03x code=%02x sx=%4d sy=%3d mot=%d\n", offs, code, sx, sy, m))
            end
        end
    end
    f:close()
    if frame == 2400 then manager.machine:exit() end
end)
