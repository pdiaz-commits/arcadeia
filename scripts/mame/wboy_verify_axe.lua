-- Verifica que el botón hacha (P1 Button 2) llega al juego y lanza proyectiles
local ROOT = "/Users/pablo/Documents/arcade-ai"
local LOG = ROOT .. "/logs/wboy_verify_axe.log"

local sys = manager.machine.ioport.ports[":SYSTEM"]
local p1 = manager.machine.ioport.ports[":P1"]
local input = manager.machine.input
local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]
local SPRITE_BASE = 0xd000

local MASK_RIGHT = 0x40
local MASK_AXE   = 0x04
local SYS_COIN   = 0x01
local SYS_START  = 0x10

local frame = 0
local baseline = {}
local with_axe = {}

local function press_sys(mask, on)
    local f = sys:field(mask)
    if f then f:set_value(on and 1 or 0) end
end

local function seq_press(seq, on)
    if not input or not input.seq_set_value or not seq then return end
    pcall(function() input:seq_set_value(seq, on and 1 or 0) end)
end

local function token_press(token, on)
    if not input or not input.seq_from_tokens then return end
    local ok, seq = pcall(function() return input:seq_from_tokens(token) end)
    if ok and seq then seq_press(seq, on) end
end

local function fire_axe(on)
    local fa = p1:field(MASK_AXE)
    if not fa and p1.fields then fa = p1.fields["P1 Button 2"] end
    if fa then
        fa:set_value(on and 1 or 0)
        local ok, seq = pcall(function() return fa:input_seq("standard") end)
        if ok and seq then seq_press(seq, on) end
    end
    if on then
        token_press("KEYCODE_LALT", true)
        token_press("KEYCODE_LOPTION", true)
        token_press("KEYCODE_Z", true)
    else
        token_press("KEYCODE_LALT", false)
        token_press("KEYCODE_LOPTION", false)
        token_press("KEYCODE_Z", false)
    end
end

local function move_right(on)
    local fr = p1:field(MASK_RIGHT)
    if fr then fr:set_value(on and 1 or 0) end
    token_press("KEYCODE_RIGHT", on)
end

local function axe_live()
    local fa = p1:field(MASK_AXE)
    if fa and fa.live then return tonumber(fa.live.value) or 0 end
    return -1
end

local function snapshot_codes()
    local codes = {}
    for offs = 0, 0x7f8, 8 do
        local c = mem:read_u8(SPRITE_BASE + offs)
        if c ~= 0 then codes[string.format("0x%02x", c)] = true end
    end
    return codes
end

local function count_new(base, now)
    local n = 0
    for k in pairs(now) do
        if not base[k] then n = n + 1 end
    end
    return n
end

os.execute("mkdir -p " .. ROOT .. "/logs")
local logf = io.open(LOG, "w")

emu.register_frame_done(function()
    frame = frame + 1
    if frame == 30 then press_sys(SYS_COIN, true); token_press("KEYCODE_5", true)
    elseif frame == 38 then press_sys(SYS_COIN, false); token_press("KEYCODE_5", false)
    elseif frame == 70 then press_sys(SYS_START, true); token_press("KEYCODE_1", true)
    elseif frame == 82 then press_sys(SYS_START, false); token_press("KEYCODE_1", false)
    end

    if frame >= 300 then move_right(true) end

    if frame == 600 then
        fire_axe(false)
        baseline = snapshot_codes()
        if logf then logf:write(string.format("f600 baseline sprites axe_live=%d\n", axe_live())); logf:flush() end
    elseif frame >= 620 and frame <= 700 then
        fire_axe(true)
        if frame % 20 == 0 then
            local now = snapshot_codes()
            local newc = count_new(baseline, now)
            if logf then
                logf:write(string.format("f%d axe_live=%d new_sprites=%d\n", frame, axe_live(), newc))
                logf:flush()
            end
        end
    elseif frame == 720 then
        fire_axe(false)
        with_axe = snapshot_codes()
        if logf then
            logf:write(string.format("f720 final axe_live=%d new_total=%d\n",
                axe_live(), count_new(baseline, with_axe)))
            logf:close()
        end
        manager.machine:exit()
    end
end)
