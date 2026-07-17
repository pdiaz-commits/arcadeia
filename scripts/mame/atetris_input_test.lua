-- Prueba: ¿el juego responde a teclado seq vs set_value?
-- Fase A: solo KEYCODE via seq_from_tokens
-- Fase B: solo field:set_value
-- Log: hash + IN1 + créditos si se puede

local LOG = "/tmp/atetris_input_test.log"
local in0 = manager.machine.ioport.ports[":IN0"]
local in1 = manager.machine.ioport.ports[":IN1"]
local input = manager.machine.input
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local PF_BASE = 0x1000
local frame = 0

local function tile(row, col)
    local addr = PF_BASE + (row * 64 + col) * 2
    return mem:read_u8(addr) | ((mem:read_u8(addr + 1) & 7) << 8)
end

local function pf_hash()
    local h, nz = 0, 0
    for row = 8, 24 do
        for col = 14, 27 do
            local t = tile(row, col)
            h = (h * 31 + t) % 2147483647
            if t ~= 0 then nz = nz + 1 end
        end
    end
    return h, nz
end

local function log(msg)
    local f = io.open(LOG, "a")
    if f then f:write(string.format("f%d %s\n", frame, msg)); f:close() end
end

local function key(tok, on)
    pcall(function()
        local seq = input:seq_from_tokens(tok)
        if seq then input:seq_set_value(seq, on and 1 or 0) end
    end)
end

local function all_keys_off()
    for _, t in ipairs({"KEYCODE_5","KEYCODE_1","KEYCODE_X","KEYCODE_LEFT","KEYCODE_RIGHT","KEYCODE_DOWN","KEYCODE_UP","KEYCODE_Z","KEYCODE_SPACE"}) do
        key(t, false)
    end
end

local function fields_off()
    pcall(function()
        in0:field(0x2):set_value(0)
        in1:field(0x1):set_value(0)
        in1:field(0x2):set_value(0)
        in1:field(0x4):set_value(0)
        in1:field(0x8):set_value(0)
    end)
end

io.open(LOG, "w"):write("input_test\n"):close()

emu.register_frame_done(function()
    frame = frame + 1
    all_keys_off()
    fields_off()

    -- Boot con SOLO teclado (como humano)
    if frame == 90 then key("KEYCODE_5", true); log("KEY coin")
    elseif frame == 105 then key("KEYCODE_5", false)
    elseif frame >= 150 and frame <= 300 then
        key("KEYCODE_1", true)
        key("KEYCODE_X", true)
        if frame == 150 then log("KEY start hold") end
    elseif frame == 310 then
        key("KEYCODE_1", false); key("KEYCODE_X", false); log("KEY start release")
    elseif frame > 310 and frame < 700 then
        -- Solo teclado: RIGHT+DOWN
        key("KEYCODE_RIGHT", true)
        key("KEYCODE_DOWN", true)
        if frame == 311 then log("KEY play right+down") end
    elseif frame == 700 then
        log("switch to set_value play")
    elseif frame > 700 then
        -- Solo set_value
        in1:field(0x4):set_value(1)
        in1:field(0x2):set_value(1)
    end

    if frame % 30 == 0 then
        local h, nz = pf_hash()
        local v0, v1 = -1, -1
        pcall(function() v0 = in0:read(); v1 = in1:read() end)
        log(string.format("nz=%d hash=%d IN0=%02x IN1=%02x", nz, h, v0 % 256, v1 % 256))
    end
    if frame > 1100 then manager.machine:exit() end
end)
