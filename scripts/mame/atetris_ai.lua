-- Atari Tetris — agente IA v11 (placement heurístico)
-- v10 movía pero soft-drop + steer ciego → torre desordenada.
-- v11:
--   * Tablero locked vs pieza flotante (~4 celdas)
--   * Evalúa cada desplazamiento horizontal (orientación actual)
--   * Score: líneas, agujeros, altura, bumpiness (Dellacherie-ish)
--   * Ejecuta: alinear SIN bajar → luego soft-drop
--   * Boot: coin → start → RIGHT → confirm (como v10)

local ROOT = "/Users/pablo/Documents/arcade-ai"
local AGENT = "heuristic"
local LOG = "/tmp/atetris_ai_boot.log"

pcall(function()
    local f = io.open(LOG, "w")
    if f then
        f:write(string.format("[%s] atetris_ai.lua v11 LOAD ok agent=%s\n", os.date("%H:%M:%S"), AGENT))
        f:close()
    end
end)

local function safe_field(port, mask)
    if not port then return nil end
    local ok, f = pcall(function() return port:field(mask) end)
    return ok and f or nil
end

local in0 = manager.machine.ioport.ports[":IN0"]
local in1 = manager.machine.ioport.ports[":IN1"]
local fld_coin = safe_field(in0, 0x2)
local fld_left = safe_field(in1, 0x8)
local fld_right = safe_field(in1, 0x4)
local fld_down = safe_field(in1, 0x2)
local fld_rot = safe_field(in1, 0x1)

local mem = manager.machine.devices[":maincpu"].spaces["program"]
local PF_BASE = 0x1000
local COL_LO, COL_HI = 2, 11
local ROW_LO, ROW_HI = 4, 24
local NCOL = COL_HI - COL_LO + 1
local NROW = ROW_HI - ROW_LO + 1

local frame = 0
local boot_done = false
local debug_info = "init"
local last_hash = -1
local hash_changes = 0
local stuck_frames = 0
local recover_until = 0
local games = 0
local BOOT_LEN = 320

-- Tablero bloqueado (sin pieza activa). false = vacío.
local locked = {}
local plan = nil          -- {dx, target_cx, score}
local rot_taps_left = 0   -- rotaciones pendientes al nacer pieza
local rot_cooldown = 0
local move_cooldown = 0
local last_piece_sig = ""
local no_piece_frames = 0

local function log(msg)
    pcall(function()
        local f = io.open(LOG, "a")
        if f then f:write(string.format("f%d %s\n", frame, msg)); f:close() end
    end)
end

local function press(field, on)
    if not field then return end
    pcall(function()
        if on then field:set_value(1)
        elseif field.clear_value then field:clear_value()
        else field:set_value(0) end
    end)
end

local function clear_all()
    press(fld_coin, false)
    press(fld_left, false)
    press(fld_right, false)
    press(fld_down, false)
    press(fld_rot, false)
end

local function tile(row, col)
    local addr = PF_BASE + (row * 64 + col) * 2
    return mem:read_u8(addr) | ((mem:read_u8(addr + 1) & 7) << 8)
end

local function idx(row, col)
    return (row - ROW_LO) * NCOL + (col - COL_LO) + 1
end

local function reset_locked()
    locked = {}
    for row = ROW_LO, ROW_HI do
        for col = COL_LO, COL_HI do
            locked[idx(row, col)] = false
        end
    end
end
reset_locked()

local function read_filled()
    local filled = {}
    local hash, n = 0, 0
    for row = ROW_LO, ROW_HI do
        for col = COL_LO, COL_HI do
            local t = tile(row, col)
            local on = (t ~= 0)
            filled[idx(row, col)] = on
            hash = (hash * 31 + t) % 2147483647
            if on then n = n + 1 end
        end
    end
    return filled, hash, n
end

