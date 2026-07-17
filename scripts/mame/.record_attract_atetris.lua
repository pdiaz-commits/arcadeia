-- Graba la demo de attract mode de Atari Tetris (SIN moneda).
-- Observa cómo el juego coloca piezas y registra alturas + movimiento.

local ROOT = "/Users/pablo/Documents/arcade-ai"
local LOG_DIR = ROOT .. "/logs/demos"
local SESSION = "attract_atetris_" .. os.date("%Y%m%d_%H%M%S")
local LOG_PATH = LOG_DIR .. "/" .. SESSION .. ".jsonl"

local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]
local PF_BASE = 0x1000

local COL_LO, COL_HI = 14, 27
local ROW_LO, ROW_HI = 8, 24
local RECORD_START = 300    -- ~10 s: demo suele empezar tras título
local RECORD_FRAMES = 3000  -- ~90 s de demo

local frame = 0
local log = nil
local prev_left = nil
local prev_top = nil
local prev_heights_key = nil

local function tile_code(row, col)
    local idx = row * 64 + col
    local addr = PF_BASE + idx * 2
    return mem:read_u8(addr) | ((mem:read_u8(addr + 1) & 7) << 8)
end

local function detect_background()
    local counts = {}
    local best_code, best_count = 0, -1
    for row = ROW_LO, ROW_HI do
        for col = COL_LO, COL_HI do
            local code = tile_code(row, col)
            counts[code] = (counts[code] or 0) + 1
            if counts[code] > best_count then
                best_count = counts[code]
                best_code = code
            end
        end
    end
    return best_code
end

local function column_depths(bg)
    local depths = {}
    for col = COL_LO, COL_HI do
        local depth = 0
        for row = ROW_HI, ROW_LO, -1 do
            if tile_code(row, col) ~= bg then
                depth = ROW_HI - row + 1
                break
            end
        end
        depths[col - COL_LO + 1] = depth
    end
    return depths
end

local function find_piece(bg)
    local min_row = ROW_HI + 1
    for row = ROW_LO, ROW_HI do
        for col = COL_LO, COL_HI do
            if tile_code(row, col) ~= bg and row < min_row then
                min_row = row
            end
        end
    end
    if min_row > ROW_HI then return nil end

    local left, right, cells = COL_HI, COL_LO, 0
    for row = min_row, math.min(min_row + 3, ROW_HI) do
        for col = COL_LO, COL_HI do
            if tile_code(row, col) ~= bg then
                cells = cells + 1
                if col < left then left = col end
                if col > right then right = col end
            end
        end
    end
    if cells == 0 then return nil end
    return { left = left, right = right, top = min_row, cells = cells }
end

local function open_log()
    if log then return true end
    os.execute("mkdir -p " .. LOG_DIR)
    log = io.open(LOG_PATH, "w")
    if not log then return false end
    log:write('{"type":"meta","game":"atetris","source":"attract_demo"}\n')
    return true
end

emu.register_frame_done(function()
    frame = frame + 1
    if frame < RECORD_START or frame % 2 ~= 0 then return end
    if frame > RECORD_START + RECORD_FRAMES then
        if log then
            log:write('{"type":"end","frames":' .. frame .. "}\n")
            log:close()
        end
        manager.machine:exit()
        return
    end
    if not open_log() then return end

    local bg = detect_background()
    local depths = column_depths(bg)
    local piece = find_piece(bg)
    local depth_sum = 0
    for i = 1, #depths do depth_sum = depth_sum + depths[i] end

    local motion = { left = 0, right = 0, down = 0, rotate = 0 }
    if piece and prev_left then
        local dx = piece.left - prev_left
        if dx > 0 then motion.right = 1
        elseif dx < 0 then motion.left = 1 end
        if prev_top and piece.top > prev_top then motion.down = 1 end
        if piece.cells ~= (prev_cells or piece.cells) then motion.rotate = 1 end
    end

    local landed = false
    if piece and prev_left and prev_top then
        if piece.top < prev_top - 6 or (prev_top > ROW_LO + 4 and piece.top <= ROW_LO + 2) then
            landed = true
        end
    end

    local heights_key = table.concat(depths, ",")
    if heights_key ~= prev_heights_key and prev_heights_key then
        landed = true
    end

    log:write(string.format(
        '{"frame":%d,"game":"atetris","depths":[%s],"depth_sum":%d,"piece":%s,"motion":{"left":%d,"right":%d,"down":%d,"rotate":%d},"landed":%s}\n',
        frame,
        table.concat(depths, ","),
        depth_sum,
        piece and string.format('{"left":%d,"right":%d,"top":%d,"cells":%d}', piece.left, piece.right, piece.top, piece.cells) or "null",
        motion.left, motion.right, motion.down, motion.rotate,
        landed and "true" or "false"
    ))

    if piece then
        prev_left = piece.left
        prev_top = piece.top
        prev_cells = piece.cells
    else
        prev_left = nil
        prev_top = nil
        prev_cells = nil
    end
    prev_heights_key = heights_key

    if frame % 120 == 0 then log:flush() end
end)

local function draw_overlay()
    local screen = manager.machine.screens[":screen"]
    if not screen then return end
    local tag = "REC ATTRACT TETRIS (sin moneda)"
    if frame >= RECORD_START then tag = tag .. " REC" end
    screen:draw_text(4, 4, string.format("%s  f%d", tag, frame), 0xffffffff, 0xff000000)
end

emu.register_frame_done(draw_overlay)
