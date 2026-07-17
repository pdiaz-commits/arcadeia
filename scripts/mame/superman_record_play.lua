-- Graba partida humana Superman (Taito) → logs/demos/*.jsonl
--
-- EXPERIMENTAL: igual que superman_ai.lua, este script no ha podido
-- probarse contra el juego real porque el dump de ROM disponible sigue
-- incompleto: aún falta cchip_upd78c11.bin (la ROM del C-Chip; ver
-- comentario en superman_ai.lua) y MAME aborta el arranque. Los nombres de
-- campo se resuelven de forma defensiva.

local ROOT = "/Users/pablo/Documents/arcade-ai"
local LOG_DIR = ROOT .. "/logs/demos"
local SESSION = os.date("session_%Y%m%d_%H%M%S")
local LOG_PATH = LOG_DIR .. "/" .. SESSION .. ".jsonl"
local FRAME_FILE = LOG_DIR .. "/current_frame.txt"
local SESSION_FILE = LOG_DIR .. "/current_session.txt"
local GAME_FILE = LOG_DIR .. "/current_game.txt"

local in0 = manager.machine.ioport.ports[":IN0"]

local function safe_field(port, name)
    if not port then return nil end
    local ok, f = pcall(function() return port.fields[name] end)
    if ok then return f end
    return nil
end

local fld_right = safe_field(in0, "P1 Right")
local fld_left = safe_field(in0, "P1 Left")
local fld_up = safe_field(in0, "P1 Up")
local fld_down = safe_field(in0, "P1 Down")
local fld_b1 = safe_field(in0, "P1 Button 1")
local fld_b2 = safe_field(in0, "P1 Button 2")

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
    if gf then gf:write("superman\n"); gf:close() end
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
            '{"frame":%d,"game":"superman","input":{"right":%d,"left":%d,"up":%d,"down":%d,"b1":%d,"b2":%d}}\n',
            frame, btn(fld_right), btn(fld_left), btn(fld_up), btn(fld_down), btn(fld_b1), btn(fld_b2)
        ))
        if frame % 60 == 0 then log:flush() end
    end

    local ff = io.open(FRAME_FILE, "w")
    if ff then ff:write(tostring(frame)); ff:close() end
end)

local function draw_overlay()
    local screen = manager.machine.screens[":screen"]
    if not screen then return end
    local tag = log and "REC+TEACH SUPERMAN (EXPERIMENTAL)" or "REC ERROR"
    screen:draw_text(4, 4, string.format("%s  f%d", tag, frame), 0xffffffff, 0xff000000)
end

emu.register_frame_done(draw_overlay)
