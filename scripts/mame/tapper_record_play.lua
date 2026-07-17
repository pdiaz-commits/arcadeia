-- Graba partida humana Tapper → logs/demos/*.jsonl

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
local in0 = ports[":IN0"]

local fld_up    = field(in0, 0x01)
local fld_down  = field(in0, 0x02)
local fld_left  = field(in0, 0x04)
local fld_right = field(in0, 0x08)
local fld_btn1  = field(in0, 0x10)

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
    if gf then gf:write("tapper\n"); gf:close() end
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
            '{"frame":%d,"game":"tapper","input":{"up":%d,"down":%d,"left":%d,"right":%d,"btn1":%d}}\n',
            frame, btn(fld_up), btn(fld_down), btn(fld_left), btn(fld_right), btn(fld_btn1)
        ))
        if frame % 60 == 0 then log:flush() end
    end
    local ff = io.open(FRAME_FILE, "w")
    if ff then ff:write(tostring(frame)); ff:close() end
end)

local function draw_overlay()
    local screen = manager.machine.screens[":screen"]
    if not screen then return end
    local tag = log and "REC+TEACH TAPPER" or "REC ERROR"
    screen:draw_text(4, 4, string.format("%s  f%d", tag, frame), 0xffffffff, 0xff000000)
end

emu.register_frame_done(draw_overlay)
