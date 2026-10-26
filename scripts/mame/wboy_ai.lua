-- Wonder Boy — agente platformer (v28)
-- Combate: disparar SIEMPRE con hacha; saltar solo si falla tras ~55 frames.

local ROOT = "/Users/pablo/Documents/arcade-ai"
local AGENT = "heuristic"

local sys = manager.machine.ioport.ports[":SYSTEM"]
local p1 = manager.machine.ioport.ports[":P1"]
local input = manager.machine.input
local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]

local SPRITE_BASE = 0xd000
local WEAPON_RAM  = 0xc07f

local MASK_RIGHT = 0x40
local MASK_LEFT  = 0x80
local MASK_JUMP  = 0x02
local MASK_AXE   = 0x04
local SYS_COIN   = 0x01
local SYS_START  = 0x10

local PLAYER_CODES  = { [0x83] = true, [0x82] = true, [0x84] = true }
local ROCK_CODES    = { [0x7c] = true, [0x7b] = true, [0x7f] = true }
local FIRE_CODES    = { [0x69] = true, [0x67] = true, [0xd8] = true, [0x68] = true }
local WASP_CODES    = { [0x48] = true, [0x49] = true, [0x4a] = true, [0x4b] = true }
local EGG_CODES     = { [0x8d] = true, [0x8c] = true, [0x8e] = true }
local FRUIT_CODES   = { [0x87] = true, [0x8f] = true, [0x91] = true, [0x88] = true, [0x89] = true, [0x8a] = true, [0x8b] = true, [0x90] = true, [0x92] = true }
local WEAPON_CODES  = { [0x80] = true, [0x81] = true, [0x85] = true, [0x86] = true }
local SKATE_CODES   = { [0x85] = true }
local ANGEL_CODES   = { [0x86] = true }
local BAD_EGG_CODES = { [0x93] = true, [0x94] = true, [0x95] = true }
local PICKUP_CODES  = {
    [0x80] = true, [0x81] = true, [0x85] = true, [0x86] = true,
    [0x87] = true, [0x8f] = true, [0x91] = true,
    [0x88] = true, [0x89] = true, [0x8a] = true, [0x8b] = true,
    [0x90] = true, [0x92] = true, [0x8d] = true, [0x8c] = true, [0x8e] = true,
}

local SCAN_AHEAD    = 130
local GROUND_TOL    = 44
local JUMP_HOLD     = 22
local JUMP_COOLDOWN = 14
local COLLECT_DX    = 115
local LOOT_DX       = 100
local LOOT_AFTER_EGG = 200
local SNAIL_JUMP_DX = 44
local AXE_RANGE     = 92
local ENEMY_LANE_DY = 38
local AXE_MIN_DX    = 8
local AXE_TAP_ON    = 3
local AXE_TAP_OFF   = 6
local AXE_TAP_FAST_OFF = 3
-- Umbral de "stall" antes de autorizar jump de panico sobre enemigo.
-- 20 frames ~= 60 px de scroll a 3 px/frame, dejando ~32 px de margen
-- antes de colision tipica a AXE_RANGE=92 px. Suficiente para wind-up
-- del salto (crouch + launch) + apex. Antes era 55 (inalcanzable).
-- Bug HIGH #4.
local ATTACK_STALL_JUMP = 20
local ENEMY_JUMP_DX     = 48

local frame = 0
local boot_done = (AGENT == "human_record")
-- En human_record mode saltamos el auto-boot (COIN/START/run) para que
-- el humano controle el flujo completo. Sin esto, el boot_sequence
-- presiona KEYCODE_5/KEYCODE_1 y setea P1 right=true, y como apply_p1
-- no se llama en human_record, el personaje corre solo eternamente.
local jump_cd = 0
local jump_sustain = 0
local prev_player_x = nil
local prev_player_sy = nil
local airborne = 0
local has_weapon = false
local on_skateboard = false
local no_player_frames = 0
local run_after_boot = 0
local egg_loot_frames = 0
local breaking_egg = false
local axe_loot_visible = false
local last_axe_sx = nil
local axe_press_left = 0
local axe_cooldown = 0
local axe_throw_frames = 0
local attack_stall_frames = 0
local last_enemy_offs = nil

local io_state = { right = false, left = false, jump = false, axe = false }
local last_mode = "CORRE"
local last_player_x = nil
local last_right_live = 0
local last_axe_live = 0
local MODE_LOG = ROOT .. "/logs/wboy_ai_modes.log"
local PROGRESS_LOG = ROOT .. "/logs/wboy_progress.log"
local CSV_LOG = ROOT .. "/logs/wboy_human_dataset.csv"
local progress_start_x = nil
local csv_handle = nil

local last_logged_mode = ""

local function log_mode(mode)
    if mode == last_logged_mode then return end
    last_logged_mode = mode
    if not mode:find("COGE") and not mode:find("ROMPE") and not mode:find("TRAS")
        and not mode:find("SALTO") and not mode:find("ATACA") and not mode:find("BUSCA")
        and not mode:find("DISPARA") and not mode:find("CARACOL") and not mode:find("AVISPA") then
        return
    end
    os.execute("mkdir -p " .. ROOT .. "/logs")
    local f = io.open(MODE_LOG, "a")
    if f then
        f:write(string.format("f%d %s w=%s\n", frame, mode, has_weapon and "1" or "0"))
        f:close()
    end
