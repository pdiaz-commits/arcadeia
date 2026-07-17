-- Out Run — agente de conducción heurístico (v1)
-- Sin mapa de curvatura de carretera (CPU de carretera separada, no accesible
-- de forma sencilla desde la CPU principal): el heurístico usa control en
-- bucle cerrado sobre la posición en pantalla del propio sprite del coche
-- (si el coche se desvía del centro, es porque la carretera ha curvado y no
-- hemos corregido) más detección de coches rivales cercanos vía sprite RAM.
-- Estrategia: acelerar siempre a fondo, mantener el coche centrado en
-- pantalla corrigiendo el volante en bucle cerrado, y esquivar + frenar
-- brevemente si algo grande aparece justo delante.

local ROOT = "/Users/pablo/Documents/arcade-ai"
local AGENT = "heuristic"

local io_ports = manager.machine.ioport
local svc = io_ports.ports[":SERVICE"]
local fld_start = svc:field(0x08)
local fld_coin = svc:field(0x40)

local adc0 = io_ports.ports[":ADC.0"] -- Paddle (volante)
local adc1 = io_ports.ports[":ADC.1"] -- Pedal 1 (acelerador)
local adc2 = io_ports.ports[":ADC.2"] -- Pedal 2 (freno)
local fld_wheel = adc0.fields["Paddle"]
local fld_accel = adc1.fields["P1 Pedal 1"]
local fld_brake = adc2.fields["P1 Pedal 2"]

local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]
local SPRITE_BASE = 0x100000
local SPRITE_END = 0x100ff0

-- Rango real del volante (paddle): min=32 max=224 (ver -listxml control paddle)
local WHEEL_MIN, WHEEL_MAX = 32, 224
local WHEEL_CENTER = 128
local ACCEL_MAX = 255
local BRAKE_MAX = 255

local frame = 0
local boot_done = false
local center_x = nil          -- xpos "recto" calibrado tras el arranque
local calib_samples = {}
local steer = WHEEL_CENTER
local brake_timer = 0

local function press(field, on)
    if field then field:set_value(on and 1 or 0) end
