-- Ghosts'n Goblins — agente heurístico (v2)
-- Estrategia alineada con prompts/ghosts_n_goblins_agent.md:
-- avanzar siempre (→), disparar a distancia media, esquivar saltando,
-- salto preventivo, desatasco, escaleras y detección de pozos.
-- Prioridad: pozo > contacto cercano > disparo > escalera > avance.

local ROOT = "/Users/pablo/Documents/arcade-ai"
local AGENT = "heuristic"

local sys = manager.machine.ioport.ports[":SYSTEM"]
local p1 = manager.machine.ioport.ports[":P1"]
-- pcall wrap: el driver de gngb NO define :DSW1, y acceder a un port
-- inexistente rompe la carga del lua. Aprendi esto durante el smoke test
-- (CSV vacio porque el lua no se cargaba). Ahora dsw1 queda nil y
-- force_freeplay ya tiene pcall interno, asi que es seguro.
local dsw1 = nil
pcall(function() dsw1 = manager.machine.ioport.ports[":DSW1"] end)
local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]

-- spriteram (prompt § REFERENCIA TÉCNICA): 0x1e00–0x1fff, 4 bytes/sprite
-- [0]=code [1]=attr [2]=sy [3]=sx bajo
local SPRITE_BASE = 0x1e00
local SPRITE_LAST_OFFS = 0x1fc

-- ioport P1 (prompt): 01=derecha 02=izq 04=abajo 08=arriba 10=salto 20=lanzar
local P1_RIGHT = 0x01
local P1_LEFT  = 0x02
local P1_DOWN  = 0x04
local P1_UP    = 0x08
local P1_JUMP  = 0x10
local P1_FIRE  = 0x20

-- ioport SYSTEM (prompt boot: moneda 5 / start 1 → coin=0x40, start=0x01)
local SYS_START1 = 0x01
local SYS_COIN1  = 0x40

-- Umbrales del prompt (§ REFERENCIA TÉCNICA / ESTRATEGIA)
local GROUND_LO = 165
local GROUND_HI = 216
local SCAN_AHEAD = 90
local CLOSE_RANGE = 25          -- ESQUIVA: enemigo < ~25 px (prompt ref <22)
local FIRE_RANGE_LO = 25        -- LANZA: 25–70 px (prompt ref 22–72)
local FIRE_RANGE_HI = 70
local LANE_TOL = 26
local JUMP_HOLD = 22            -- mantener Ctrl ~20–25 frames (prompt § Saltar)
local FIRE_COOLDOWN = 12
local STUCK_LIMIT = 150         -- DESATASCA: >2 s sin mover X
local PREVENTIVE_JUMP_PERIOD = 75
local PIT_SCAN_LO = 10
local PIT_SCAN_HI = 48
local LADDER_Y_ABOVE = 18       -- ΔY por encima del suelo → subir escalera
local LADDER_Y_BELOW = 12

local frame = 0
-- En human_record mode saltamos el auto-boot (coin/start/run) para que
-- el humano controle el flujo completo. Sin esto, el boot_sequence
-- presiona SYS_COIN1/SYS_START1 en bucle y bloquea al humano.
local boot_done = (AGENT == "human_record")
local ingame_streak = 0
local dip_forced = false

-- CSV state para human_record (Fase 1 imitation learning)
local CSV_LOG = ROOT .. "/logs/gngb_human_dataset.csv"
local csv_handle = nil

local jump_cd = 0
local fire_cd = 0
local prev_player_x = nil
local prev_player_sy = nil
local stuck_frames = 0

local function press_sys(mask, on)
    local f = sys:field(mask)
    if f then f:set_value(on and 1 or 0) end
end

local function set_p1(right, left, up, down, jump, fire)
    local function bit(m, on)
        local f = p1:field(m)
        if f then f:set_value(on and 1 or 0) end
    end
    bit(P1_RIGHT, right)
    bit(P1_LEFT, left)
    bit(P1_UP, up)
    bit(P1_DOWN, down)
    bit(P1_JUMP, jump)
    bit(P1_FIRE, fire)
end

