-- Escanea RAM buscando flag de hacha y prueba disparo puro (solo set_value)
local ROOT = "/Users/pablo/Documents/arcade-ai"
local LOG = ROOT .. "/logs/wboy_weapon_ram.log"
local sys = manager.machine.ioport.ports[":SYSTEM"]
local p1 = manager.machine.ioport.ports[":P1"]
local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]
local SPRITE_BASE = 0xd000
local frame = 0
local phase = "boot"
local snap_no = {}
local snap_yes = {}

local function press_sys(m, on)
    local f = sys:field(m)
    if f then f:set_value(on and 1 or 0) end
end

local function axe(on)
    local f = p1:field(0x04)
    if f then f:set_value(on and 1 or 0) end
end

local function right(on)
    local f = p1:field(0x40)
    if f then f:set_value(on and 1 or 0) end
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

    if frame >= 250 then right(true) end

    if frame == 800 and phase == "boot" then
        phase = "scan1"
        for a = 0xc000, 0xc7ff do snap_no[a] = mem:read_u8(a) end
        if logf then logf:write(string.format("f800 scan1 proj=%d\n", count_proj())); logf:flush() end
    elseif frame >= 820 and frame <= 900 and phase == "scan1" then
        axe(true)
    elseif frame == 920 and phase == "scan1" then
        phase = "scan2"
        for a = 0xc000, 0xc7ff do
            local v = mem:read_u8(a)
            if snap_no[a] ~= v then
                if logf then logf:write(string.format("ram 0x%04x: %02x -> %02x\n", a, snap_no[a], v)) end
            end
        end
        if logf then logf:write(string.format("f920 proj=%d axe_live=%s\n",
            count_proj(), tostring(p1:field(0x04) and p1:field(0x04).live and p1:field(0x04).live.value))); logf:flush() end
        if logf then logf:close() end
        manager.machine:exit()
    end
end)
