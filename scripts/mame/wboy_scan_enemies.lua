-- Scan enemigos Wonder Boy (caracoles, avispas)
local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]
local SPRITE_BASE = 0xd000
local frame = 0
local seen = {}
local LOG = "/Users/pablo/Documents/arcade-ai/logs/wboy_enemy_codes.log"
local logf = nil
local sys = manager.machine.ioport.ports[":SYSTEM"]
local p1 = manager.machine.ioport.ports[":P1"]

local function log(msg)
    if not logf then
        os.execute("mkdir -p /Users/pablo/Documents/arcade-ai/logs")
        logf = io.open(LOG, "w")
    end
    if logf then logf:write(msg .. "\n"); logf:flush() end
end

local function press_sys(mask, on)
    local f = sys:field(mask)
    if f then f:set_value(on and 1 or 0) end
end

local function find_player()
    for offs = 0, 0x7f8, 8 do
        local base = SPRITE_BASE + offs
        local code = mem:read_u8(base)
        if code == 0x83 or code == 0x82 or code == 0x84 then
            local raw_y = mem:read_u8(base + 1)
            local raw_x = mem:read_u8(base + 2)
            return raw_x - 128, 256 - raw_y
        end
    end
    return nil, nil
end

emu.register_frame_done(function()
    frame = frame + 1
    if frame == 40 then press_sys(0x01, true)
    elseif frame == 50 then press_sys(0x01, false)
    elseif frame == 90 then press_sys(0x10, true)
    elseif frame == 105 then press_sys(0x10, false)
    elseif frame == 180 then press_sys(0x10, true)
    elseif frame == 195 then press_sys(0x10, false)
    elseif frame >= 220 then
        local r = p1:field(0x40); if r then r:set_value(1) end
        local a = p1:field(0x04); if a then a:set_value(1) end
    end
    if frame < 400 then return end
    if frame > 9000 then
        if logf then logf:close() end
        manager.machine:exit()
        return
    end
    if frame % 20 ~= 0 then return end
    local px, py = find_player()
    if not px then return end
    for offs = 0, 0x7f8, 8 do
        local base = SPRITE_BASE + offs
        local code = mem:read_u8(base)
        if code == 0 or code == 0x82 or code == 0x83 or code == 0x84 then goto cont end
        local raw_y = mem:read_u8(base + 1)
        local raw_x = mem:read_u8(base + 2)
        local sx = raw_x - 128
        local sy = 256 - raw_y
        local dx = sx - px
        local dy = sy - py
        if dx > -5 and dx < 130 and math.abs(dy) < 55 then
            local key = string.format("0x%02x dy%d", code, dy)
            if not seen[key] then
                seen[key] = true
                log(string.format("f%d code=0x%02x dx=%d dy=%d", frame, code, dx, dy))
            end
        end
        ::cont::
    end
end)