end

local function read_score_bcd()
    -- Score BCD en 0xc304 (alto) : 0xc305 (bajo). Verificado por sonda de RAM
    -- (2026-10-26); la ventana 0xc040-0xc080 anterior era incorrecta.
    local function bcd(b) return math.floor(b / 16) * 10 + b % 16 end
    return bcd(mem:read_u8(0xc304)) * 100 + bcd(mem:read_u8(0xc305))
end

local function press_sys(mask, on)
    local f = sys:field(mask)
    if f then f:set_value(on and 1 or 0) end
end

local function press_key(seq, on)
    if not input or not input.seq_set_value or not seq then return end
    pcall(function() input:seq_set_value(seq, on and 1 or 0) end)
end

local function press_token(token, on)
    if not input or not input.seq_from_tokens then return end
    local ok, seq = pcall(function() return input:seq_from_tokens(token) end)
    if ok and seq then press_key(seq, on) end
end

local function p1_field(mask, name)
    local f = p1:field(mask)
    if not f and p1.fields and name then f = p1.fields[name] end
    return f
end

local function press_field(field, on, tokens)
    if field then
        if on then field:set_value(1) else field:clear_value() end
        local ok, seq = pcall(function() return field:input_seq("standard") end)
        if ok and seq then press_key(seq, on) end
    end
    if tokens then
        for _, tok in ipairs(tokens) do press_token(tok, on) end
    end
end

local function game_has_weapon()
    -- Lectura directa de RAM. game_has_weapon() solo se invoca desde
    -- act_heuristic() que solo corre tras boot_done (frame 180), por
    -- lo que WEAPON_RAM ya está inicializado. Antes habia un delay
    -- artificial de 400 frames (6.6s) que anulaba la lectura.
    return mem:read_u8(WEAPON_RAM) ~= 0
end

local function count_axe_sprites()
    local n = 0
    for offs = 0, 0x7f8, 8 do
        local c = mem:read_u8(SPRITE_BASE + offs)
        if c >= 0x70 and c <= 0x7e then n = n + 1 end
    end
    return n
end

