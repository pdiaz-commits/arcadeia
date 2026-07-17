-- Graba la demo de atract mode de Atari Tetris → logs/demos/attract_atetris_*.jsonl
-- Sin moneda, sin input humano: el arcade juega solo.
-- El extractor (scripts/learn_from_attract_atetris.py) infiere reglas del
-- tipo { depth_sum, target_left } que el agente ya consume en
-- scripts/mame/atetris_ai.lua (match_attract_tactic).

local ROOT = "/Users/pablo/Documents/arcade-ai"
local LOG_DIR = ROOT .. "/logs/demos"
local SESSION = "attract_atetris_" .. os.date("%Y%m%d_%H%M%S")
local LOG_PATH = LOG_DIR .. "/" .. SESSION .. ".jsonl"

local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]
local PF_BASE = 0x1000

local COL_LO, COL_HI = 14, 27  -- 14 columnas (las del pozo de juego)
local ROW_LO, ROW_HI = 8, 24   -- 17 filas del playfield (la UI lateral queda fuera)
local BG_ROW_LO, BG_ROW_HI = 2, 29
local BG_COL_LO, BG_COL_HI = 0, 63

local RECORD_FRAMES = 5000    -- ~83 s a 60 fps; suficiente para ~30 piezas en demo

local frame = 0
local log = nil
local last_bg = 0

local function tile_code(row, col)
    local idx = row * 64 + col
    local addr = PF_BASE + idx * 2
    local b0 = mem:read_u8(addr)
    local b1 = mem:read_u8(addr + 1)
    return b0 | ((b1 & 7) << 8)
end

local function detect_background()
    local counts = {}
    local best_code, best_count = 0, -1
    for row = BG_ROW_LO, BG_ROW_HI do
        for col = BG_COL_LO, BG_COL_HI do
            local c = tile_code(row, col)
            counts[c] = (counts[c] or 0) + 1
            if counts[c] > best_count then best_count = counts[c]; best_code = c end
        end
    end
    return best_code
end

-- Replica exacta de stack_depths() / column_topmost() de atetris_ai.lua.
local function column_topmost(bg)
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

local function stack_depths_for_piece(bg, cells)
    local piece_rows = {}
    for _, c in ipairs(cells) do piece_rows[c.row] = true end
    local depths = {}
    for col = COL_LO, COL_HI do
        local depth = 0
        for row = ROW_HI, ROW_LO, -1 do
            if piece_rows[row] then
                -- skip (equivalente al `goto continue` del agente)
            elseif tile_code(row, col) ~= bg then
                depth = ROW_HI - row + 1
                break
            end
        end
        depths[#depths + 1] = depth
    end
    return depths
end

local function find_active_piece(bg)
    -- Replica exacta de find_active_piece() del agente: busca el topmost
    -- non-bg cell en [ROW_LO, ROW_HI]. Esto da cells del "active piece"
    -- mientras cae, y del stack top una vez la pieza está settle.
    -- Por eso el extractor usa piece_cells crudo + tracking de estabilidad.
    local min_row = ROW_HI + 1
    for row = ROW_LO, ROW_HI do
        for col = COL_LO, COL_HI do
            if tile_code(row, col) ~= bg and row < min_row then
                min_row = row
            end
        end
    end
    if min_row > ROW_HI then return {} end
    local cells = {}
    for row = min_row, math.min(min_row + 3, ROW_HI) do
        for col = COL_LO, COL_HI do
            if tile_code(row, col) ~= bg then
                cells[#cells + 1] = { row = row, col = col }
            end
        end
    end
    return cells
end

local function cells_signature(cells)
    if #cells == 0 then return "NONE" end
    local parts = {}
    for _, c in ipairs(cells) do
        parts[#parts + 1] = c.row .. ":" .. c.col
    end
    table.sort(parts)
    return table.concat(parts, ",")
end

-- Serializa cells como lista compacta "row:col;row:col;..." para análisis
-- offline. Permite reconstruir el set exacto de celdas del "active piece"
-- en el extractor Python (clave para identificar la pieza que cae vs el
-- stack estable, distinción que find_active_piece pierde al settle).
local function cells_to_compact(cells)
    if #cells == 0 then return "" end
    local parts = {}
    for _, c in ipairs(cells) do
        parts[#parts + 1] = c.row .. ":" .. c.col
    end
    table.sort(parts)
    return table.concat(parts, ";")
end

local function open_log()
    if log then return true end
    os.execute("mkdir -p " .. LOG_DIR)
    log = io.open(LOG_PATH, "w")
    if not log then return false end
    log:write(string.format(
        '{"type":"meta","session":"%s","game":"atetris","source":"attract_demo","col_lo":%d,"col_hi":%d,"row_lo":%d,"row_hi":%d}\n',
        SESSION, COL_LO, COL_HI, ROW_LO, ROW_HI
    ))
    return true
end

local function write_rows_string(arr)
    return table.concat(arr, ",")
end

local function draw_overlay()
    local screen = manager.machine.screens[":screen"]
    if not screen then return end
    screen:draw_text(4, 4, string.format("REC ATTRACT TETRIS  %d/%d", frame, RECORD_FRAMES), 0xffffffff, 0xff000000)
    screen:draw_text(4, 16, "Sin moneda — el arcade juega solo", 0xffccff66, 0xff000000)
end

emu.register_frame_done(function()
    frame = frame + 1
    if not open_log() then return end
    if frame % 4 ~= 0 then return end

    last_bg = detect_background()
    local cells = find_active_piece(last_bg)
    local heights = column_topmost(last_bg)
    local depths = stack_depths_for_piece(last_bg, cells)
    local sig = cells_signature(cells)
    local piece_left, piece_right, piece_top = -1, -1, -1
    for _, c in ipairs(cells) do
        if piece_left == -1 or c.col < piece_left then piece_left = c.col end
        if piece_right == -1 or c.col > piece_right then piece_right = c.col end
        if piece_top == -1 or c.row < piece_top then piece_top = c.row end
    end

    log:write(string.format(
        '{"frame":%d,"bg":%d,"heights":[%s],"depths":[%s],"piece_sig":"%s","piece_cells":"%s","piece_left":%d,"piece_right":%d,"piece_top":%d}\n',
        frame, last_bg, write_rows_string(heights), write_rows_string(depths),
        sig, cells_to_compact(cells), piece_left, piece_right, piece_top
    ))

    if frame % 120 == 0 then log:flush() end
    if frame >= RECORD_FRAMES then
        log:write('{"type":"end"}\n')
        log:close()
        log = nil
        manager.machine:exit()
    end
end)

emu.register_frame_done(draw_overlay)