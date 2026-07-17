-- Secuencia: coin → start largo → release → start corto → idle (¿caen piezas?)
local LOG = "/tmp/atetris_seq_test.log"
local in0 = manager.machine.ioport.ports[":IN0"]
local in1 = manager.machine.ioport.ports[":IN1"]
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local PF_BASE = 0x1000
local frame = 0
local phase = "boot"

local function tile(row, col)
    local addr = PF_BASE + (row * 64 + col) * 2
    return mem:read_u8(addr) | ((mem:read_u8(addr + 1) & 7) << 8)
end

local function stats()
    local nz, h = 0, 0
    for row = 8, 24 do
        for col = 14, 27 do
            local t = tile(row, col)
            h = (h * 31 + t) % 2147483647
            if t ~= 0 then nz = nz + 1 end
        end
    end
    return nz, h
end

local function log(msg)
    local f = io.open(LOG, "a")
    if f then f:write(string.format("f%d %s\n", frame, msg)); f:close() end
end

io.open(LOG, "w"):write("seq_test\n"):close()

emu.register_frame_done(function()
    frame = frame + 1
    -- No clear global: solo setear lo que hace falta; soltar explícitamente.
    if frame == 60 then
        in0:field(0x2):set_value(1); log("coin down"); phase = "coin"
    elseif frame == 75 then
        in0:field(0x2):set_value(0); log("coin up")
    elseif frame == 120 then
        in1:field(0x1):set_value(1); log("start1 hold begin"); phase = "start1"
    elseif frame == 280 then
        in1:field(0x1):set_value(0); log("start1 release")
    elseif frame == 350 then
        in1:field(0x1):set_value(1); log("start2 tap"); phase = "start2"
    elseif frame == 365 then
        in1:field(0x1):set_value(0); log("start2 release"); phase = "idle"
    elseif frame == 500 then
        -- Intentar jugar: right+down con set_value
        phase = "play"
        log("play right+down begin")
    end

    if phase == "play" then
        in1:field(0x4):set_value(1)
        in1:field(0x2):set_value(1)
        in1:field(0x8):set_value(0)
        in1:field(0x1):set_value(0)
    end

    if frame % 20 == 0 then
        local nz, h = stats()
        log(string.format("phase=%s nz=%d hash=%d IN1=%02x", phase, nz, h, in1:read() % 256))
    end
    if frame > 900 then manager.machine:exit() end
end)
