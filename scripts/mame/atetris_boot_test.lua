-- Minimal boot test: exactamente como atetris_diag (solo set_value)
local LOG = "/tmp/atetris_boot_test.log"
local in0 = manager.machine.ioport.ports[":IN0"]
local in1 = manager.machine.ioport.ports[":IN1"]
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local PF_BASE = 0x1000
local frame, boot_done = 0, false

local function tile(row, col)
    local addr = PF_BASE + (row * 64 + col) * 2
    return mem:read_u8(addr) | ((mem:read_u8(addr + 1) & 7) << 8)
end

local function stats()
    local counts, filled, hash = {}, 0, 0
    for row = 8, 24 do
        for col = 14, 27 do
            local t = tile(row, col)
            counts[t] = (counts[t] or 0) + 1
            if t ~= 0 then filled = filled + 1 end
            hash = (hash * 31 + t) % 2147483647
        end
    end
    local bg, bn = 0, -1
    for c, n in pairs(counts) do if n > bn then bn = n; bg = c end end
    return filled, bg, hash
end

local function log(msg)
    local f = io.open(LOG, "a")
    if f then f:write(string.format("f%d %s\n", frame, msg)); f:close() end
end

io.open(LOG, "w"):write("boot_test start\n"):close()

emu.register_frame_done(function()
    frame = frame + 1
    if not boot_done then
        if frame == 60 then in0:field(0x2):set_value(1); log("coin1")
        elseif frame == 70 then in0:field(0x2):set_value(0); log("coin0")
        elseif frame >= 120 and frame <= 280 then in1:field(0x1):set_value(1)
        elseif frame == 300 then
            in1:field(0x1):set_value(0)
            boot_done = true
            log("boot_done")
        end
        if frame == 120 then log("start_hold") end
    else
        -- hold RIGHT forever after boot (proof inputs work)
        in1:field(0x4):set_value(1)
        in1:field(0x8):set_value(0)
        in1:field(0x2):set_value(1) -- down
    end
    if frame % 30 == 0 then
        local filled, bg, hash = stats()
        local liv = "?"
        pcall(function()
            liv = string.format("IN1=%02x", in1:read())
        end)
        log(string.format("fill=%d bg=%d hash=%d %s", filled, bg, hash, liv))
    end
    if frame > 1200 then
        log("exit")
        manager.machine:exit()
    end
end)