-- Free Play + coin/start periódicos (prompt § ARRANQUE)
local function force_freeplay()
    if dip_forced then return end
    dip_forced = true
    pcall(function()
        local f = dsw1.fields["Coinage"]
        if f then f:set_value(0x00) end
    end)
end

local function count_active_sprites()
    local n = 0
    for offs = 0, SPRITE_LAST_OFFS, 4 do
        local code = mem:read_u8(SPRITE_BASE + offs)
        if code ~= 0x00 and code ~= 0xff and code ~= 0xf8 then n = n + 1 end
    end
    return n
end

-- Empareja sprites apilados (32 px) para Arthur y enemigos terrestres.
local function read_actors()
    local raw = {}
    for offs = 0, SPRITE_LAST_OFFS, 4 do
        local base = SPRITE_BASE + offs
        local code = mem:read_u8(base)
        if code ~= 0x00 and code ~= 0xff and code ~= 0xf8 then
            local attr = mem:read_u8(base + 1)
            local sy = mem:read_u8(base + 2)
            local raw_sx = mem:read_u8(base + 3)
            local sx = raw_sx - 0x100 * (attr & 0x01)
            raw[#raw + 1] = {
                code = code, sx = sx, sy = sy,
                color = (attr >> 4) & 3,
                used = false,
            }
        end
    end

    local actors = {}
    for i = 1, #raw do
        local a = raw[i]
        if not a.used then
            local partner = nil
            for j = i + 1, #raw do
                local b = raw[j]
                if not b.used and math.abs(b.sx - a.sx) <= 3 and math.abs(b.sy - a.sy) == 16 then
                    partner = b
                    break
                end
            end
            if partner then
                a.used = true
                partner.used = true
                local top = (a.sy < partner.sy) and a or partner
                local bottom = (a.sy < partner.sy) and partner or a
                actors[#actors + 1] = {
                    sx = top.sx, sy = bottom.sy, color = top.color, tall = true,
                }
            else
                a.used = true
                actors[#actors + 1] = {
                    sx = a.sx, sy = a.sy, color = a.color, tall = false,
                }
            end
        end
    end
    return actors
end

local function find_player(actors)
    local best, best_score = nil, -9999
    for _, a in ipairs(actors) do
        if a.tall then
            local score = 0
            if a.sy >= GROUND_LO and a.sy <= GROUND_HI then score = score + 25 end
            if prev_player_x then
                if math.abs(a.sx - prev_player_x) < 40 then score = score + 40 end
            elseif a.sx >= 25 and a.sx <= 150 then
                score = score + 15
            end
            if a.color == 0 then score = score + 5 end
            if score > best_score then
                best_score = score
                best = a
            end
        end
    end
    return best
end

local function scan_enemy(player, actors)
    local best, best_dx = nil, 9999
    for _, a in ipairs(actors) do
        if a.tall and a ~= player then
            local dx = a.sx - player.sx
            local dy = math.abs(a.sy - player.sy)
            if dx > 2 and dx <= SCAN_AHEAD and dy <= LANE_TOL and dx < best_dx then
                best_dx = dx
                best = a
            end
        end
    end
    return best, best_dx
end

-- ¿Hay suelo/playable delante? (prompt § Pozos — salta antes del borde)
local function has_ground_ahead(player, actors)
    for _, a in ipairs(actors) do
        if a ~= player then
            local dx = a.sx - player.sx
            if dx >= PIT_SCAN_LO and dx <= PIT_SCAN_HI then
                if math.abs(a.sy - player.sy) <= LANE_TOL then
                    return true
                end
            end
        end
    end
    return false
end

local function pit_imminent(player, actors)
    if not player then return false end
    if jump_cd > 0 then return false end
    -- Sin sprites en nuestro carril delante → posible hueco al scroll
    if not has_ground_ahead(player, actors) then
        -- Más agresivo cerca del borde derecho donde aparecen pozos (prompt § CÓMO LEER)
        if player.sx >= 130 then return true end
        -- También si avanzamos sin enemigos visibles en terreno desconocido
        if player.sx >= 90 and frame % PREVENTIVE_JUMP_PERIOD < 8 then return true end
    end
    return false
end