local function axe_tap(want, urgent)
    if not want then
        axe_press_left = 0
        axe_cooldown = 0
        return false
    end
    -- Cap canonico: max 2 hachas en pantalla. Si ya hay 2, NO tirar la 3a
    -- (el juego despawnaria la 1a, anulando los proyectiles previos).
    -- Sin este cap, el AI "spameaba" el boton y los tiros se cancelaban
    -- entre si, dando la sensacion de "no dispara" (bug HIGH #2).
    if count_axe_sprites() >= 2 then
        return false
    end
    local off = urgent and AXE_TAP_FAST_OFF or AXE_TAP_OFF
    if axe_cooldown > 0 then
        axe_cooldown = axe_cooldown - 1
        return false
    end
    if axe_press_left > 0 then
        axe_press_left = axe_press_left - 1
        if axe_press_left == 0 then axe_cooldown = off end
        return true
    end
    axe_press_left = AXE_TAP_ON
    return true
end

local function log_progress(player, mode)
    if not boot_done or not player then return end
    if frame % 60 ~= 0 and not (mode and mode:find("ATACA")) then return end
    if not progress_start_x then progress_start_x = player.sx end
    os.execute("mkdir -p " .. ROOT .. "/logs")
    local pf = io.open(PROGRESS_LOG, "a")
    if pf then
        pf:write(string.format(
            "f%d x=%d mode=%s w=%d ram=%02x axe=%d proj=%d throws=%d\n",
            frame, player.sx, mode or last_mode, has_weapon and 1 or 0,
            mem:read_u8(WEAPON_RAM), last_axe_live, count_axe_sprites(), axe_throw_frames
        ))
        pf:close()
    end
end

local function press_digital(field, on)
    if not field then return end
    if on then field:set_value(1) else field:clear_value() end
end

local function apply_p1()
    press_field(p1_field(MASK_RIGHT, "P1 Right"), io_state.right, { "KEYCODE_RIGHT" })
    press_field(p1_field(MASK_LEFT, "P1 Left"), io_state.left, { "KEYCODE_LEFT" })
    -- Tokens unificados con cfg/wboy.cfg: X=jump, Z=axe.
    -- Antes: LALT/LCONTROL eran legacy (interceptados en macOS por char entry
    -- y Mission Control). Tras Fase 3 el cfg solo mapea X/Z, los tokens
    -- legacy son ruido (bug HIGH #3).
    press_field(p1_field(MASK_JUMP, "P1 Button 1"), io_state.jump, { "KEYCODE_X" })
    press_field(p1_field(MASK_AXE, "P1 Button 2"), io_state.axe,
        { "KEYCODE_Z" })

    local fr = p1_field(MASK_RIGHT, "P1 Right")
    local fa = p1_field(MASK_AXE, "P1 Button 2")
    if fr and fr.live then
        local v = tonumber(fr.live.value) or 0
        last_right_live = (io_state.right and v == 0) and 1 or v  -- ACTIVE_LOW
    end
    if fa and fa.live then
        local v = tonumber(fa.live.value) or 0
        last_axe_live = (io_state.axe and v == 0) and 1 or v
    end
end

local function set_p1(right, left, jump, want_axe, urgent_fire)
    io_state.right = right
    io_state.left = left
    io_state.jump = jump
    io_state.axe = axe_tap(want_axe, urgent_fire)
    if io_state.axe then axe_throw_frames = axe_throw_frames + 1 end
end

local function is_fire(code) return FIRE_CODES[code] == true end
local function is_rock(code) return ROCK_CODES[code] == true end
local function is_wasp(code) return WASP_CODES[code] == true end
local function is_fruit(code) return FRUIT_CODES[code] == true end
local function is_pickup_code(code) return PICKUP_CODES[code] or EGG_CODES[code] end

local function is_enemy_code(code)
    if is_fire(code) or is_rock(code) or is_pickup_code(code) then return false end
    if is_wasp(code) then return true end
    if code >= 0x40 and code <= 0x6f then return true end
    return false
end

local function classify(code)
    if BAD_EGG_CODES[code] then return "bad_egg" end
    if EGG_CODES[code] then return "egg" end
    if is_fruit(code) then return "fruit" end
    if is_rock(code) then return "rock" end
    if is_fire(code) then return "fire" end
    if is_wasp(code) then return "wasp" end
    if SKATE_CODES[code] then return "skate_item" end
    if ANGEL_CODES[code] then return "angel_item" end
    if WEAPON_CODES[code] then return "weapon_item" end
    if is_enemy_code(code) then return "enemy" end
    if PICKUP_CODES[code] then return "pickup" end
    if code >= 0x80 and code <= 0x96 then return "pickup" end
    return "other"
end

local function read_sprites()
    local sprites = {}
    for offs = 0, 0x7f8, 8 do
        local base = SPRITE_BASE + offs
        local code = mem:read_u8(base)
        if code ~= 0 then
            local raw_y = mem:read_u8(base + 1)
            local raw_x = mem:read_u8(base + 2)
            sprites[#sprites + 1] = {
                offs = offs,
                code = code,
                kind = classify(code),
                sx = raw_x - 128,
                sy = 256 - raw_y,
            }
        end
    end
    return sprites
end

local function find_player(sprites)
    local best, best_score = nil, -9999
    for _, s in ipairs(sprites) do
        local score = 0
        if PLAYER_CODES[s.code] then score = score + 60 end
        if s.sy >= 75 and s.sy <= 205 then score = score + 20 end
        if prev_player_x and math.abs(s.sx - prev_player_x) < 45 then score = score + 18 end
        if score > best_score then
            best_score = score
            best = s
        end
    end
    return best
end

local function on_ground(player)
    if not player or not prev_player_sy then return true end
    if airborne > 0 or jump_sustain > 0 then return false end
    return math.abs(player.sy - prev_player_sy) < 4
end

local function ahead_dx(player, s)
    return s.sx - player.sx
end

local function same_lane(player, s)
    return math.abs(s.sy - player.sy) <= GROUND_TOL
end

local function is_ground_level(player, s)
    return math.abs(s.sy - player.sy) <= 30
end

local function is_ground_enemy(player, s)
    return math.abs(s.sy - player.sy) <= 58
end

local function is_low_aerial_threat(player, s)
    local dy = s.sy - player.sy
    return dy >= -22 and dy <= 18
end

local function is_aerial_enemy(player, s)
    return s.sy < player.sy - 8 or is_low_aerial_threat(player, s)
end

local function is_likely_enemy_sprite(s)
    if s.kind == "fruit" or s.kind == "egg" or s.kind == "pickup"
        or s.kind == "weapon_item" or s.kind == "skate_item" or s.kind == "angel_item"
        or s.kind == "bad_egg" or s.kind == "rock" or s.kind == "fire" then
        return false
    end
    if s.kind == "enemy" or s.kind == "wasp" then return true end
    if PLAYER_CODES[s.code] or is_pickup_code(s.code) then return false end
    if s.code >= 0x40 and s.code <= 0x7a and not is_fire(s.code) and not is_rock(s.code) then return true end
    return false
end

local function is_loot_kind(kind)
    return kind == "fruit" or kind == "weapon_item" or kind == "pickup"
        or kind == "skate_item" or kind == "angel_item"
end

local function scan_loot_ahead(player, sprites)
    local best = nil
    for _, s in ipairs(sprites) do
        if s.offs == player.offs or PLAYER_CODES[s.code] or s.kind == "egg" then goto continue end
        if not is_loot_kind(s.kind) then goto continue end
        local dx = ahead_dx(player, s)
        if dx < -12 or dx > LOOT_DX then goto continue end
        if math.abs(s.sy - player.sy) > 58 then goto continue end
        if not best or dx < ahead_dx(player, best) then best = s end
        ::continue::
    end
    return best
end

local function loot_blocks_jump(loot, loot_dx)
    if not loot or loot_dx < -5 or loot_dx > 42 then return false end
    if loot.kind == "weapon_item" then return true end
    if loot.kind == "skate_item" or loot.kind == "angel_item" or loot.kind == "pickup" then
        return true
    end
    return false
end

local function jump_window(kind, dx)
    if kind == "fire" then return dx >= 28 and dx <= 68 end
    if kind == "rock" then return dx >= 20 and dx <= 58 end
    if kind == "enemy" or kind == "wasp" or kind == "snail" then
        return dx >= 10 and dx <= SNAIL_JUMP_DX + 12
    end
    return false
end

local function scan_snail_ahead(player, sprites)
    for _, s in ipairs(sprites) do
        if PLAYER_CODES[s.code] then goto cont end
        local dx = ahead_dx(player, s)
        if dx <= 0 or dx > AXE_RANGE then goto cont end
        if s.code == 0x66 or (s.kind == "enemy" and is_ground_enemy(player, s)) then
            return s, dx
        end
        ::cont::
    end
    return nil, 999
end

local function scan_ahead(player, sprites)
    local rock, fire, enemy, fruit, egg, bad_egg, power = nil, nil, nil, nil, nil, nil, nil

    for _, s in ipairs(sprites) do
        if s.offs == player.offs or PLAYER_CODES[s.code] then goto continue end
        local dx = ahead_dx(player, s)
        if dx < -10 or dx > SCAN_AHEAD then goto continue end

        if is_likely_enemy_sprite(s) and dx > 0 and math.abs(s.sy - player.sy) <= 65 then
            if not enemy or dx < ahead_dx(player, enemy) then enemy = s end
        end

        if s.kind == "bad_egg" and same_lane(player, s) then
            if not bad_egg or dx < ahead_dx(player, bad_egg) then bad_egg = s end
        elseif s.kind == "egg" and math.abs(s.sy - player.sy) <= 55 then
            if not egg or dx < ahead_dx(player, egg) then egg = s end
        elseif s.kind == "fruit" and is_ground_level(player, s) then
            if not fruit or dx < ahead_dx(player, fruit) then fruit = s end
        elseif s.kind == "pickup" and is_ground_level(player, s) then
            if not fruit or dx < ahead_dx(player, fruit) then fruit = s end
        elseif s.kind == "rock" and same_lane(player, s) then
            if not rock or dx < ahead_dx(player, rock) then rock = s end
        elseif s.kind == "fire" and s.sy >= player.sy - 28 then
            if not fire or dx < ahead_dx(player, fire) then fire = s end
        elseif s.kind == "skate_item" or s.kind == "angel_item" or s.kind == "weapon_item" then
            if not power or dx < ahead_dx(player, power) then power = s end
        end
        ::continue::
    end
    return rock, fire, enemy, fruit, egg, bad_egg, power
end

local function start_jump(mode)
    jump_sustain = JUMP_HOLD
    jump_cd = JUMP_HOLD + JUMP_COOLDOWN
    airborne = JUMP_HOLD
    return mode
end

local function pulse_title()
    press_sys(SYS_COIN, true)
    press_sys(SYS_START, true)
end

local function release_title()
    press_sys(SYS_COIN, false)
    press_sys(SYS_START, false)
end

local function boot_sequence()
    if frame == 30 then
        press_sys(SYS_COIN, true)
        press_key("KEYCODE_5", true)
    elseif frame == 38 then
        press_sys(SYS_COIN, false)
        press_key("KEYCODE_5", false)
    elseif frame == 70 then
        press_sys(SYS_START, true)
        press_key("KEYCODE_1", true)
    elseif frame == 82 then
        press_sys(SYS_START, false)
        press_key("KEYCODE_1", false)
    elseif frame == 120 then
        press_sys(SYS_START, true)
        press_key("KEYCODE_1", true)
    elseif frame == 132 then
        press_sys(SYS_START, false)
        press_key("KEYCODE_1", false)
    elseif frame >= 150 then set_p1(true, false, false, false, false) end
    if frame == 180 then boot_done = true; run_after_boot = 0 end
end

local function enemy_in_axe_range(player, enemy, enemy_dx)
    if not enemy or enemy_dx <= 0 or enemy_dx > AXE_RANGE then return false end
    if is_ground_enemy(player, enemy) then return enemy_dx >= 4 end
    return enemy_dx >= AXE_MIN_DX and math.abs(enemy.sy - player.sy) <= ENEMY_LANE_DY
end

local function should_jump_over_enemy(has_weapon, ground_snail, aerial_foe, enemy_dx, stall)
    if has_weapon then
        return stall >= ATTACK_STALL_JUMP
    end
    if ground_snail then
        return jump_window("snail", enemy_dx) or jump_window("enemy", enemy_dx)
    end
    if aerial_foe then
        return jump_window("wasp", enemy_dx) or jump_window("enemy", enemy_dx)
    end
    return false
end

local function cancel_jumps()
    jump_sustain = 0
    airborne = 0
end

local function act_heuristic()
    local sprites = read_sprites()
    local player = find_player(sprites)

    local right, left, jump = true, false, false
    local want_axe = false
    local mode = "CORRE"
    local want_collect = false

    if not player then
        no_player_frames = no_player_frames + 1
        if no_player_frames % 45 == 0 then pulse_title() end
        if no_player_frames % 50 == 0 then release_title() end
        set_p1(true, false, false, false, false)
        return no_player_frames > 120 and "REBOOT" or "TITULO"
    end
    no_player_frames = 0
    release_title()

    on_skateboard = (player.code == 0x84)
    run_after_boot = run_after_boot + 1

    -- Tras boot: mantener → para pasar cartel START (como en el vídeo)
    if run_after_boot < 360 then
        right = true
        mode = "ARRANQUE"
    end

    if prev_player_sy and math.abs(player.sy - prev_player_sy) > 6 and jump_sustain == 0 then
        airborne = JUMP_HOLD
    end
    if airborne > 0 and jump_sustain == 0 then airborne = airborne - 1 end

    local rock, fire, enemy, fruit, egg, bad_egg, power = scan_ahead(player, sprites)
    local snail, snail_dx = scan_snail_ahead(player, sprites)
    if snail then
        local other_dx = enemy and ahead_dx(player, enemy) or 999
        if not enemy or snail_dx < other_dx then
            enemy = snail
        end
    end
    local enemy_dx = enemy and ahead_dx(player, enemy) or 999
    local enemy_near = enemy and enemy_dx > 0 and enemy_dx <= SCAN_AHEAD
    local ground_snail = enemy_near and is_ground_enemy(player, enemy)
    local aerial_foe = enemy_near and is_aerial_enemy(player, enemy)
    local enemy_urgent = enemy_near and enemy_dx < 30
    local enemy_lane = enemy_in_axe_range(player, enemy, enemy_dx)

    local egg_dx = egg and ahead_dx(player, egg) or 999
    local fruit_dx = fruit and ahead_dx(player, fruit) or 999
    local fruit_dy = fruit and (player.sy - fruit.sy) or 0
    local fruit_ground = fruit and is_ground_level(player, fruit)
    local egg_ground = egg and is_ground_level(player, egg)

    local loot = scan_loot_ahead(player, sprites)
    local loot_dx = loot and ahead_dx(player, loot) or 999
    local loot_ground = loot and is_ground_level(player, loot)

    -- Huevo roto → ventana de recogida (hacha, fruta, patín, vida)
    if egg_ground and egg_dx <= 50 then breaking_egg = true end
    if breaking_egg and not egg then
        egg_loot_frames = LOOT_AFTER_EGG
        breaking_egg = false
    end
    if egg_loot_frames > 0 then egg_loot_frames = egg_loot_frames - 1 end

    has_weapon = game_has_weapon()

    if enemy and enemy_near and (ground_snail or aerial_foe) then
        if last_enemy_offs == enemy.offs then
            attack_stall_frames = attack_stall_frames + 1
        else
            attack_stall_frames = 0
            last_enemy_offs = enemy.offs
        end
    else
        attack_stall_frames = 0
        last_enemy_offs = nil
    end

    local see_axe_loot = false
    local axe_sx = nil
    for _, s in ipairs(sprites) do
        if s.kind == "weapon_item" and s.offs ~= player.offs then
            see_axe_loot = true
            axe_sx = s.sx
            break
        end
    end
    if see_axe_loot then
        axe_loot_visible = true
        last_axe_sx = axe_sx
    end

    local egg_visible = egg and egg_dx <= COLLECT_DX and egg_dx >= -15
    local egg_phase = egg_visible or egg_loot_frames > 0 or breaking_egg
        or see_axe_loot or axe_loot_visible
        or (loot and loot.kind == "weapon_item" and loot_dx <= LOOT_DX and not has_weapon)

    local collect_priority = egg_loot_frames > 0 or egg_phase
    if loot and loot_dx <= LOOT_DX and loot_dx >= -12 and not egg_phase then
        if loot.kind == "weapon_item" or loot.kind == "skate_item"
            or loot.kind == "angel_item" or loot.kind == "pickup" then
            collect_priority = true
        elseif loot_ground and loot.kind == "fruit" then
            collect_priority = true
        end
    end
    local axe_on_ground = (see_axe_loot or axe_loot_visible) and not has_weapon

    if axe_on_ground then
        collect_priority = true
    elseif has_weapon and enemy_near and enemy_dx <= AXE_RANGE then
        collect_priority = false
        egg_loot_frames = 0
    end

    local combat = enemy_near and (ground_snail or aerial_foe)
        and enemy_dx > 0 and enemy_dx <= AXE_RANGE

    if combat and has_weapon then
        collect_priority = false
        egg_loot_frames = 0
    end

    local real_danger = fire or rock or bad_egg

    local block_jumps = (egg_phase or collect_priority or axe_on_ground
        or egg_visible or (egg and egg_dx <= 90)) and not (combat and has_weapon)

    local enemy_blocks = enemy_near and (ground_snail or aerial_foe)
        and enemy_dx <= ENEMY_JUMP_DX
    local jump_enemy = false
    if enemy_blocks then
        local want_jump = should_jump_over_enemy(
            has_weapon, ground_snail, aerial_foe, enemy_dx, attack_stall_frames)
        -- Safety: si hay un caracol/avispa en jump window, saltar SIEMPRE,
        -- aunque block_jumps esté activo (TRAS-HUEVO, COGE-LOOT, etc.).
        -- Antes el AI se estampaba contra el caracol durante la fase de
        -- recolección porque el jump solo se autorizaba en dx<=24 (muy tarde).
        if want_jump then
            jump_enemy = true
            if block_jumps then block_jumps = false end
        end
    end

    if block_jumps and not jump_enemy then cancel_jumps() end

    if jump_sustain > 0 and not block_jumps then
        jump_sustain = jump_sustain - 1
        right = true
        jump = true
    elseif block_jumps then
        cancel_jumps()
        jump = false
    end

    local grounded = on_ground(player)
    if on_skateboard then
        mode = "PATINETE"
        right = true
        want_axe = enemy_lane or has_weapon
        if jump_sustain == 0 and grounded and jump_cd <= 0 then
            if fire then
                local dx = ahead_dx(player, fire)
                if jump_window("fire", dx) then mode = start_jump("SKATE-FUEGO") end
            elseif rock then
                local dx = ahead_dx(player, rock)
                if jump_window("rock", dx) then mode = start_jump("SKATE-ROCA") end
            elseif bad_egg then
                local dx = ahead_dx(player, bad_egg)
                if dx >= 12 and dx <= 58 then mode = start_jump("SKATE-MALO") end
            end
        end
        if enemy_lane then want_axe = true end
        -- Sección nubes/agua (~1:05 vídeo): saltos entre plataformas sin frenar
        if jump_sustain == 0 and grounded and jump_cd <= 0
            and not fire and not rock and not bad_egg and not enemy_urgent
            and player.sy >= 130 then
            if frame % 65 < 4 then mode = start_jump("SKATE-NUBE") end
        end
        prev_player_x = player.sx
        prev_player_sy = player.sy
        last_player_x = player.sx
        if has_weapon then want_axe = true end
        set_p1(right, left, jump or jump_sustain > 0, want_axe, enemy_lane)
        return mode
    end

    -- 1) Saltos: peligro (fuego/roca) o enemigo si disparo falla / sin hacha
    if not block_jumps and jump_sustain == 0 and grounded and jump_cd <= 0 and not jump then
        if fire then
            local dx = ahead_dx(player, fire)
            if jump_window("fire", dx) then mode = start_jump("SALTO-FUEGO") end
        elseif rock then
            local dx = ahead_dx(player, rock)
            if jump_window("rock", dx) then mode = start_jump("SALTO-ROCA") end
        elseif bad_egg then
            local dx = ahead_dx(player, bad_egg)
            if dx >= 12 and dx <= 58 then mode = start_jump("SALTO-MALO") end
        elseif jump_enemy then
            mode = start_jump(ground_snail and "SALTO-CARACOL" or "SALTO-AVISPA")
            attack_stall_frames = 0
        end
    elseif not block_jumps and jump_enemy and jump_sustain == 0
        and grounded and jump_cd <= 0 and not jump then
        mode = start_jump(ground_snail and "SALTO-CARACOL" or "SALTO-AVISPA")
        attack_stall_frames = 0
    elseif not block_jumps and collect_priority and real_danger and jump_sustain == 0
        and grounded and jump_cd <= 0 and not loot_blocks_jump(loot, loot_dx) then
        if fire then
            local dx = ahead_dx(player, fire)
            if jump_window("fire", dx) then mode = start_jump("SALTO-FUEGO") end
        elseif rock then
            local dx = ahead_dx(player, rock)
            if jump_window("rock", dx) then mode = start_jump("SALTO-ROCA") end
        elseif bad_egg then
            local dx = ahead_dx(player, bad_egg)
            if dx >= 12 and dx <= 58 then mode = start_jump("SALTO-MALO") end
        end
    end

    -- 2) Huevo: romper/coger CORRIENDO — nunca saltar
    local want_egg = egg_visible and not enemy_urgent
    if want_egg then
        cancel_jumps()
        jump = false
        right = true
        mode = egg_dx <= 40 and "ROMPE-HUEVO" or "BUSCA-HUEVO"
        want_collect = true
        collect_priority = true
        block_jumps = true
    end

    -- 3) Tras huevo o botín cerca: avanzar sin saltar (salvo si hay enemigo)
    if collect_priority and not real_danger
        and not (has_weapon and enemy_near)
        and not (ground_snail and enemy_dx <= AXE_RANGE) then
        cancel_jumps()
        jump = false
        right = true
        want_collect = true
        block_jumps = true
        if loot then
            if loot.kind == "weapon_item" then mode = "COGE-HACHA"
            elseif loot.kind == "fruit" then mode = "COGE-FRUTA"
            elseif loot.kind == "skate_item" then mode = "COGE-PATIN"
            elseif loot.kind == "angel_item" then mode = "COGE-VIDA"
            else mode = "COGE-LOOT"
            end
        elseif egg_loot_frames > 0 then
            mode = "TRAS-HUEVO"
        end
    end

    -- 4) Fruta en suelo (fuera de fase huevo)
    local want_fruit_ground = not collect_priority and fruit_ground
        and fruit_dx <= COLLECT_DX and fruit_dx >= -8 and not enemy_urgent
    if not want_egg and want_fruit_ground then
        cancel_jumps()
        jump = false
        right = true
        mode = "COGE-FRUTA"
        want_collect = true
    end

    -- 5) Combate: con hacha → disparar siempre; sin hacha → saltar caracol/avispa
    local try_shoot = false
    if combat and not jump_enemy then
        if has_weapon and attack_stall_frames < ATTACK_STALL_JUMP then
            try_shoot = true
            want_axe = true
            if ground_snail then mode = "ATACA-CARACOL"
            elseif aerial_foe then mode = "ATACA-AVISPA"
            else mode = "ATACA"
            end
        elseif not has_weapon and ground_snail and enemy_dx <= ENEMY_JUMP_DX
            and not block_jumps and jump_sustain == 0 and grounded and jump_cd <= 0 then
            mode = start_jump("SALTO-CARACOL")
            attack_stall_frames = 0
        elseif not has_weapon and aerial_foe and enemy_dx <= ENEMY_JUMP_DX
            and not block_jumps and jump_sustain == 0 and grounded and jump_cd <= 0 then
            mode = start_jump("SALTO-AVISPA")
            attack_stall_frames = 0
        end
    end

    -- 6) Solo fruta en el aire (nunca durante huevo/hacha)
    if not block_jumps and not want_collect and fruit and fruit.kind == "fruit"
        and not fruit_ground and not egg_ground and not axe_on_ground
        and jump_sustain == 0 and grounded and jump_cd <= 0 and not jump then
        local dx = ahead_dx(player, fruit)
        local dy = player.sy - fruit.sy
        if dx >= 18 and dx <= 52 and dy >= 8 and dy <= 38 then
            mode = start_jump("SALTO-FRUTA")
        end
    end

    -- Sin arma: ir al huevo
    if not has_weapon and egg and egg_dx <= 90 then
        cancel_jumps()
        jump = false
        block_jumps = true
        right = true
        mode = egg_dx <= 40 and "ROMPE-HUEVO" or "BUSCA-HUEVO"
    end

    if jump_sustain > 0 and not block_jumps then
        right = true
        jump = true
        if enemy_lane and has_weapon then want_axe = true end
    elseif block_jumps then
        cancel_jumps()
        jump = false
    end

    if jump and jump_sustain == 0 and not want_collect then
        jump_cd = JUMP_HOLD + JUMP_COOLDOWN
        airborne = JUMP_HOLD
    end

    if jump_cd > 0 and jump_sustain == 0 and not jump then jump_cd = jump_cd - 1 end

    prev_player_x = player.sx
    prev_player_sy = player.sy
    last_player_x = player.sx

    -- PRIORIDAD FINAL: caracol/avispa — disparar con hacha; sin hacha → saltar
    local urgent_fire = false
    if combat then
        right = true
        block_jumps = false
        if has_weapon and attack_stall_frames < ATTACK_STALL_JUMP then
            cancel_jumps()
            jump = false
            want_axe = true
            urgent_fire = true
            mode = ground_snail and "ATACA-CARACOL"
                or (aerial_foe and "ATACA-AVISPA" or "ATACA")
        elseif has_weapon and attack_stall_frames >= ATTACK_STALL_JUMP then
            want_axe = false
            if jump_sustain == 0 and grounded and jump_cd <= 0 then
                mode = start_jump(ground_snail and "SALTO-CARACOL" or "SALTO-AVISPA")
                jump = true
            end
        elseif not has_weapon and enemy_dx <= ENEMY_JUMP_DX then
            want_axe = false
            if jump_sustain == 0 and grounded and jump_cd <= 0 then
                mode = start_jump(ground_snail and "SALTO-CARACOL" or "SALTO-AVISPA")
                jump = true
            end
        end
    elseif jump_enemy then
        want_axe = false
    elseif has_weapon and not block_jumps then
        want_axe = true
        urgent_fire = enemy_lane
        if mode == "CORRE" then mode = "DISPARA" end
    else
        want_axe = false
    end

    set_p1(right, left,
        jump and not block_jumps,
        want_axe, urgent_fire)
    log_mode(mode)
    return mode
