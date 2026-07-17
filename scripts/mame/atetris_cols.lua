-- Ver qué columnas cambian tras start (pieza cayendo)
local LOG = "/tmp/atetris_cols.log"
local in0 = manager.machine.ioport.ports[":IN0"]
local in1 = manager.machine.ioport.ports[":IN1"]
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local frame = 0

local function tile(r, c)
    local a = 0x1000 + (r * 64 + c) * 2
    return mem:read_u8(a) | ((mem:read_u8(a + 1) & 7) << 8)
end

local function hash_cols(c0, c1)
    local h, nz = 0, 0
    for row = 2, 25 do
        for col = c0, c1 do
            local t = tile(row, col)
            h = (h * 31 + t) % 2147483647
            if t ~= 0 then nz = nz + 1 end
        end
    end
    return nz, h
end

io.open(LOG, "w"):write("cols\n"):close()

emu.register_frame_done(function()
    frame = frame + 1
    if frame == 60 then in0:field(0x2):set_value(1)
    elseif frame == 75 then in0:field(0x2):set_value(0)
    elseif frame >= 120 and frame <= 200 then in1:field(0x1):set_value(1)
    elseif frame == 210 then in1:field(0x1):set_value(0)
    elseif frame > 210 then
        -- soft drop to accelerate
        in1:field(0x2):set_value(1)
    end

    if frame % 30 == 0 then
        local f = io.open(LOG, "a")
        local a = string.format("A(2-11) nz=%d h=%d", hash_cols(2, 11))
        local b = string.format("B(14-27) nz=%d h=%d", hash_cols(14, 27))
        local c = string.format("C(28-37) nz=%d h=%d", hash_cols(28, 37))
        f:write(string.format("f%d %s | %s | %s IN1=%02x\n", frame, a, b, c, in1:read() % 256))
        f:close()
    end
    if frame > 900 then manager.machine:exit() end
end)
