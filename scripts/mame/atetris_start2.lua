-- Tras llegar a pantalla de pozos estáticos, probar secuencias para empezar
local LOG = "/tmp/atetris_start2.log"
local in0 = manager.machine.ioport.ports[":IN0"]
local in1 = manager.machine.ioport.ports[":IN1"]
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local frame = 0

local function tile(r, c)
    local a = 0x1000 + (r * 64 + c) * 2
    return mem:read_u8(a) | ((mem:read_u8(a + 1) & 7) << 8)
end

local function well_hash()
    local h, nz = 0, 0
    for row = 4, 24 do
        for col = 2, 11 do
            local t = tile(row, col)
            h = (h * 31 + t) % 2147483647
            if t ~= 0 then nz = nz + 1 end
        end
    end
    return nz, h
end

local function clear()
    in0:field(0x2):set_value(0)
    in1:field(0x1):set_value(0)
    in1:field(0x2):set_value(0)
    in1:field(0x4):set_value(0)
    in1:field(0x8):set_value(0)
end

local function log(msg)
    local f = io.open(LOG, "a")
    if f then
        local nz, h = well_hash()
        f:write(string.format("f%d %s nz=%d hash=%d\n", frame, msg, nz, h))
        f:close()
    end
end

io.open(LOG, "w"):write("start2\n"):close()

emu.register_frame_done(function()
    frame = frame + 1
    clear()

    -- Fase 1: coin + start corto
    if frame == 60 then in0:field(0x2):set_value(1); log("coin")
    elseif frame == 75 then -- coin up via clear
    elseif frame >= 140 and frame <= 155 then
        in1:field(0x1):set_value(1)
        if frame == 140 then log("start1") end

    -- Fase 2: en pantalla pozos, mover derecha varias veces (elegir nivel?)
    elseif frame >= 200 and frame <= 230 then
        if (frame % 10) < 4 then in1:field(0x4):set_value(1) end
        if frame == 200 then log("right spam") end

    -- Fase 3: confirmar con botón
    elseif frame >= 250 and frame <= 265 then
        in1:field(0x1):set_value(1)
        if frame == 250 then log("confirm") end

    -- Fase 4: más left + confirm
    elseif frame >= 300 and frame <= 330 then
        if (frame % 10) < 4 then in1:field(0x8):set_value(1) end
        if frame == 300 then log("left spam") end
    elseif frame >= 350 and frame <= 365 then
        in1:field(0x1):set_value(1)
        if frame == 350 then log("confirm2") end

    -- Fase 5: down + button
    elseif frame >= 400 and frame <= 430 then
        in1:field(0x2):set_value(1)
        if frame == 400 then log("down hold") end
    elseif frame >= 450 and frame <= 465 then
        in1:field(0x1):set_value(1)
        if frame == 450 then log("confirm3") end

    -- Fase 6: segunda moneda + start
    elseif frame == 500 then in0:field(0x2):set_value(1); log("coin2")
    elseif frame >= 550 and frame <= 650 then
        in1:field(0x1):set_value(1)
        if frame == 550 then log("start_long") end
    elseif frame > 700 then
        in1:field(0x2):set_value(1) -- soft drop watch
        if frame == 701 then log("softdrop watch") end
    end

    if frame % 30 == 0 then log("tick") end
    if frame > 1000 then manager.machine:exit() end
end)
