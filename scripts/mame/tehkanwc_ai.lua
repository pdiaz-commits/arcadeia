-- Tehkan World Cup — agente táctico (v4)
-- Sin balón: ir a buscarlo. Con balón: subir, esquivar rivales, disparar a portería.

local ROOT = "/Users/pablo/dossier/arcade-ai"
local AGENT = "heuristic"

local io = manager.machine.ioport
local sys = io.ports[":SYSTEM"]
local fld_p1x = io.ports[":P1X"].fields["Trackball X"]
local fld_p1y = io.ports[":P1Y"].fields["Trackball Y"]
local fld_btn = io.ports[":P1BUT"].fields["P1 Button 1"]

local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]
local SPRITE_BASE = 0xe800

-- Y bajo = portería rival (arriba en pantalla)
local OPP_GOAL_X = 128
local OPP_GOAL_Y = 36
local OUR_GOAL_Y = 200
local MID_Y = 112
local CENTER_X = 128
local CENTER_Y = 112
local MAX_DELTA = 58

-- Posesión, persecución y amenaza
local POSSESSION_DIST = 17
local CHASE_BOOST = 1.35
local THREAT_RADIUS = 32
local SHOOT_ZONE_Y = 80
local SHOOT_MAX_DIST = 72

-- Truco saque: puntos izq/der del círculo central
local KICKOFF_LEFT_X = 90
local KICKOFF_RIGHT_X = 166
local KICKOFF_Y = 110

-- 2ª franja verde campo rival (zona de centro-gol)
local GREEN_STRIPE_Y_MIN = 58
local GREEN_STRIPE_Y_MAX = 86

local frame = 0
local game_frames = 0
local boot_done = false
local prev = {}
local kick_windup = 0
local rnd_phase = 0
local kickoff_side = "left"
local kickoff_armed = true
local LEARNED = {}

local function load_learned()
    local path = ROOT .. "/scripts/mame/learned_tactics.lua"
    local chunk = loadfile(path)
    if chunk then
        local ok, data = pcall(chunk)
        if ok and type(data) == "table" then LEARNED = data end
    end
end
load_learned()

local function sys_field(mask)
    return sys:field(mask)
end

local function press(mask, on)
    local f = sys_field(mask)
    if f then f:set_value(on and 1 or 0) end
end

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function dist(a, b)
    return math.abs(a.sx - b.sx) + math.abs(a.sy - b.sy)
end

local function dist_xy(px, py, sx, sy)
    return math.abs(px - sx) + math.abs(py - sy)
end

local function read_sprites()
    local sprites = {}
    for offs = 0, 0x3fc, 4 do
        local base = SPRITE_BASE + offs
        local code = mem:read_u8(base)
        if code ~= 0 then
            local attr = mem:read_u8(base + 1)
            local sx = mem:read_u8(base + 2) + ((attr & 0x20) * 8) - 128
            local sy = mem:read_u8(base + 3)
            sprites[#sprites + 1] = {
                sx = sx, sy = sy, code = code, attr = attr, offs = offs,
            }
        end
    end
    return sprites
end

local function motion(s)
    local p = prev[s.offs]
    if not p then return 0 end
    return math.abs(s.sx - p.sx) + math.abs(s.sy - p.sy)
end

local function update_prev(sprites)
    for _, s in ipairs(sprites) do
        prev[s.offs] = { sx = s.sx, sy = s.sy }
    end
end

local function find_ball(sprites)
    local best, best_score = nil, -1
    for _, s in ipairs(sprites) do
        local m = motion(s)
        local score = m * 3
        if s.code <= 0x1f then score = score + 8 end
        if s.sy > 20 and s.sy < 230 then score = score + 2 end
        if score > best_score then
            best_score = score
            best = s
        end
    end
    if best then return best end
    for _, s in ipairs(sprites) do
        if s.code <= 0x1f then return s end
    end
    return nil
end

local function is_outfield(s)
    return s.code >= 0x08 and s.sy > 28 and s.sy < 225
end

