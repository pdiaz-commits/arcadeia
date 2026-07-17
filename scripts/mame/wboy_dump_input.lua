-- Dump secuencias reales de P1 Button 1/2 y probar tokens
local ROOT = "/Users/pablo/Documents/arcade-ai"
local LOG = ROOT .. "/logs/wboy_input_cfg.log"
local p1 = manager.machine.ioport.ports[":P1"]
local input = manager.machine.input
local frame = 0

os.execute("mkdir -p " .. ROOT .. "/logs")
local f = io.open(LOG, "w")

local function w(s)
    if f then f:write(s .. "\n") end
end

for _, name in ipairs({"P1 Button 1", "P1 Button 2", "P1 Right", "P1 Left"}) do
    local field = p1.fields and p1.fields[name]
    if field then
        local ok, seq = pcall(function() return field:input_seq("standard") end)
        local nm = "?"
        if ok and seq and input.seq_name then
            local ok2, n = pcall(function() return input:seq_name(seq) end)
            if ok2 and n then nm = n end
        end
        w(string.format("%s mask=0x%x seq=%s", name, field.mask or 0, nm))
    end
end

w("\nTokens:")
for _, t in ipairs({
    "KEYCODE_LALT", "KEYCODE_RALT", "KEYCODE_LCONTROL", "KEYCODE_RCONTROL",
    "KEYCODE_LWIN", "KEYCODE_LCOMMAND", "KEYCODE_LOPTION", "KEYCODE_OPTION",
    "KEYCODE_LMETA", "KEYCODE_Z", "KEYCODE_X", "KEYCODE_SPACE",
}) do
    local ok, seq = pcall(function() return input:seq_from_tokens(t) end)
    w(string.format("  %s -> %s", t, ok and "OK" or "FAIL"))
end

emu.register_frame_done(function()
    frame = frame + 1
    if frame == 5 then
        if f then f:close() end
        manager.machine:exit()
    end
end)
