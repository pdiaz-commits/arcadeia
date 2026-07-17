-- En pantalla nz=103: probar L/R/D/rot y volcar grid de tiles
local LOG = "/tmp/atetris_menu_test.log"
local in0 = manager.machine.ioport.ports[":IN0"]
local in1 = manager.machine.ioport.ports[":IN1"]
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local PF_BASE = 0x1000
local frame = 0

local function tile(row, col)
    local addr = PF_BASE + (row * 64 + col) * 2
    return mem:read_u8(addr) | ((mem:read_u8(addr + 1) & 7) << 8)
end

local function dump_grid()
    local f = io.open(LOG, "a")
    if not f then return end
    f:write(string.format("GRID f%d\n", frame))
    for row = 8, 24 do
        local line = ""
        for col = 14, 27 do
            local t = tile(row, col)
            if t == 0 then line = line .. "."
            elseif t < 16 then line = line .. string.format("%x", t)
            else line = line .. "#"
            end
        end
        f:write(line .. "\n")
    end
    f:close()
end

local function log(msg)
    local f = io.open(LOG, "a")
    if f then f:write(string.format("f%d %s\n", frame, msg)); f:close() end
end

io.open(LOG, "w"):write("menu_test\n"):close()

emu.register_frame_done(function()
    frame = frame + 1
    in0:field(0x2):set_value(0)
    in1:field(0x1):set_value(0)
    in1:field(0x2):set_value(0)
    in1:field(0x4):set_value(0)
    in1:field(0x8):set_value(0)

    if frame == 60 then in0:field(0x2):set_value(1)
    elseif frame == 75 then in0:field(0x2):set_value(0)
    elseif frame >= 120 and frame <= 200 then
        in1:field(0x1):set_value(1) -- enter nz=103
    elseif frame == 220 then dump_grid(); log("after start, try RIGHT")
    elseif frame >= 230 and frame <= 280 then
        in1:field(0x4):set_value(1) -- right
    elseif frame == 290 then dump_grid(); log("try LEFT")
    elseif frame >= 300 and frame <= 350 then
        in1:field(0x8):set_value(1) -- left
    elseif frame == 360 then dump_grid(); log("try DOWN")
    elseif frame >= 370 and frame <= 420 then
        in1:field(0x2):set_value(1) -- down
    elseif frame == 430 then dump_grid(); log("try ROT taps")
    elseif frame >= 440 and frame <= 445 then in1:field(0x1):set_value(1)
    elseif frame >= 460 and frame <= 465 then in1:field(0x1):set_value(1)
    elseif frame == 480 then dump_grid(); log("done")
    end

    if frame % 30 == 0 and frame >= 200 then
        local nz, h = 0, 0
        for row = 8, 24 do
            for col = 14, 27 do
                local t = tile(row, col)
                h = (h * 31 + t) % 2147483647
                if t ~= 0 then nz = nz + 1 end
            end
        end
        log(string.format("nz=%d hash=%d IN1=%02x", nz, h, in1:read() % 256))
    end
    if frame > 500 then manager.machine:exit() end
end)