-- Pieza = celdas llenas que NO están en locked (3..5 típico).
local function extract_piece(filled)
    local cells = {}
    for row = ROW_LO, ROW_HI do
        for col = COL_LO, COL_HI do
            local i = idx(row, col)
            if filled[i] and not locked[i] then
                cells[#cells + 1] = { row = row, col = col }
            end
        end
    end
    return cells
end

local function piece_signature(cells)
    if #cells == 0 then return "" end
    -- Firma relativa (forma), no posición absoluta — si no, cada frame
    -- al caer la pieza parece "nueva" y se replanifica en bucle.
    local minc, maxc, minr = 99, -99, 99
    for _, c in ipairs(cells) do
        if c.col < minc then minc = c.col end
        if c.col > maxc then maxc = c.col end
        if c.row < minr then minr = c.row end
    end
    local parts = {}
    for _, c in ipairs(cells) do
        parts[#parts + 1] = (c.row - minr) .. ":" .. (c.col - minc)
    end
    table.sort(parts)
    return table.concat(parts, ";") .. "#n" .. #cells
end

local function piece_center(cells)
    local sx, sy, n = 0, 0, #cells
    for _, c in ipairs(cells) do
        sx = sx + c.col
        sy = sy + c.row
    end
    return sx / n, sy / n
end

local function piece_bounds(cells)
    local minc, maxc = 99, -99
    local minr, maxr = 99, -99
    for _, c in ipairs(cells) do
        if c.col < minc then minc = c.col end
        if c.col > maxc then maxc = c.col end
        if c.row < minr then minr = c.row end
        if c.row > maxr then maxr = c.row end
    end
    return minc, maxc, minr, maxr
end

-- Si no hay pieza clara, resincroniza locked = filled (todo asentado).
local function sync_locked(filled, cells)
    if #cells >= 3 and #cells <= 5 then return end
    for row = ROW_LO, ROW_HI do
        for col = COL_LO, COL_HI do
            locked[idx(row, col)] = filled[idx(row, col)]
        end
    end
end

local function can_place(cells, board)
    for _, c in ipairs(cells) do
        if c.col < COL_LO or c.col > COL_HI then return false end
        if c.row < ROW_LO or c.row > ROW_HI then return false end
        if board[idx(c.row, c.col)] then return false end
    end
    return true
end

local function translate(cells, dc, dr)
    local out = {}
    for i, c in ipairs(cells) do
        out[i] = { row = c.row + dr, col = c.col + dc }
    end
    return out
end

local function drop_piece(cells, board)
    local cur = cells
    while true do
        local nxt = translate(cur, 0, 1)
        if not can_place(nxt, board) then return cur end
        cur = nxt
    end
end

local function merge_board(board, cells)
    local b = {}
    for i = 1, NROW * NCOL do b[i] = board[i] end
    for _, c in ipairs(cells) do
        b[idx(c.row, c.col)] = true
    end
    return b
end

local function clear_lines(board)
    local out = {}
    for i = 1, NROW * NCOL do out[i] = false end
    local write_row = ROW_HI
    local cleared = 0
    for row = ROW_HI, ROW_LO, -1 do
        local full = true
        for col = COL_LO, COL_HI do
            if not board[idx(row, col)] then full = false; break end
        end
        if full then
            cleared = cleared + 1
        else
            for col = COL_LO, COL_HI do
                out[idx(write_row, col)] = board[idx(row, col)]
            end
            write_row = write_row - 1
        end
    end
    return out, cleared
end

local function column_heights(board)
    local h = {}
    for col = COL_LO, COL_HI do
        local height = 0
        for row = ROW_LO, ROW_HI do
            if board[idx(row, col)] then
                height = (ROW_HI + 1) - row
                break
            end
        end
        h[col] = height
    end
    return h
end

local function count_holes(board)
    local holes = 0
    for col = COL_LO, COL_HI do
        local block = false
        for row = ROW_LO, ROW_HI do
            if board[idx(row, col)] then
                block = true
            elseif block then
                holes = holes + 1
            end
        end
    end
    return holes
end

local function bumpiness(heights)
    local b = 0
    for col = COL_LO, COL_HI - 1 do
        b = b + math.abs(heights[col] - heights[col + 1])
    end
    return b
end

local function aggregate_height(heights)
    local s = 0
    for col = COL_LO, COL_HI do s = s + heights[col] end
    return s
end

-- Pesos estilo heurística clásica (evitar agujeros > todo).
local function score_board(board, cleared, landing_row)
    local heights = column_heights(board)
    local holes = count_holes(board)
    local bump = bumpiness(heights)
    local agg = aggregate_height(heights)
    local land = (ROW_HI + 1) - landing_row
    return cleared * 760 - holes * 510 - bump * 18 - agg * 12 - land * 25
end

local function plan_placement(cells)
    local minc, maxc = piece_bounds(cells)
    local width = maxc - minc + 1
    local best, best_s = nil, -1e18
    -- dx relativo al bounding box izquierdo
    for left = COL_LO, COL_HI - width + 1 do
        local dx = left - minc
        local shifted = translate(cells, dx, 0)
        if can_place(shifted, locked) then
            local dropped = drop_piece(shifted, locked)
            if can_place(dropped, locked) then
                local _, _, minr = piece_bounds(dropped)
                local merged = merge_board(locked, dropped)
                local after, cleared = clear_lines(merged)
                local s = score_board(after, cleared, minr)
                if s > best_s then
                    best_s = s
                    local cx = 0
                    for _, c in ipairs(dropped) do cx = cx + c.col end
                    best = {
                        dx = dx,
                        target_left = left,
                        target_cx = cx / #dropped,
                        score = s,
                        cleared = cleared,
                    }
                end
            end
        end
    end
    return best
end

local function do_boot_pulse(pf)
    if pf == 20 then press(fld_coin, true)
    elseif pf == 35 then press(fld_coin, false)
    elseif pf >= 80 and pf <= 95 then press(fld_rot, true)
    elseif pf == 96 then press(fld_rot, false)
    elseif pf >= 130 and pf <= 175 then
        if (pf % 8) < 3 then press(fld_right, true) end
    elseif pf >= 200 and pf <= 220 then press(fld_rot, true)
    elseif pf == 221 then press(fld_rot, false)
    end
end

local function boot()
    clear_all()
    do_boot_pulse(frame)
    if frame == 20 then log("coin") end
    if frame == 80 then log("start→select") end
    if frame == 200 then log("confirm→play") end
    if frame >= BOOT_LEN then
        boot_done = true
        games = 1
        stuck_frames = 0
        reset_locked()
        plan = nil
        log("BOOT DONE — IA juega (v11 placement)")
    end
    debug_info = string.format("BOOT %d", frame)
end

local function start_recover()
    games = games + 1
    recover_until = frame + BOOT_LEN
    stuck_frames = 0
    reset_locked()
    plan = nil
    log(string.format("RECOVER game #%d", games))
end

local function act()
    local in_recover = frame < recover_until
    local filled, hash, fill_n = read_filled()
    local cells = extract_piece(filled)

    if not in_recover then
        if hash ~= last_hash then
            hash_changes = hash_changes + 1
            last_hash = hash
            stuck_frames = 0
        else
            stuck_frames = stuck_frames + 1
        end
        if stuck_frames > 360 then
            start_recover()
            in_recover = true
        end
    elseif frame == recover_until - 1 then
        stuck_frames = 0
        last_hash = hash
    end

    clear_all()
    if in_recover then
        local pf = frame - (recover_until - BOOT_LEN)
        do_boot_pulse(pf)
        debug_info = string.format("RECOVER %d g=%d", pf, games)
        return
    end

    -- Sin pieza clara: asentar tablero y esperar
    if #cells < 3 or #cells > 6 then
        no_piece_frames = no_piece_frames + 1
        if no_piece_frames > 8 then
            sync_locked(filled, cells)
            plan = nil
            last_piece_sig = ""
        end
        debug_info = string.format("WAIT fill=%d pc=%d", fill_n, #cells)
        return
    end
    no_piece_frames = 0

    local sig = piece_signature(cells)
    local cx = select(1, piece_center(cells))
    local minc, maxc, minr, maxr = piece_bounds(cells)

    -- Nueva pieza → planificar (+ 1 rotación exploratoria si es alta/estrecha)
    if sig ~= last_piece_sig then
        last_piece_sig = sig
        plan = plan_placement(cells)
        local height = maxr - minr + 1
        local width = maxc - minc + 1
        -- Piezas altas (I vertical, etc.): prueba 1 rotación al nacer
        if width <= 2 and height >= 3 then
            rot_taps_left = 1
        else
            rot_taps_left = 0
        end
        rot_cooldown = 0
        move_cooldown = 0
        if plan then
            log(string.format("PLAN left=%d sc=%.0f clr=%d cx=%.1f",
                plan.target_left, plan.score, plan.cleared, plan.target_cx))
        end
    elseif plan == nil then
        plan = plan_placement(cells)
    end

    -- Re-plan tras rotar
    if rot_taps_left == 0 and rot_cooldown == 1 then
        plan = plan_placement(cells)
        rot_cooldown = 0
    end

    if rot_cooldown > 0 then rot_cooldown = rot_cooldown - 1 end
    if move_cooldown > 0 then move_cooldown = move_cooldown - 1 end

    -- 1) Rotar si toca (tap corto)
    if rot_taps_left > 0 and rot_cooldown == 0 then
        press(fld_rot, true)
        rot_taps_left = rot_taps_left - 1
        rot_cooldown = 10  -- espera a que la pieza rote en RAM
        debug_info = string.format("ROT left=%d", rot_taps_left)
        return
    end

    if not plan then
        press(fld_down, true)
        debug_info = "DROP no-plan"
        return
    end

    -- 2) Alinear horizontalmente SIN soft-drop (por borde izquierdo)
    local err = minc - plan.target_left
    if math.abs(err) > 0 then
        if move_cooldown == 0 then
            if err < 0 then
                press(fld_right, true)
                debug_info = string.format("→ %d→%d sc=%.0f", minc, plan.target_left, plan.score)
            else
                press(fld_left, true)
                debug_info = string.format("← %d→%d sc=%.0f", minc, plan.target_left, plan.score)
            end
            move_cooldown = 4
        else
            debug_info = string.format("hold %d→%d", minc, plan.target_left)
        end
        return
    end

    -- 3) Alineado → soft-drop
    press(fld_down, true)
    debug_info = string.format("↓ sc=%.0f L=%d", plan.score, plan.cleared)

    if frame % 60 == 0 then
        log(string.format("%s fill=%d Δ=%d", debug_info, fill_n, hash_changes))
    end
end

local function overlay()
    local screen = manager.machine.screens[":screen"]
    if not screen then return end
    screen:draw_text(4, 4, "AI v11 " .. AGENT .. " | " .. debug_info, 0xffffffff, 0xff000000)
    local p = plan and string.format("tgt=%.1f sc=%.0f", plan.target_cx, plan.score) or "no-plan"
    screen:draw_text(4, 14, string.format("Δ=%d %s", hash_changes, p), 0xff88ff88, 0xff000000)
end

emu.register_frame_done(function()
    local ok, err = pcall(function()
        frame = frame + 1
        if not boot_done then boot() else act() end
        overlay()
    end)
    if not ok then
        log("ERROR " .. tostring(err))
        debug_info = "ERR " .. tostring(err)
    end
end)
