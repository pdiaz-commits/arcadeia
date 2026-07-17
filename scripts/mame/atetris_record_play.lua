-- Graba partida humana Atari Tetris → logs/demos/*.jsonl

local ROOT = "/Users/pablo/Documents/arcade-ai"
local LOG_DIR = ROOT .. "/logs/demos"
local SESSION = os.date("session_%Y%m%d_%H%M%S")
local LOG_PATH = LOG_DIR .. "/" .. SESSION .. ".jsonl"
local FRAME_FILE = LOG_DIR .. "/current_frame.txt"
local SESSION_FILE = LOG_DIR .. "/current_session.txt"
local GAME_FILE = LOG_DIR .. "/current_game.txt"

local in1 = manager.machine.ioport.ports[":IN1"]
local fld_p1_left = in1:field(0x8)
local fld_p1_right = in1:field(0x4)
local fld_p1_down = in1:field(0x2)
local fld_p1_rotate = in1:field(0x1)

local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]
local PF_BASE = 0x1000
local COL_LO, COL_HI = 10, 31
local ROW_LO, ROW_HI = 2, 29

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
    if gf then gf:write("atetris\n"); gf:close() end
    return true
end

local function btn(field)
    if field and field.live and field.live.value then
        return tonumber(field.live.value) ~= 0 and 1 or 0
    end
    return 0
end

local function tile_code(row, col)
    local idx = row * 64 + col
    local addr = PF_BASE + idx * 2
    local b0 = mem:read_u8(addr)
    local b1 = mem:read_u8(addr + 1)
    return b0 | ((b1 & 7) << 8)
end

-- Resumen ligero del tablero (alturas de columna) para no volcar los 2048
-- tiles enteros en cada frame grabado.
local function column_heights()
    local counts = {}
    local bg, bg_n = 0, -1
    for row = ROW_LO, ROW_HI do
        for col = COL_LO, COL_HI do
            local c = tile_code(row, col)
            counts[c] = (counts[c] or 0) + 1
            if counts[c] > bg_n then bg_n = counts[c]; bg = c end
        end
    end
    local heights = {}
    for col = COL_LO, COL_HI do
        local top = ROW_HI + 1
        for row = ROW_LO, ROW_HI do
            if tile_code(row, col) ~= bg then top = row; break end
        end
        heights[#heights + 1] = top
    end
    return heights
end

emu.register_frame_done(function()
    frame = frame + 1
    if not open_log() then return end

    if frame % 4 == 0 then
        local heights = column_heights()
        log:write(string.format(
            '{"frame":%d,"game":"atetris","heights":[%s],"input":{"left":%d,"right":%d,"down":%d,"rotate":%d}}\n',
            frame, table.concat(heights, ","),
            btn(fld_p1_left), btn(fld_p1_right), btn(fld_p1_down), btn(fld_p1_rotate)
        ))
        if frame % 60 == 0 then log:flush() end
    end

    local ff = io.open(FRAME_FILE, "w")
    if ff then ff:write(tostring(frame)); ff:close() end
end)

local function draw_overlay()
    local screen = manager.machine.screens[":screen"]
    if not screen then return end
    local tag = log and "REC+TEACH TETRIS" or "REC ERROR"
    screen:draw_text(4, 4, string.format("%s  f%d", tag, frame), 0xffffffff, 0xff000000)
end

emu.register_frame_done(draw_overlay)