end

local function init_csv_log()
    if csv_handle then return end
    os.execute("mkdir -p " .. ROOT .. "/logs")
    csv_handle = io.open(CSV_LOG, "a")
    if csv_handle then
        local fsize = csv_handle:seek("end")
        if fsize == 0 then
            csv_handle:write("frame,player_sx,player_sy,has_weapon,on_skateboard,snail_dx,snail_dy,fire_dx,fire_dy,rock_dx,rock_dy,fruit_dx,fruit_dy,egg_dx,egg_dy,axe_pickup_dx,axe_pickup_dy,press_right,press_left,press_jump,press_axe\n")
            csv_handle:flush()
        end
    end
end

local function close_csv_log()
    if csv_handle then csv_handle:close(); csv_handle = nil end
end

-- Lee el P1 field directamente desde ioport. Wonder Boy usa convencion
-- active_low en sus ports: v==0 = pressed, v!=0 = released. La version
-- anterior usaba input:seq_get_value(seq) que parecia retornar siempre 0
-- (probablemente porque la seq hereda el active_low del cfg via el port).
-- Leyendo p1:field(MASK).live.value con tonumber() capturamos el estado
-- real respetando el active_low.
local function is_key_pressed(mask, name)
    local f = p1_field(mask, name)
    if not f or not f.live then return 0 end
    local v = tonumber(f.live.value) or 0
    return v == 0 and 1 or 0
