-- Graba partida humana Wonder Boy → logs/demos/*.jsonl

local ROOT = "/Users/pablo/dossier/arcade-ai"
local LOG_DIR = ROOT .. "/logs/demos"
local SESSION = os.date("session_%Y%m%d_%H%M%S")
local LOG_PATH = LOG_DIR .. "/" .. SESSION .. ".jsonl"
local FRAME_FILE = LOG_DIR .. "/current_frame.txt"
local SESSION_FILE = LOG_DIR .. "/current_session.txt"
local GAME_FILE = LOG_DIR .. "/current_game.txt"

local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]
local p1 = manager.machine.ioport.ports[":P1"]
local SPRITE_BASE = 0xd000

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
    if gf then gf:write("wonder_boy\n"); gf:close() end
    return true
end

local function btn(mask)
    local f = p1:field(mask)
    if f and f.live and f.live.value then return tonumber(f.live.value) ~= 0 and 1 or 0 end
    return 0
end

local function find_player()
    for offs = 0, 0x7f8, 8 do
        local base = SPRITE_BASE + offs
        local code = mem:read_u8(base)
        if code == 0x83 or code == 0x82 then
            local raw_y = mem:read_u8(base + 1)
            local raw_x = mem:read_u8(base + 2)
            return raw_x - 128, 256 - raw_y
        end
    end
    return -1, -1
end

emu.register_frame_done(function()
    frame = frame + 1
    if not open_log() then return end

    if frame % 2 == 0 then
        local px, py = find_player()
        log:write(string.format(
            '{"frame":%d,"game":"wonder_boy","player":{"x":%d,"y":%d},"input":{"right":%d,"left":%d,"jump":%d,"axe":%d}}\n',
            frame, px, py,
            btn(0x40), btn(0x80), btn(0x02), btn(0x04)
        ))
        if frame % 60 == 0 then log:flush() end
    end

    local ff = io.open(FRAME_FILE, "w")
    if ff then ff:write(tostring(frame)); ff:close() end
end)

local function draw_overlay()
    local screen = manager.machine.screens[":screen"]
    if not screen then return end
    local tag = log and "REC+TEACH WB" or "REC ERROR"
    screen:draw_text(4, 4, string.format("%s  f%d", tag, frame), 0xffffffff, 0xff000000)
end

emu.register_frame_done(draw_overlay)
