-- Wrapper Lua: carga el agente atetris_ai.lua (parcheado con AGENT) + observer
-- no-invasivo que loguea per-frame el estado del tablero para auditoría.
-- El agente y el observer registran callbacks frame_done independientes
-- (MAME los ejecuta en orden de registro).

local ROOT = "/Users/pablo/Documents/arcade-ai"
local LOG_DIR = ROOT .. "/logs/demos"
local SESSION = os.date("atetris_audit_%Y%m%d_%H%M%S")
local LOG_PATH = LOG_DIR .. "/" .. SESSION .. ".jsonl"

os.execute("mkdir -p " .. LOG_DIR)

local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]
local PF_BASE = 0x1000
local COL_LO, COL_HI = 14, 27
local ROW_LO, ROW_HI = 8, 24
local BG_ROW_LO, BG_ROW_HI = 2, 29
local BG_COL_LO, BG_COL_HI = 0, 63
local N_COLS = COL_HI - COL_LO
local N_ROWS = ROW_HI - ROW_LO

local log = io.open(LOG_PATH, "w")
if log then
    log:write(string.format(
        '{"type":"meta","session":"%s","source":"atetris_audit","col_lo":%d,"col_hi":%d,"row_lo":%d,"row_hi":%d}\n',
        SESSION, COL_LO, COL_HI, ROW_LO, ROW_HI
    ))
    log:flush()
end

local frame = 0

local function tile_code(row, col)
    local idx = row * 64 + col
    local addr = PF_BASE + idx * 2
    local b0 = mem:read_u8(addr)
    local b1 = mem:read_u8(addr + 1)
    return b0 | ((b1 & 7) << 8)
end

local function detect_background()
    local counts = {}
    local best, best_n = 0, -1
    for row = BG_ROW_LO, BG_ROW_HI do
        for col = BG_COL_LO, BG_COL_HI do
            local c = tile_code(row, col)
            counts[c] = (counts[c] or 0) + 1
            if counts[c] > best_n then best_n, best = counts[c], c end
        end
    end
    return best
end

local function read_grid(bg)
    local grid = {}
    local total = 0
    for row = ROW_LO, ROW_HI do
        grid[row] = {}
        for col = COL_LO, COL_HI do
            local c = tile_code(row, col)
            grid[row][col] = c
            if c ~= bg then total = total + 1 end
        end
    end
    return grid, total
end

local function heights(grid, bg)
    local h = {}
    for col = COL_LO, COL_HI do
        local top = ROW_HI + 1
        for row = ROW_LO, ROW_HI do
            if grid[row][col] ~= bg then top = row; break end
        end
        h[col] = top  -- row index of topmost !=bg, or ROW_HI+1 if empty
    end
    return h
end

local function cells_signature(grid, bg)
    -- Serializa cells !=bg como "r:c;r:c;..."
    local parts = {}
    for row = ROW_LO, ROW_HI do
        for col = COL_LO, COL_HI do
            if grid[row][col] ~= bg then
                parts[#parts + 1] = row .. ":" .. col
            end
        end
    end
    return table.concat(parts, ";")
end

local function stack_depths(grid, bg, cells)
    -- Reproduce la fórmula de stack_depths() en atetris_ai.lua
    local piece_rows = {}
    for _, c in ipairs(cells) do piece_rows[c.row] = true end
    local d = {}
    for col = COL_LO, COL_HI do
        local depth = 0
        for row = ROW_HI, ROW_LO, -1 do
            if piece_rows[row] then
                -- skip
            elseif grid[row][col] ~= bg then
                depth = ROW_HI - row + 1
                break
            end
        end
        d[col] = depth
    end
    return d
end

local function find_active_piece(grid, bg)
    local min_row = ROW_HI + 1
    for row = ROW_LO, ROW_HI do
        for col = COL_LO, COL_HI do
            if grid[row][col] ~= bg and row < min_row then
                min_row = row
            end
        end
    end
    if min_row > ROW_HI then return {}, min_row end
    local cells = {}
    for row = min_row, math.min(min_row + 3, ROW_HI) do
        for col = COL_LO, COL_HI do
            if grid[row][col] ~= bg then
                cells[#cells + 1] = { row = row, col = col }
            end
        end
    end
    return cells, min_row
end

-- Detección de settle + placements: piece_cells estable K=8 frames => settle.
-- Luego, comparando con el siguiente "piece change" event, sabemos
-- target_left.
local last_sig = ""
local stable_count = 0
local last_heights_at_settle = nil

emu.register_frame_done(function()
    frame = frame + 1
    if not log then return end
    if frame % 4 ~= 0 then return end  -- log every 4 frames (~15 Hz)

    local bg = detect_background()
    local grid, total_filled = read_grid(bg)
    local cells, min_top = find_active_piece(grid, bg)
    local h = heights(grid, bg)
    local d = stack_depths(grid, bg, cells)
    local sig = cells_signature(grid, bg)

    local piece_left, piece_right, piece_top = -1, -1, -1
    for _, c in ipairs(cells) do
        if piece_left == -1 or c.col < piece_left then piece_left = c.col end
        if piece_right == -1 or c.col > piece_right then piece_right = c.col end
        if piece_top == -1 or c.row < piece_top then piece_top = c.row end
    end

    -- Detección de settle: piece_cells no cambia K=8 frames consecutivos
    local sig_now = ""
    for _, c in ipairs(cells) do sig_now = sig_now .. c.row .. ":" .. c.col .. ";" end
    if sig_now == last_sig and sig_now ~= "" then
        stable_count = stable_count + 1
    else
        stable_count = 0
    end
    last_sig = sig_now
    local settled = (stable_count >= 8) and 1 or 0

    -- Detección de line clear: total_filled cae en ≥14 entre frames consecutivos
    local prev_total = _G.__prev_total or total_filled
    local line_clear = 0
    if prev_total > total_filled and (prev_total - total_filled) >= 14 then
        line_clear = math.floor((prev_total - total_filled) / 14)
    end
    _G.__prev_total = total_filled

    -- Depth_sum (mismo cálculo que atetris_ai.lua)
    local depth_sum = 0
    for i = 1, #d do depth_sum = depth_sum + (d[i] or 0) end

    log:write(string.format(
        '{"f":%d,"tf":%d,"ds":%d,"h":[%s],"d":[%s],"pl":%d,"pr":%d,"pt":%d,"settled":%d,"lc":%d,"sig":"%s"}\n',
        frame, total_filled, depth_sum,
        table.concat(h, ","),
        table.concat(d, ","),
        piece_left, piece_right, piece_top,
        settled, line_clear,
        sig_now
    ))
    if frame % 60 == 0 then log:flush() end
end)

-- CARGAR EL AGENTE (parcheado con AGENT por scripts/audit_atetris.py)
dofile(ROOT .. "/scripts/mame/.audit_atetris_agent.lua")

if log then log:write('{"type":"end_observer_loaded"}\n'); log:flush() end