end

local function act_human_record()
    init_csv_log()
    if not csv_handle then return "REC-NOFILE" end

    local sprites = read_sprites()
    local player = find_player(sprites)
    local p_sx = player and player.sx or 0
    local p_sy = player and player.sy or 0
    local has_weap = game_has_weapon() and 1 or 0
    local on_skate = (player and player.code == 0x84) and 1 or 0

    local rock, fire, enemy, fruit, egg, bad_egg, power = scan_ahead(player, sprites)
    local function dxdy_of(s, base_sy)
        if not s then return -999, 0 end
        return ahead_dx(base_sy and {sy = base_sy} or player, s),
               (p_sy - s.sy)
    end
    local snail_dx, snail_dy = -999, 0
    if enemy then snail_dx, snail_dy = ahead_dx(player, enemy), (p_sy - enemy.sy) end
    local fire_dx, fire_dy = -999, 0
    if fire then fire_dx, fire_dy = ahead_dx(player, fire), (p_sy - fire.sy) end
    local rock_dx, rock_dy = -999, 0
    if rock then rock_dx, rock_dy = ahead_dx(player, rock), (p_sy - rock.sy) end
    local fruit_dx, fruit_dy = -999, 0
    if fruit then fruit_dx, fruit_dy = ahead_dx(player, fruit), (p_sy - fruit.sy) end
    local egg_dx, egg_dy = -999, 0
    if egg then egg_dx, egg_dy = ahead_dx(player, egg), (p_sy - egg.sy) end
    local axe_dx, axe_dy = -999, 0
    if power then axe_dx, axe_dy = ahead_dx(player, power), (p_sy - power.sy) end

    -- Captura de inputs del humano via P1 fields (active_low: v==0 = pressed).
    -- Sin inyeccion: el humano maneja el teclado; nosotros solo observamos.
    local pr = is_key_pressed(MASK_RIGHT, "P1 Right")
    local pl = is_key_pressed(MASK_LEFT, "P1 Left")
    local pj = is_key_pressed(MASK_JUMP, "P1 Button 1")
    local pa = is_key_pressed(MASK_AXE, "P1 Button 2")

    csv_handle:write(string.format(
        "%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d\n",
        frame, p_sx, p_sy, has_weap, on_skate,
        snail_dx, snail_dy, fire_dx, fire_dy, rock_dx, rock_dy,
        fruit_dx, fruit_dy, egg_dx, egg_dy, axe_dx, axe_dy,
        pr, pl, pj, pa
    ))
    csv_handle:flush()
    return "REC"
