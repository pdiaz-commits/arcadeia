-- Test combate: escribe hacha en RAM y dispara ante caracol 0x66
local ROOT = "/Users/pablo/Documents/arcade-ai"
local LOG = ROOT .. "/logs/wboy_combat_test.log"
local sys = manager.machine.ioport.ports[":SYSTEM"]
local p1 = manager.machine.ioport.ports[":P1"]
local input = manager.machine.input
local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]
local SPRITE_BASE = 0xd000
local WEAPON_RAM = 0xc07f
local frame = 0
local phase = "boot"
local fire_on = false

local function press_sys(m, on)
    local f = sys:field(m)
    if f then f:set_value(on and 1 or 0) end
end

local function fire(on)
    local fa = p1:field(0x04)
    if fa then
        if on then fa:set_value(1) else fa:clear_value() end
        local ok, seq = pcall(function() return fa:input_seq("standard") end)
        if ok and seq and input and input.seq_set_value then
            pcall(function() input:seq_set_value(seq, on and 1 or 0) end)
        end
    end
end

local function right(on)
    local f = p1:field(0x40)
    if f then f:set_value(on and 1 or 0) end
end

local function px()
    for offs = 0, 0x7f8, 8 do
        local c = mem:read_u8(SPRITE_BASE + offs)
        if c == 0x83 or c == 0x82 then
            return mem:read_u8(SPRITE_BASE + offs + 2) - 128
        end
    end
    return nil
end

local function find_snail()
    local pxv = px()
    if not pxv then return nil, nil end
    for offs = 0, 0x7f8, 8 do
        local c = mem:read_u8(SPRITE_BASE + offs)
        if c >= 0x40 and c <= 0x6f then
            local sx = mem:read_u8(SPRITE_BASE + offs + 2) - 128
            local dx = sx - pxv
            if dx > 0 and dx < 100 then return c, dx end
        end
    end
    return nil, nil
end

local function count_proj()
    local n = 0
    for offs = 0, 0x7f8, 8 do
        local c = mem:read_u8(SPRITE_BASE + offs)
        if c >= 0x70 and c <= 0x7e then n = n + 1 end
    end
    return n
end

os.execute("mkdir -p " .. ROOT .. "/logs")
local logf = io.open(LOG, "w")

emu.register_frame_done(function()
    frame = frame + 1
    if frame == 30 then press_sys(0x01, true)
    elseif frame == 38 then press_sys(0x01, false)
    elseif frame == 70 then press_sys(0x10, true)
    elseif frame == 82 then press_sys(0x10, false)
    end

    if frame >= 280 then right(true) end

    if frame == 900 then
        mem:write_u8(WEAPON_RAM, 1)
        phase = "armed"
        if logf then logf:write(string.format("f900 armed ram=%02x\n", mem:read_u8(WEAPON_RAM))); logf:flush() end
    end

    if phase == "armed" then
        local code, dx = find_snail()
        fire_on = (frame % 9) < 3
        fire(fire_on)
        if frame % 30 == 0 and logf then
            logf:write(string.format(
                "f%d px=%s snail=0x%s dx=%s ram=%02x proj=%d fire=%d\n",
                frame, tostring(px()), code and string.format("%02x", code) or "-",
                tostring(dx), mem:read_u8(WEAPON_RAM), count_proj(), fire_on and 1 or 0
            ))
            logf:flush()
        end
    end

    if frame >= 2400 then
        if logf then logf:close() end
        manager.machine:exit()
    end
end)
