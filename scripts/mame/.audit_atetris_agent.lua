-- Atari Tetris — agente IA v9.1
-- v8 ya inyectaba inputs (hashΔ subía) pero en ~3s hacía top-out y se
-- quedaba en game-over con fill=238 congelado → "la IA no juega".
-- v9: recuperación coin+start si el playfield se congela.
-- v9.1: no contar stuck durante RECOVER (evitaba bucle infinito);
--       start más largo (como diag); menos rotación (es también START).

local ROOT = "/Users/pablo/Documents/arcade-ai"
local AGENT = "heuristic"
local LOG = "/tmp/atetris_ai_boot.log"

pcall(function()
    local f = io.open(LOG, "w")
    if f then
        f:write(string.format("[%s] atetris_ai.lua v9.1 LOAD ok agent=%s\n", os.date("%H:%M:%S"), AGENT))
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

local input = manager.machine.input
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local PF_BASE = 0x1000
local COL_LO, COL_HI = 14, 27
local ROW_LO, ROW_HI = 8, 24

local frame = 0
local boot_done = false
local debug_info = "init"
local move_phase = 0
local last_hash = -1
local hash_changes = 0
local stuck_frames = 0
local recover_until = 0
local games = 0

local function log(msg)
    pcall(function()
        local f = io.open(LOG, "a")
        if f then f:write(string.format("f%d %s\n", frame, msg)); f:close() end
    end)
end

local function press_key(tok, on)
    if not input or not tok then return end
    if not input.seq_set_value or not input.seq_from_tokens then return end
    pcall(function()
        local seq = input:seq_from_tokens(tok)
        if seq then input:seq_set_value(seq, on and 1 or 0) end
    end)
end

local function press(field, on, keycodes)
    if field then
        pcall(function()
            if on then
                field:set_value(1)
            elseif field.clear_value then
                field:clear_value()
            else
                field:set_value(0)
            end
        end)
        pcall(function()
            if field.input_seq and input and input.seq_set_value then
                local seq = field:input_seq("standard")
                if seq then input:seq_set_value(seq, on and 1 or 0) end
            end
        end)
    end
    if keycodes then
        for _, tok in ipairs(keycodes) do press_key(tok, on) end
    end
end

local KEY_L = { "KEYCODE_LEFT" }
local KEY_R = { "KEYCODE_RIGHT" }
local KEY_D = { "KEYCODE_DOWN" }
local KEY_ROT = { "KEYCODE_X" }
local KEY_START = { "KEYCODE_1", "KEYCODE_X" }
local KEY_COIN = { "KEYCODE_5" }

local function clear_play()
    press(fld_left, false, KEY_L)
    press(fld_right, false, KEY_R)
    press(fld_down, false, KEY_D)
    press(fld_rot, false, KEY_ROT)
    press_key("KEYCODE_Z", false)
    press_key("KEYCODE_SPACE", false)
    press_key("KEYCODE_UP", false)
    press_key("KEYCODE_1", false)
end

local function tile(row, col)
    local addr = PF_BASE + (row * 64 + col) * 2
    return mem:read_u8(addr) | ((mem:read_u8(addr + 1) & 7) << 8)
end

-- Fondo = tile más frecuente en el pozo (0 en partida; otro en attract/GO).
local function detect_bg()
    local counts = {}
    local best, nbest = 0, -1
    for row = ROW_LO, ROW_HI do
        for col = COL_LO, COL_HI do
            local t = tile(row, col)
            counts[t] = (counts[t] or 0) + 1
            if counts[t] > nbest then nbest = counts[t]; best = t end
        end
    end
    return best
end

local function playfield_stats()
    local bg = detect_bg()
    local filled, hash = 0, 0
    local heights = {}
    local piece_cols, piece_n = {}, 0
    local piece_min_row = ROW_HI + 1

    for col = COL_LO, COL_HI do
        local top = ROW_HI + 1
        for row = ROW_LO, ROW_HI do
            local t = tile(row, col)
            hash = (hash * 31 + t) % 2147483647
            if t ~= bg then
                filled = filled + 1
                if row < top then top = row end
                -- Pieza flotante: bloques en la mitad superior del pozo
                if row <= ROW_LO + 8 then
                    piece_n = piece_n + 1
                    piece_cols[col] = (piece_cols[col] or 0) + 1
                    if row < piece_min_row then piece_min_row = row end
                end
            end
        end
        heights[col] = (ROW_HI + 1) - top
    end

    local piece_cx = nil
    if piece_n >= 3 and piece_n <= 8 and piece_min_row <= ROW_LO + 6 then
        local sum, n = 0, 0
        for col, c in pairs(piece_cols) do
            sum = sum + col * c
            n = n + c
        end
        if n > 0 then piece_cx = sum / n end
    end

    return filled, hash, heights, bg, piece_cx, piece_n
end

local function choose_col(heights)
    local best, best_h = COL_LO, 999
    -- Reserva la última columna para piezas I; el resto al mínimo.
    for col = COL_LO, COL_HI - 1 do
        local h = heights[col] or 99
        if h < best_h then
            best_h = h
            best = col
        end
    end
    return best, best_h
end

local RECOVER_LEN = 280

local function do_boot_pulse(phase_frame)
    -- Coin corto + start largo (diag: ~160 frames de Button1).
    if phase_frame == 10 then
        press(fld_coin, true, KEY_COIN)
    elseif phase_frame == 25 then
        press(fld_coin, false, KEY_COIN)
    elseif phase_frame >= 60 and phase_frame <= 220 then
        press(fld_rot, true, KEY_START)
    elseif phase_frame == 230 then
        press(fld_rot, false, KEY_START)
    elseif phase_frame >= 250 and phase_frame <= 265 then
        -- Segundo tap por si el menú pide confirmación
        press(fld_rot, true, KEY_START)
    elseif phase_frame == 270 then
        press(fld_rot, false, KEY_START)
    end
end

local function boot()
    -- No clear_play en cada frame del boot: evita glitches en POKEY.
    if frame < 60 or (frame >= 60 and frame <= 220) or (frame >= 250 and frame <= 270) then
        -- solo pulsos
    else
        clear_play()
    end
    do_boot_pulse(frame)
    if frame == 10 then log("coin down") end
    if frame == 60 then log("start hold begin") end
    if frame >= RECOVER_LEN then
        boot_done = true
        games = 1
        stuck_frames = 0
        log("BOOT DONE — IA juega")
    end
    debug_info = string.format("BOOT %d", frame)
end

local function start_recover()
    games = games + 1
    recover_until = frame + RECOVER_LEN
    stuck_frames = 0
    log(string.format("RECOVER game #%d", games))
end

local function act()
    local in_recover = frame < recover_until
    local filled, hash, heights, bg, piece_cx, piece_n = playfield_stats()

    if not in_recover then
        if hash ~= last_hash then
            hash_changes = hash_changes + 1
            last_hash = hash
            stuck_frames = 0
        else
            stuck_frames = stuck_frames + 1
        end
        if stuck_frames > 200 then
            start_recover()
            in_recover = true
        end
    else
        -- Durante recover no acumular stuck; al salir se reinicia.
        if frame == recover_until - 1 then
            stuck_frames = 0
            last_hash = hash
        end
    end

    if in_recover then
        local pf = frame - (recover_until - RECOVER_LEN)
        -- No clear durante hold de start (mismos rangos que do_boot_pulse)
        if not ((pf >= 60 and pf <= 220) or (pf >= 250 and pf <= 270) or pf == 10 or pf == 25) then
            clear_play()
        end
        do_boot_pulse(pf)
        debug_info = string.format("RECOVER %d g=%d", pf, games)
        if frame % 60 == 0 then log(debug_info) end
        return
    end

    clear_play()
    move_phase = move_phase + 1
    local target, th = choose_col(heights)
    local sub = move_phase % 48

    -- Rotar muy poco (Button1 = start): 2 frames cada ~0.8 s
    if sub <= 1 then
        press(fld_rot, true, KEY_ROT)
        debug_info = string.format("ROT fill=%d", filled)
    else
        press(fld_down, true, KEY_D)

        local steer = nil
        if piece_cx then
            if piece_cx < target - 0.6 then steer = "R"
            elseif piece_cx > target + 0.6 then steer = "L"
            end
        else
            local mid = math.floor((COL_LO + COL_HI) / 2)
            if target >= mid then steer = "R" else steer = "L" end
        end

        if steer == "R" and (sub % 3) ~= 0 then
            press(fld_right, true, KEY_R)
            debug_info = string.format("RIGHT cx=%.1f→%d", piece_cx or -1, target)
        elseif steer == "L" and (sub % 3) ~= 0 then
            press(fld_left, true, KEY_L)
            debug_info = string.format("LEFT cx=%.1f→%d", piece_cx or -1, target)
        else
            debug_info = string.format("DOWN tgt=%d h=%d n=%d", target, th, piece_n)
        end
    end

    if frame % 60 == 0 then
        log(string.format(
            "%s fill=%d bg=%d Δ=%d stuck=%d g=%d",
            debug_info, filled, bg, hash_changes, stuck_frames, games
        ))
    end
end

local function overlay()
    local screen = manager.machine.screens[":screen"]
    if not screen then return end
    screen:draw_text(4, 4, "AI v9.1 " .. AGENT .. " | " .. debug_info, 0xffffffff, 0xff000000)
    screen:draw_text(4, 14, string.format(
        "Δhash=%d stuck=%d games=%d", hash_changes, stuck_frames, games
    ), 0xff88ff88, 0xff000000)
    screen:draw_text(4, 24, "si Δhash sube, la IA está jugando", 0xffccff66, 0xff000000)
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