end

local function draw_overlay()
    local screen = manager.machine.screens[":screen"]
    if not screen then return end
    local w = has_weapon and "W" or "-"
    local sk = on_skateboard and "S" or ""
    local ax = io_state.axe and "A" or "-"
    local io_ok = p1_field(MASK_RIGHT, "P1 Right") and "IO" or "!!"
    local tag = boot_done and string.format(
        "AI v28 %s R%d A%d [%s%s%s|%s]", last_mode, last_right_live, last_axe_live, w, sk, ax, io_ok
    ) or "boot..."
    screen:draw_text(4, 4, string.format("%s f%d", tag, frame), 0xffffffff, 0xff000000)
end

-- Aplicar inputs al INICIO de cada frame (antes de que MAME lea el puerto).
-- En human_record mode NO aplicamos inputs AI: el humano maneja el teclado directamente.
emu.add_machine_frame_notifier(function()
    if AGENT ~= "human_record" then apply_p1() end
end)

-- Cleanup del CSV al cerrar MAME. emu.register_stop existe solo en
-- MAME >= 0.229+ con bindings Lua nuevos; en 0.288 (vendor local) no esta.
-- Como el CSV se flushea por frame con csv_handle:flush(), los datos
-- quedan en disco aunque MAME caiga de forma no limpia (kill, crash, etc).
-- Wrap en pcall para portabilidad cross-version.
if emu.register_stop then
    pcall(function() emu.register_stop(function() close_csv_log() end) end)
end

emu.register_frame_done(function()
    frame = frame + 1
    if not boot_done then
        boot_sequence()
        apply_p1()
        draw_overlay()
        return
    end
    if AGENT == "human_record" then
        -- Modo "grabar humano": AI NO presiona teclas, solo observa.
        -- El humano controla el personaje via teclado (X/Z/arrows via cfg/wboy.cfg).
        -- Capturamos (game_state, action) por frame a logs/wboy_human_dataset.csv
        -- para entrenar classifier despues (Fase 2 imitation learning).
        last_mode = act_human_record() or "REC"
        draw_overlay()
        return
    end
    if AGENT == "random" then
        local r = frame % 47
        set_p1(r > 5, r < 3, r == 10 or r == 11, r == 20 or r == 21, false)
    else
        last_mode = act_heuristic() or "CORRE"
        if AGENT == "heuristic" then
            local sprites = read_sprites()
            log_progress(find_player(sprites), last_mode)
        end
    end
    apply_p1()
    draw_overlay()
end)
