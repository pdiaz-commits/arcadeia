-- Test: mantener todos los botones P1 y loguear si el hacha llega al juego
local ROOT = "/Users/pablo/Documents/arcade-ai"
local LOG = ROOT .. "/logs/wboy_axe_test.log"

local sys = manager.machine.ioport.ports[":SYSTEM"]
local p1 = manager.machine.ioport.ports[":P1"]
local input = manager.machine.input

local MASK_RIGHT = 0x40
local MASK_LEFT  = 0x80
local MASK_JUMP  = 0x02
local MASK_AXE   = 0x04
local SYS_COIN   = 0x01
local SYS_START  = 0x10

local frame = 0

local function press_key(seq, on)
    if not input or not input.seq_set_value or not seq then return end
    pcall(function() input:seq_set_value(seq, on and 1 or 0) end)
end

local function press_field(field, on, fallback)
    if field then field:set_value(on and 1 or 0) end
    if field then
        local ok, seq = pcall(function() return field:input_seq("standard") end)
        if ok and seq then press_key(seq, on) else press_key(fallback, on) end
    else
        press_key(fallback, on)
    end
end

local function live(mask)
    local f = p1:field(mask)
    if f and f.live then return tonumber(f.live.value) or 0 end
    return -1
end

os.execute("mkdir -p " .. ROOT .. "/logs")
local logf = io.open(LOG, "w")
if logf then
    logf:write("P1 fields:\n")
    if p1 and p1.fields then
        for name, field in pairs(p1.fields) do
            local seq = ""
            local ok, s = pcall(function() return field:input_seq("standard") end)
            if ok and s and input and input.seq_name then
                local ok2, n = pcall(function() return input:seq_name(s) end)
                if ok2 and n then seq = tostring(n) end
            end
            logf:write(string.format("  %s mask=0x%x seq=%s\n", tostring(name), field.mask or 0, seq))
        end
    end
    logf:write("\n")
end

emu.register_frame_done(function()
    frame = frame + 1
    if frame == 30 then
        local f = sys:field(SYS_COIN); if f then f:set_value(1) end
        press_key("KEYCODE_5", true)
    elseif frame == 38 then
        local f = sys:field(SYS_COIN); if f then f:set_value(0) end
        press_key("KEYCODE_5", false)
    elseif frame == 70 then
        local f = sys:field(SYS_START); if f then f:set_value(1) end
        press_key("KEYCODE_1", true)
    elseif frame == 82 then
        local f = sys:field(SYS_START); if f then f:set_value(0) end
        press_key("KEYCODE_1", false)
    end

    if frame >= 200 then
        press_field(p1:field(MASK_RIGHT), true, "KEYCODE_RIGHT")
        press_field(p1:field(MASK_AXE), true, "KEYCODE_LALT")
        press_field(p1:field(MASK_JUMP), false, "KEYCODE_LCONTROL")
    end

    if frame % 60 == 0 and logf then
        logf:write(string.format(
            "f%d R=%d A=%d J=%d\n", frame,
            live(MASK_RIGHT), live(MASK_AXE), live(MASK_JUMP)
        ))
        logf:flush()
    end

    if frame >= 3600 then
        if logf then logf:close() end
        manager.machine:exit()
    end
end)
