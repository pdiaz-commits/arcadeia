-- Graba partida humana Ghosts'n Goblins → logs/demos/*.jsonl

local ROOT = "/Users/pablo/Documents/arcade-ai"
local LOG_DIR = ROOT .. "/logs/demos"
local SESSION = os.date("session_%Y%m%d_%H%M%S")
local LOG_PATH = LOG_DIR .. "/" .. SESSION .. ".jsonl"
local FRAME_FILE = LOG_DIR .. "/current_frame.txt"
local SESSION_FILE = LOG_DIR .. "/current_session.txt"
local GAME_FILE = LOG_DIR .. "/current_game.txt"

local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]
local p1 = manager.machine.ioport.ports[":P1"]

-- Igual que en gngb_ai.lua: spriteram 0x1e00-0x1fff, 4 bytes/sprite.
local SPRITE_BASE = 0x1e00
local SPRITE_LAST_OFFS = 0x1fc

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
    if gf then gf:write("ghosts_n_goblins\n"); gf:close() end
    return true
end

local function btn(mask)
    local f = p1:field(mask)
    if f and f.live and f.live.value then return tonumber(f.live.value) ~= 0 and 1 or 0 end
    return 0
end

-- Busca el actor de 32px (dos sprites apilados) más plausible como Arthur:
-- banda de altura de suelo habitual, con preferencia por el banco de color 0.
local function find_player()
    local best_x, best_y, best_score = -1, -1, -9999
    for offs = 0, SPRITE_LAST_OFFS, 4 do
        local base = SPRITE_BASE + offs
        local code = mem:read_u8(base)
        if code ~= 0x00 and code ~= 0xff and code ~= 0xf8 then
            local attr = mem:read_u8(base + 1)
            local sy = mem:read_u8(base + 2)
            local raw_sx = mem:read_u8(base + 3)
            local sx = raw_sx - 0x100 * (attr & 0x01)
            if sy >= 165 and sy <= 216 then
                local score = 10
                if ((attr >> 4) & 3) == 0 then score = score + 5 end
                if score > best_score then
                    best_score = score
                    best_x, best_y = sx, sy
                end
            end
        end
    end
    return best_x, best_y
end

emu.register_frame_done(function()
    frame = frame + 1
    if not open_log() then return end

    if frame % 2 == 0 then
        local px, py = find_player()
        log:write(string.format(
            '{"frame":%d,"game":"ghosts_n_goblins","player":{"x":%d,"y":%d},"input":{"right":%d,"left":%d,"jump":%d,"fire":%d}}\n',
            frame, px, py,
            btn(0x01), btn(0x02), btn(0x10), btn(0x20)
        ))
        if frame % 60 == 0 then log:flush() end
    end

    local ff = io.open(FRAME_FILE, "w")
    if ff then ff:write(tostring(frame)); ff:close() end
end)

local function draw_overlay()
    local screen = manager.machine.screens[":screen"]
    if not screen then return end
    local tag = log and "REC+TEACH GNG" or "REC ERROR"
    screen:draw_text(4, 4, string.format("%s  f%d", tag, frame), 0xffffffff, 0xff000000)
end

emu.register_frame_done(draw_overlay)