-- Escalera: cambio de altura necesario (prompt § Escaleras)
local function scan_ladder(player, actors)
    if not player then return nil end

    if player.sy < GROUND_LO - LADDER_Y_ABOVE then
        return "up"
    end
    if player.sy > GROUND_HI - LADDER_Y_BELOW then
        return "down"
    end

    for _, a in ipairs(actors) do
        if a.tall and a ~= player then
            local dx = a.sx - player.sx
            if dx > 4 and dx < 55 then
                local dy = a.sy - player.sy
                if dy < -LADDER_Y_ABOVE then return "up" end
                if dy > LADDER_Y_BELOW then return "down" end
            end
        end
    end
    return nil
end

local function request_jump()
    if jump_cd <= 0 then
        jump_cd = JUMP_HOLD
        return true
    end
    return false
end

local function boot_sequence()
    if frame == 5 then force_freeplay() end

    -- Coin (5) + Start (1) cada ~2,5 s mientras no hay partida (prompt § ARRANQUE)
    if not boot_done and frame < 3600 then
        local m = frame % 150
        if m == 20 then press_sys(SYS_COIN1, true)
        elseif m == 35 then press_sys(SYS_COIN1, false)
        elseif m == 50 then press_sys(SYS_START1, true)
        elseif m == 65 then press_sys(SYS_START1, false)
        end
    end

    if count_active_sprites() >= 8 then
        ingame_streak = ingame_streak + 1
    else
        ingame_streak = 0
    end
    if ingame_streak > 25 or frame >= 3600 then
        boot_done = true
    end
end

local function act_heuristic()
    local actors = read_actors()
    local player = find_player(actors)

    -- Siempre avanzar salvo escalera (prompt § Regla de oro)
    local right, left, up, down = true, false, false, false
    local jump = jump_cd > 0
    local fire = false
    local mode = "AVANZA"

    if player then
        local enemy, dx = scan_enemy(player, actors)
        local ladder = scan_ladder(player, actors)

        -- Prioridad 1: pozo / caída inminente (prompt § ESTRATEGIA CON AMENAZAS)
        if pit_imminent(player, actors) and request_jump() then
            jump = true
            mode = "SALTO"
        end

        -- Prioridad 2: enemigo muy cerca → esquivar, no disparar
        if mode == "AVANZA" and enemy and dx < CLOSE_RANGE then
            if request_jump() then
                jump = true
                mode = "ESQUIVA"
            end
        end

        -- Prioridad 3: enemigo a distancia media → disparar manteniendo →
        if mode == "AVANZA" and enemy and dx >= FIRE_RANGE_LO and dx <= FIRE_RANGE_HI then
            if fire_cd <= 0 then
                fire = true
                fire_cd = FIRE_COOLDOWN
                mode = "LANZA"
            end
        end

        -- Prioridad 4: escalera
        if mode == "AVANZA" and ladder then
            if ladder == "up" then
                up = true
                mode = "ESCALERA"
            elseif ladder == "down" then
                down = true
                mode = "ESCALERA"
            end
        end

        -- Prioridad 5: salto preventivo (~1 s) en terreno desconocido
        if mode == "AVANZA" and not jump and frame % PREVENTIVE_JUMP_PERIOD == 0 then
            if request_jump() then
                jump = true
                mode = "SALTO"
            end
        end

        -- DESATASCA: sin movimiento X > ~2 s (prompt § Desatasco)
        if prev_player_x and math.abs(player.sx - prev_player_x) < 1 and not jump then
            stuck_frames = stuck_frames + 1
        else
            stuck_frames = 0
        end
        if stuck_frames > STUCK_LIMIT and mode == "AVANZA" then
            if request_jump() then
                jump = true
                mode = "DESATASCA"
            end
        end

        prev_player_x = player.sx
        prev_player_sy = player.sy
    else
        stuck_frames = 0
    end

    if jump_cd > 0 then jump_cd = jump_cd - 1 end
    if fire_cd > 0 then fire_cd = fire_cd - 1 end

    set_p1(right, left, up, down, jump, fire)
    return mode
end

local function act_random()
    local r = frame % 53
    set_p1(r > 6, false, false, false, r == 20 or r == 21, r == 35)