end

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- Lee la tabla de sprites (formato Sega Out Run: 8 words / 16 bytes cada uno)
-- +0 bit15 fin de lista; bits 14/12 oculto; bits 11-9 banco; bits 8-0 top-256
-- +4 bits 8-0 posición X en pantalla
-- +6 bits 10-0 zoom vertical (más alto = sprite más grande/cercano)
-- +8 bits 10-0 zoom horizontal
local function read_sprites()
    local sprites = {}
    for offs = 0, SPRITE_END - SPRITE_BASE, 16 do
        local w0 = mem:read_u16(SPRITE_BASE + offs)
        if (w0 & 0x8000) ~= 0 then break end
        local hidden = (w0 & 0x5000) ~= 0
        if not hidden then
            local top = (w0 & 0x1ff) - 0x100
            local w4 = mem:read_u16(SPRITE_BASE + offs + 4)
            local xpos = w4 & 0x1ff
            local w6 = mem:read_u16(SPRITE_BASE + offs + 6)
            local vzoom = w6 & 0x7ff
            local w8 = mem:read_u16(SPRITE_BASE + offs + 8)
            local hzoom = w8 & 0x7ff
            sprites[#sprites + 1] = { top = top, xpos = xpos, vzoom = vzoom, hzoom = hzoom, offs = offs }
        end
    end
    return sprites
end

-- El propio coche del jugador suele ser, con diferencia, el sprite más
-- grande (zoom horizontal+vertical) y aparece en la mitad inferior de la
-- pantalla en (casi) todos los frames.
local function find_own_car(sprites)
    local best, best_size = nil, -1
    for _, s in ipairs(sprites) do
        if s.top > 90 then
            local size = s.vzoom + s.hzoom
            if size > best_size then
                best_size = size
                best = s
            end
        end
    end
    return best
end

-- Coches/obstáculos rivales: sprites grandes y cercanos (zoom alto) que NO
-- son nuestro propio coche, en la mitad inferior/central de la pantalla.
local function find_obstacle_ahead(sprites, own)
    if not own then return nil end
    local best, best_size = nil, -1
    for _, s in ipairs(sprites) do
        if s.offs ~= own.offs and s.top > 60 and s.top <= own.top + 20 then
            local size = s.vzoom + s.hzoom
            -- Solo objetos ya grandes (cerca) y razonablemente centrados respecto a nosotros
            if size > 0x900 and math.abs(s.xpos - own.xpos) < 60 then
                if size > best_size then
                    best_size = size
                    best = s
                end
            end
        end
    end
    return best
end

local function boot_sequence()
    if frame == 60 then press(fld_coin, true)
    elseif frame == 70 then press(fld_coin, false)
    elseif frame == 120 then press(fld_start, true)
    elseif frame == 130 then press(fld_start, false)
    elseif frame == 200 then boot_done = true
    end
end

local function act_random()
    local r = frame % 53
    if fld_wheel then fld_wheel:set_value(clamp(WHEEL_CENTER + ((r * 5) % 61) - 30, WHEEL_MIN, WHEEL_MAX)) end
    if fld_accel then fld_accel:set_value(ACCEL_MAX) end
    if fld_brake then fld_brake:set_value(0) end
end

local function act_heuristic()
    local sprites = read_sprites()
    local own = find_own_car(sprites)

    -- Calibrar el "centro recto" con las primeras lecturas estables tras el arranque
    if own and #calib_samples < 30 then
        calib_samples[#calib_samples + 1] = own.xpos
        if #calib_samples == 30 then
            local sum = 0
            for _, v in ipairs(calib_samples) do sum = sum + v end
            center_x = sum / #calib_samples
        end
    end

    local target_wheel = WHEEL_CENTER
    local brake = false

    if own and center_x then
        -- Control proporcional: si el coche se ha desviado del centro
        -- (p.ej. por una curva no compensada), corregimos el volante para
        -- devolverlo al centro. Esto funciona sin necesitar la curvatura
        -- real de la carretera (que vive en la CPU de carretera/sub-CPU).
        local error = own.xpos - center_x
        local correction = clamp(error * 1.6, -70, 70)
        target_wheel = WHEEL_CENTER - correction

        local obstacle = find_obstacle_ahead(sprites, own)
        if obstacle then
            -- Esquivar: virar hacia el lado contrario del obstáculo y frenar
            -- un instante si está muy cerca (zoom muy alto).
            local away = (own.xpos <= obstacle.xpos) and -1 or 1
            target_wheel = WHEEL_CENTER + away * 55
            if obstacle.vzoom + obstacle.hzoom > 0xb00 then
                brake_timer = 10
            end
        end
    end

    if brake_timer > 0 then
        brake = true
        brake_timer = brake_timer - 1
    end

    -- Suavizado del volante (evita saltos bruscos frame a frame)
    steer = steer + clamp(target_wheel - steer, -14, 14)
    steer = clamp(steer, WHEEL_MIN, WHEEL_MAX)

    if fld_wheel then fld_wheel:set_value(math.floor(steer)) end
    if fld_accel then fld_accel:set_value(brake and 40 or ACCEL_MAX) end
    if fld_brake then fld_brake:set_value(brake and BRAKE_MAX or 0) end
end

local function draw_overlay()
    local screen = manager.machine.screens[":screen"]
    if not screen then return end
    local mode = boot_done and ("AI " .. AGENT) or "AI boot..."
    screen:draw_text(4, 4, string.format("%s  f%d", mode, frame), 0xffffffff, 0xff000000)
end

emu.register_frame_done(function()
    frame = frame + 1
    if not boot_done then
        boot_sequence()
        draw_overlay()
        return
    end

    if AGENT == "random" then act_random() else act_heuristic() end
    draw_overlay()
end)
