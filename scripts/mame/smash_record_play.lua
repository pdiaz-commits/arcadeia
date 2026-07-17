-- Graba partida humana Smash TV → logs/demos/*.jsonl

local ROOT = "/Users/pablo/Documents/arcade-ai"
local LOG_DIR = ROOT .. "/logs/demos"
local SESSION = os.date("session_%Y%m%d_%H%M%S")
local LOG_PATH = LOG_DIR .. "/" .. SESSION .. ".jsonl"
local FRAME_FILE = LOG_DIR .. "/current_frame.txt"
local SESSION_FILE = LOG_DIR .. "/current_session.txt"
local GAME_FILE = LOG_DIR .. "/current_game.txt"

local function field(port, mask)
    if not port then return nil end
    local ok, f = pcall(function() return port:field(mask) end)
    if ok then return f end
    return nil
end

local ports = manager.machine.ioport.ports
local in1 = ports[":IN1"]
local in2 = ports[":IN2"]

-- Joystick 1 (movimiento)
local fld_mv_up   = field(in1, 0x01)
local fld_mv_down = field(in1, 0x02)
local fld_mv_left = field(in1, 0x04)
local fld_mv_right= field(in1, 0x08)

-- Joystick 2 (dirección de disparo)
local fld_fire_up   = field(in2, 0x01)
local fld_fire_down = field(in2, 0x02)
local fld_fire_left = field(in2, 0x04)
local fld_fire_right= field(in2, 0x08)

local fld_bomb = field(in1, 0x10)

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
    if gf then gf:write("smash\n"); gf:close() end
    return true
end

local function btn(field)
    if field and field.live and field.live.value then
        return tonumber(field.live.value) ~= 0 and 1 or 0
    end
    return 0
end

emu.register_frame_done(function()
    frame = frame + 1
    if not open_log() then return end
    if frame % 2 == 0 then
        log:write(string.format(
            '{"frame":%d,"game":"smash","input":{"mv_up":%d,"mv_down":%d,"mv_left":%d,"mv_right":%d,"fire_up":%d,"fire_down":%d,"fire_left":%d,"fire_right":%d,"bomb":%d}}\n',
            frame,
            btn(fld_mv_up), btn(fld_mv_down), btn(fld_mv_left), btn(fld_mv_right),
            btn(fld_fire_up), btn(fld_fire_down), btn(fld_fire_left), btn(fld_fire_right),
            btn(fld_bomb)
        ))
        if frame % 60 == 0 then log:flush() end
    end
    local ff = io.open(FRAME_FILE, "w")
    if ff then ff:write(tostring(frame)); ff:close() end
end)

local function draw_overlay()
    local screen = manager.machine.screens[":screen"]
    if not screen then return end
    local tag = log and "REC+TEACH SMASH TV" or "REC ERROR"
    screen:draw_text(4, 4, string.format("%s  f%d", tag, frame), 0xffffffff, 0xff000000)
end

emu.register_frame_done(draw_overlay)