end

local last_mode = "AVANZA"

local function p1_field(mask, name)
    local f = p1:field(mask)
    if not f and p1.fields and name then f = p1.fields[name] end
    return f
end

local function init_csv_log()
    if csv_handle then return end
    pcall(function() os.execute("mkdir -p " .. ROOT .. "/logs") end)
    csv_handle = io.open(CSV_LOG, "a")
    if csv_handle then
        local fsize = csv_handle:seek("end")
        if fsize == 0 then
            csv_handle:write("frame,player_sx,player_sy,enemy_dx,enemy_dy,press_right,press_left,press_up,press_down,press_jump,press_fire\n")
            csv_handle:flush()
        end
    end
end

local function close_csv_log()
    if csv_handle then csv_handle:close(); csv_handle = nil end
end

-- G'n'G es active_high (v!=0=pressed). Distinto de Wonder Boy (active_low,
-- v==0=pressed). Por eso aquí retornamos 1 cuando v != 0, NO cuando v == 0.
-- Si inviertes la convencion, el CSV sale con 0 acciones aunque el humano
-- esté jugando (lección aprendida con Wonder Boy).
local function is_key_pressed(mask, name)
    local f = p1_field(mask, name)
    if not f or not f.live then return 0 end
    local v = tonumber(f.live.value) or 0
    return v ~= 0 and 1 or 0
end

-- Captura el estado del juego + inputs del humano por frame.
-- CSV: 5 features (frame, px, py, enemy_dx, enemy_dy) + 6 acciones.
-- El humano controla via teclado; la AI NO presiona nada (no se llama set_p1).
local function act_human_record()
    init_csv_log()
    if not csv_handle then return "REC-NOFILE" end

    local actors = read_actors()
    local player = find_player(actors)
    local p_sx = player and player.sx or 0
    local p_sy = player and player.sy or 0

    local enemy, enemy_dx = scan_enemy(player, actors)
    local e_dx = enemy and (enemy.sx - p_sx) or 999
    local e_dy = enemy and math.abs(enemy.sy - p_sy) or 0

    local pr = is_key_pressed(P1_RIGHT, "P1 Right")
    local pl = is_key_pressed(P1_LEFT, "P1 Left")
    local pu = is_key_pressed(P1_UP, "P1 Up")
    local pd = is_key_pressed(P1_DOWN, "P1 Down")
    local pj = is_key_pressed(P1_JUMP, "P1 Button 1")
    local pf = is_key_pressed(P1_FIRE, "P1 Button 2")

    csv_handle:write(string.format(
        "%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d\n",
        frame, p_sx, p_sy, e_dx, e_dy,
        pr, pl, pu, pd, pj, pf
    ))
    csv_handle:flush()
    return "REC"
end

local function draw_overlay()
    local screen = manager.machine.screens[":screen"]
    if not screen then return end
    local tag = boot_done and ("AI " .. last_mode) or "AI boot..."
    if AGENT == "human_record" then
        tag = boot_done and "REC+TEACH GNG" or "REC GNG (boot)"
    end
    screen:draw_text(4, 4, string.format("%s  f%d", tag, frame), 0xffffffff, 0xff000000)
end

emu.register_frame_done(function()
    frame = frame + 1
    if not boot_done then
        boot_sequence()
        draw_overlay()
        return
    end
    if AGENT == "human_record" then
        -- Modo "grabar humano": AI NO presiona teclas, solo observa.
        -- El humano controla via teclado (flechas + X jump + Z fire).
        last_mode = act_human_record() or "REC"
    elseif AGENT == "random" then
        act_random()
    else
        last_mode = act_heuristic() or "AVANZA"
    end
    draw_overlay()
end)

-- Cleanup del CSV al cerrar MAME. emu.register_stop existe solo en
-- MAME >= 0.229+ con bindings Lua nuevos; en 0.288 (vendor local) no está.
-- Como el CSV se flushea por frame con csv_handle:flush(), los datos
-- quedan en disco aunque MAME caiga de forma no limpia (kill, crash, etc).
if emu.register_stop then
    pcall(function() emu.register_stop(function() close_csv_log() end) end)
end
