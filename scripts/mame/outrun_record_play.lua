-- Graba partida humana Out Run → logs/demos/*.jsonl

local ROOT = "/Users/pablo/Documents/arcade-ai"
local LOG_DIR = ROOT .. "/logs/demos"
local SESSION = os.date("session_%Y%m%d_%H%M%S")
local LOG_PATH = LOG_DIR .. "/" .. SESSION .. ".jsonl"
local FRAME_FILE = LOG_DIR .. "/current_frame.txt"
local SESSION_FILE = LOG_DIR .. "/current_session.txt"
local GAME_FILE = LOG_DIR .. "/current_game.txt"

local io_ports = manager.machine.ioport
local adc0 = io_ports.ports[":ADC.0"]
local adc1 = io_ports.ports[":ADC.1"]
local adc2 = io_ports.ports[":ADC.2"]
local fld_wheel = adc0.fields["Paddle"]
local fld_accel = adc1.fields["P1 Pedal 1"]
local fld_brake = adc2.fields["P1 Pedal 2"]

local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]
local SPRITE_BASE = 0x100000

local frame = 0
local log = nil

local function open_log()
    if log then return true end
    os.execute("mkdir -p " .. LOG_DIR)
    log = io.open(LOG_PATH, "w")
    if not log then return false end
    local idx = io.open(SESSION_FILE, "w")
    if idx then idx:write(LOG_PATH .. "\n"); idx:close() end
    local gf = io.open(GAME_FILE, "w")
    if gf then gf:write("outrun\n"); gf:close() end
    return true
end

local function live_val(field)
    if field and field.live and field.live.value then
        return tonumber(field.live.value) or 0
    end
    return 0
end

-- Misma heurística que outrun_ai.lua para identificar el propio coche
local function find_own_car()
    local best, best_size = nil, -1
    for offs = 0, 0xff0, 16 do
        local w0 = mem:read_u16(SPRITE_BASE + offs)
        if (w0 & 0x8000) ~= 0 then break end
        local hidden = (w0 & 0x5000) ~= 0
        if not hidden then
            local top = (w0 & 0x1ff) - 0x100
            if top > 90 then
                local w4 = mem:read_u16(SPRITE_BASE + offs + 4)
                local xpos = w4 & 0x1ff
                local w6 = mem:read_u16(SPRITE_BASE + offs + 6)
                local vzoom = w6 & 0x7ff
                local w8 = mem:read_u16(SPRITE_BASE + offs + 8)
                local hzoom = w8 & 0x7ff
                local size = vzoom + hzoom
                if size > best_size then
                    best_size = size
                    best = { xpos = xpos, top = top }
                end
            end
        end
    end
    return best
end

emu.register_frame_done(function()
    frame = frame + 1
    if not open_log() then return end

    if frame % 2 == 0 then
        local car = find_own_car()
        log:write(string.format(
            '{"frame":%d,"game":"outrun","car":{"x":%d,"y":%d},"input":{"wheel":%d,"accel":%d,"brake":%d}}\n',
            frame,
            car and car.xpos or -1, car and car.top or -1,
            live_val(fld_wheel), live_val(fld_accel), live_val(fld_brake)
        ))
        if frame % 60 == 0 then log:flush() end
    end

    local ff = io.open(FRAME_FILE, "w")
    if ff then ff:write(tostring(frame)); ff:close() end
end)

local function draw_overlay()
    local screen = manager.machine.screens[":screen"]
    if not screen then return end
    local tag = log and "REC+TEACH OUTRUN" or "REC ERROR"
    screen:draw_text(4, 4, string.format("%s  f%d", tag, frame), 0xffffffff, 0xff000000)
end

emu.register_frame_done(draw_overlay)