local function find_player(sprites, ball)
    local outfield = {}
    for _, s in ipairs(sprites) do
        if is_outfield(s) then outfield[#outfield + 1] = s end
    end
    if #outfield == 0 then
        for _, s in ipairs(sprites) do
            if s.sy > 40 and s.sy < 220 then return s end
        end
        return nil
    end
    if not ball then
        local best = outfield[1]
        for _, s in ipairs(outfield) do
            if s.sy > best.sy then best = s end
        end
        return best
    end

    local closest, best_d = nil, 9999
    for _, s in ipairs(outfield) do
        local d = dist(s, ball)
        if d < best_d then
            best_d = d
            closest = s
        end
    end

    -- Sin posesión: el nuestro suele venir detrás del balón en ataque
    if best_d > POSSESSION_DIST * 2 and ball.sy < MID_Y then
        for _, s in ipairs(outfield) do
            if s.sy >= ball.sy - 18 and dist(s, ball) < best_d + 24 then
                return s
            end
        end
    end
    return closest
end

local function find_opponents(sprites, player)
    local opponents = {}
    if not player then return opponents end
    for _, s in ipairs(sprites) do
        if is_outfield(s) and s.offs ~= player.offs then
            opponents[#opponents + 1] = s
        end
    end
    return opponents
end

local function find_our_goalkeeper(sprites)
    local best = nil
    for _, s in ipairs(sprites) do
        if s.sy >= 185 and s.code >= 0x08 then
            if not best or s.sy > best.sy then best = s end
        end
    end
    return best
end

local function find_opp_goalkeeper(sprites)
    local best = nil
    for _, s in ipairs(sprites) do
        if s.sy < 58 and s.code >= 0x08 then
            if not best or s.sy < best.sy then best = s end
        end
    end
    return best
end

local function has_possession(player, ball)
    return player and ball and dist(player, ball) < POSSESSION_DIST
end

local function nearest_threat(player, opponents)
    local best, best_d = nil, 9999
    for _, o in ipairs(opponents) do
        local d = dist(player, o)
        if d < best_d then
            best_d = d
            best = o
        end
    end
    return best, best_d
end

local function shoot_past_gk(player, opp_gk)
    local target_x
    if opp_gk and dist(opp_gk, player) < 55 then
        if opp_gk.sx <= OPP_GOAL_X then
            target_x = OPP_GOAL_X + 44
        else
            target_x = OPP_GOAL_X - 44
        end
    else
        target_x = (player.sx <= CENTER_X) and (OPP_GOAL_X + 38) or (OPP_GOAL_X - 38)
    end
    local dx = clamp(target_x - player.sx, -MAX_DELTA, MAX_DELTA)
    return dx, -MAX_DELTA, true
end

local function chase_ball(player, ball, opponents)
    local bx, by = predict_ball(ball)
    local boost = CHASE_BOOST
    if dist(player, ball) > 36 then boost = CHASE_BOOST + 0.25 end
    local dx = (bx - player.sx) * boost
    local dy = (by - player.sy) * boost

    local rival, rd = nearest_threat(player, opponents)
    if rival and dist(rival, ball) < dist(player, ball) + 6 and rd < 34 then
        local dodge_x, dodge_y = dodge_rival(player, rival)
        dx = math.floor(dx * 0.45 + dodge_x * 0.55)
        dy = math.floor(dy * 0.45 + dodge_y * 0.55)
    end

    return clamp(dx, -MAX_DELTA, MAX_DELTA), clamp(dy, -MAX_DELTA, MAX_DELTA), false
end

local function dodge_rival(player, threat)
    local away = player.sx - threat.sx
    if math.abs(away) < 6 then
        away = (player.sx < CENTER_X) and 1 or -1
    end
    local dx = (away > 0) and MAX_DELTA or -MAX_DELTA
    local dy = -math.floor(MAX_DELTA * 0.55)
    return dx, dy, false
end

local function dribble_upfield(player, ball, opponents)
    local threat, td = nearest_threat(player, opponents)
    if threat and td < THREAT_RADIUS then
        return dodge_rival(player, threat)
    end

    local bx, by = predict_ball(ball)
    local tx = bx + (OPP_GOAL_X - bx) * 0.12
    local ty = math.max(OPP_GOAL_Y + 10, by - 38)

    local dx = clamp((tx - player.sx) * 1.1, -MAX_DELTA, MAX_DELTA)
    local dy = clamp((ty - player.sy) * 1.1, -MAX_DELTA, MAX_DELTA)
    if dy > -18 then dy = -18 end
    return dx, dy, false
end

local function predict_ball(ball)
    local p = prev[ball.offs]
    if not p then return ball.sx, ball.sy end
    return ball.sx + (ball.sx - p.sx) * 4, ball.sy + (ball.sy - p.sy) * 4
end

local function ball_at_kickoff(ball)
    return math.abs(ball.sx - CENTER_X) < 24 and math.abs(ball.sy - CENTER_Y) < 24
end

-- Diagonal al palo contrario (ajustado)
local function far_post_vector(player_sx)
    if player_sx <= CENTER_X then
        return 54, -MAX_DELTA  -- desde izquierda → palo derecho
    end
    return -54, -MAX_DELTA     -- desde derecha → palo izquierdo
end

local function apply_move(dx, dy, kick)
    fld_p1x:set_value(clamp(dx, -MAX_DELTA, MAX_DELTA))
    fld_p1y:set_value(clamp(dy, -MAX_DELTA, MAX_DELTA))
    fld_btn:set_value(kick and 1 or 0)
end

-- Trucos aprendidos de tus demos (prioridad máxima)
local function try_learned(ball, player)
    if #LEARNED == 0 then return false end
    for _, t in ipairs(LEARNED) do
        if math.abs(ball.sx - t.bx) <= t.bx_tol
            and math.abs(ball.sy - t.by) <= t.by_tol
            and player.sy <= t.py_max then
            apply_move(t.dx, t.dy, t.kick)
            return true
        end
    end
    return false
end

-- Trucos con prioridad (devuelve true si aplica)
local function try_tricks(ball, player)
    local near_ball = dist(player, ball) < 24

    -- Re-armar saque cuando el balón vuelve al centro
    if ball_at_kickoff(ball) and motion(ball) < 3 then
        kickoff_armed = true
    end

    -- TRUCO 1: Gol desde saque (izq/der del círculo central, primeros segundos)
    if kickoff_armed and game_frames < 520 and ball_at_kickoff(ball) then
        local spot_x = (kickoff_side == "left") and KICKOFF_LEFT_X or KICKOFF_RIGHT_X
        local at_spot = dist_xy(player.sx, player.sy, spot_x, KICKOFF_Y) < 22

        if not at_spot then
            apply_move(spot_x - player.sx, KICKOFF_Y - player.sy, false)
            return true
        end
        if near_ball then
            local dx, dy = far_post_vector(player.sx)
            apply_move(dx, dy, true)
            kickoff_armed = false
            kickoff_side = (kickoff_side == "left") and "right" or "left"
            return true
        end
    end

    -- TRUCO 2: Centro-gol desde 2ª franja verde (final campo rival)
    if player.sy >= GREEN_STRIPE_Y_MIN and player.sy <= GREEN_STRIPE_Y_MAX
        and ball.sy < MID_Y and near_ball then
        local dx = (OPP_GOAL_X - player.sx) * 0.85
        apply_move(dx, -MAX_DELTA, true)
        return true
    end

    -- TRUCO 3: Diagonal al palo contrario (zona de remate)
    if ball.sy < 100 and player.sy < 108 and near_ball and ball.sy < MID_Y then
        local dx, dy = far_post_vector(player.sx)
        apply_move(dx, dy, true)
        return true
    end

    return false
end

local function boot_sequence()
    if frame == 40 then press(0x01, true)
    elseif frame == 50 then press(0x01, false)
    elseif frame == 70 then press(0x04, true)
    elseif frame == 85 then press(0x04, false)
    elseif frame == 130 then press(0x20, true)
    elseif frame == 140 then press(0x20, false)
    elseif frame == 150 then boot_done = true
    end
end

local function act_random()
    rnd_phase = rnd_phase + 1
    apply_move(((rnd_phase * 7) % 81) - 40, ((rnd_phase * 11) % 81) - 40, (rnd_phase % 45) < 3)
end

local function act_heuristic()
    local sprites = read_sprites()
    local ball = find_ball(sprites)
    local player = find_player(sprites, ball)
    local opp_gk = find_opp_goalkeeper(sprites)
    local our_gk = find_our_goalkeeper(sprites)
    local opponents = find_opponents(sprites, player)

    if not ball or not player then
        apply_move(0, -MAX_DELTA, false)
        update_prev(sprites)
        return
    end

    if try_learned(ball, player) then
        update_prev(sprites)
        return
    end

    if try_tricks(ball, player) then
        update_prev(sprites)
        return
    end

    local possessed = has_possession(player, ball)
    local ball_in_our_half = ball.sy > MID_Y
    local gk_mode = ball_in_our_half and ball.sy > 150 and our_gk and dist(our_gk, ball) < 50

    local dx, dy, kick

    -- Portero propio: bloquear línea de gol
    if gk_mode and player.sy > 170 then
        local bx = predict_ball(ball)
        dx = clamp(bx - player.sx, -MAX_DELTA, MAX_DELTA)
        dy = 0
        kick = false
    -- Sin balón: ir a buscarlo siempre
    elseif not possessed then
        dx, dy, kick = chase_ball(player, ball, opponents)
        local rival, rd = nearest_threat(player, opponents)
        if rival and rd < 22 and rival.sy < player.sy + 8 then
            local dodge_x, dodge_y = dodge_rival(player, rival)
            dx = math.floor((dx + dodge_x) * 0.55)
            dy = math.floor((dy + dodge_y) * 0.55)
        end
    -- Con balón cerca de portería: disparar lejos del portero
    elseif player.sy < SHOOT_ZONE_Y
        and dist_xy(player.sx, player.sy, OPP_GOAL_X, OPP_GOAL_Y) < SHOOT_MAX_DIST then
        dx, dy, kick = shoot_past_gk(player, opp_gk)
        kick_windup = kick_windup + 1
        if kick_windup < 2 then kick = false end
    -- Con balón: subir esquivando rivales
    else
        kick_windup = 0
        dx, dy, kick = dribble_upfield(player, ball, opponents)
    end

    apply_move(dx, dy, kick)
    update_prev(sprites)
end

local function draw_overlay()
    local screen = manager.machine.screens[":screen"]
    if not screen then return end
    local mode = "AI boot..."
    if boot_done then
        local sprites = read_sprites()
        local ball = find_ball(sprites)
        local player = find_player(sprites, ball)
        if ball and player and has_possession(player, ball) then
            mode = "AI BALON"
        elseif ball and player then
            mode = "AI BUSCAR"
        else
            mode = "AI " .. AGENT
        end
    end
    screen:draw_text(4, 4, string.format("%s  f%d", mode, frame), 0xffffffff, 0xff000000)
end

emu.register_frame_done(function()
    frame = frame + 1
    if not boot_done then
        boot_sequence()
        draw_overlay()
        return
    end
    game_frames = game_frames + 1

    if AGENT == "random" then act_random() else act_heuristic() end
    draw_overlay()
end)
