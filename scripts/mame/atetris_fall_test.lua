-- Boot con tap corto de start; luego NO input — ¿caen piezas solas?
local LOG = "/tmp/atetris_fall_test.log"
local in0 = manager.machine.ioport.ports[":IN0"]
local in1 = manager.machine.ioport.ports[":IN1"]
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local PF_BASE = 0x1000
local frame = 0

local function tile(row, col)
    local addr = PF_BASE + (row * 64 + col) * 2
    return mem:read_u8(addr) | ((mem:read_u8(addr + 1) & 7) << 8)
end

local function stats()
    local nz, h, counts = 0, 0, {}
    for row = 8, 24 do
        for col = 14, 27 do
            local t = tile(row, col)
            h = (h * 31 + t) % 2147483647
            if t ~= 0 then nz = nz + 1 end
            counts[t] = (counts[t] or 0) + 1
        end
    end
    local bg, bn = 0, -1
    for c, n in pairs(counts) do if n > bn then bn, bg = n, c end end
    return nz, bg, h
end

local function log(msg)
    local f = io.open(LOG, "a")
    if f then f:write(string.format("f%d %s\n", frame, msg)); f:close() end
end

local function clear()
    in0:field(0x2):set_value(0)
    in1:field(0x1):set_value(0)
    in1:field(0x2):set_value(0)
    in1:field(0x4):set_value(0)
    in1:field(0x8):set_value(0)
end

io.open(LOG, "w"):write("fall_test\n"):close()

emu.register_frame_done(function()
    frame = frame + 1
    clear()

    -- Variante A: coin + tap corto start
    if frame == 80 then in0:field(0x2):set_value(1); log("coin")
    elseif frame == 95 then in0:field(0x2):set_value(0)
    elseif frame >= 160 and frame <= 175 then
        in1:field(0x1):set_value(1)
        if frame == 160 then log("start tap") end
    elseif frame >= 250 and frame <= 265 then
        in1:field(0x1):set_value(1)
        if frame == 250 then log("start tap2") end
    end
    -- resto: sin inputs (clear ya hecho)

    if frame % 20 == 0 then
        local nz, bg, h = stats()
        local v0, v1 = in0:read() % 256, in1:read() % 256
        log(string.format("nz=%d bg=%d hash=%d IN0=%02x IN1=%02x", nz, bg, h, v0, v1))
    end
    if frame > 900 then manager.machine:exit() end
end)
