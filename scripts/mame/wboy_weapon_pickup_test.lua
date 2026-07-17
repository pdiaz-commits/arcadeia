-- Detecta cuándo el juego registra hacha equipada (RAM + proj)
local ROOT = "/Users/pablo/Documents/arcade-ai"
local LOG = ROOT .. "/logs/wboy_weapon_pickup.log"
local sys = manager.machine.ioport.ports[":SYSTEM"]
local p1 = manager.machine.ioport.ports[":P1"]
local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]
local SPRITE_BASE = 0xd000
local frame = 0
local had_axe_sprite = false
local last_ram = {}

local function press_sys(m, on)
    local f = sys:field(m)
    if f then f:set_value(on and 1 or 0) end
end

local function right(on)
    local f = p1:field(0x40)
    if f then f:set_value(on and 1 or 0) end
end

local function px()
    for offs = 0, 0x7f8, 8 do
        local c = mem:read_u8(SPRITE_BASE + offs)
        if c == 0x83 or c == 0x82 or c == 0x84 then
            return mem:read_u8(SPRITE_BASE + offs + 2) - 128
        end
    end
    return nil
end

local function has_axe_sprite()
    for offs = 0, 0x7f8, 8 do
        local c = mem:read_u8(SPRITE_BASE + offs)
        if c == 0x80 or c == 0x81 then return true end
    end
    return false
end

local function count_proj()
    local n = 0
    for offs = 0, 0x7f8, 8 do
        local c = mem:read_u8(SPRITE_BASE + offs)
        if c >= 0x70 and c <= 0x7e then n = n + 1 end
    end
    return n
end

local function snap_ram()
    local t = {}
    for a = 0xc000, 0xc0ff do t[a] = mem:read_u8(a) end
    return t
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
    if frame >= 250 then right(true) end

    local axe = has_axe_sprite()
    if axe and not had_axe_sprite then
        last_ram = snap_ram()
        if logf then logf:write(string.format("f%d AXE_APPEAR x=%s\n", frame, tostring(px()))); logf:flush() end
    end
    if had_axe_sprite and not axe then
        local now = snap_ram()
        if logf then
            logf:write(string.format("f%d AXE_GONE x=%s proj=%d\n", frame, tostring(px()), count_proj()))
            for a = 0xc000, 0xc0ff do
                if last_ram[a] ~= now[a] then
                    logf:write(string.format("  ram 0x%04x: %02x -> %02x\n", a, last_ram[a], now[a]))
                end
            end
            logf:flush()
        end
    end
    had_axe_sprite = axe

    if frame >= 1400 and frame <= 1500 and frame % 10 == 0 then
        local fa = p1:field(0x04)
        if fa then fa:set_value(1) end
    elseif frame == 1510 then
        local fa = p1:field(0x04)
        if fa then fa:set_value(0) end
    end

    if frame == 1520 and logf then
        logf:write(string.format("f1520 after_fire proj=%d x=%s\n", count_proj(), tostring(px())))
        logf:close()
        manager.machine:exit()
    end
end)
