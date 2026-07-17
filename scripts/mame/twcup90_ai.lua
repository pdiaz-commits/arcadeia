-- TECMO WORLD CUP '90 (twcup90) — agente heurístico v1
-- Objetivo: GANAR EL PARTIDO.
-- Controles MAME P1: ↑↓←→ (8 dirs), Btn1=disparo/entrada, Btn2=pase/cambio jugador.
-- Moneda=5 (0x01 ACTIVE_HIGH), Start=1 (0x04).

local ROOT = "/Users/pablo/Documents/arcade-ai"
local AGENT = "heuristic"

local sys = manager.machine.ioport.ports[":SYSTEM"]
local p1 = manager.machine.ioport.ports[":P1"]
local subcpu = manager.machine.devices[":sub"]
local mem = subcpu and subcpu.spaces["program"] or nil

local SPRITE_BASE = 0xd000
local SPRITE_END  = 0xd800

local P1_UP    = 0x01
local P1_DOWN  = 0x02
local P1_LEFT  = 0x04
local P1_RIGHT = 0x08
local P1_BTN1  = 0x10
local P1_BTN2  = 0x20

local SYS_COIN1  = 0x01
local SYS_START1 = 0x04

local FIELD_W = 256
local FIELD_H = 224
local MID_X = 128
local FINAL_THIRD = 72
local MAX_DELTA = 58

local frame = 0
local boot_done = false
local game_frames = 0
local zig_up = true
local zig_cd = 0
local btn1_hold = 0
local btn2_hold = 0
local attack_right = true
local prev = {}

local function press_sys(mask, on)
    local f = sys:field(mask)
    if f then f:set_value(on and 1 or 0) end
end

local function press_coin(on)
    press_sys(SYS_COIN1, on)
end

local function press_start(on)
    press_sys(SYS_START1, on)
end

local function set_p1(mask)
    for _, bit in ipairs({P1_UP, P1_DOWN, P1_LEFT, P1_RIGHT, P1_BTN1, P1_BTN2}) do
        local f = p1:field(bit)
        if f then f:set_value((mask & bit) ~= 0 and 1 or 0) end
    end
end

local function dist_xy(ax, ay, bx, by)
    return math.abs(ax - bx) + math.abs(ay - by)
end

local function read_sprites()
    local sprites = {}
    if not mem then return sprites end
    for offs = 0, SPRITE_END - SPRITE_BASE - 4, 4 do
        local b = SPRITE_BASE + offs
        local sy = mem:read_u8(b)
        local code = mem:read_u8(b + 1)
        local attr = mem:read_u8(b + 2)
        local sx = mem:read_u8(b + 3)
        if code ~= 0 and sy > 8 and sy < 220 then
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
        local score = m * 4
        if s.code <= 0x40 then score = score + 6 end
        if score > best_score then
            best_score = score
            best = s
        end
    end
    return best
end

local function find_player(sprites, ball)
    local best, best_d = nil, 9999
    for _, s in ipairs(sprites) do
        if s.code >= 0x10 and s.code < 0xc0 then
            local d = ball and dist_xy(s.sx, s.sy, ball.sx, ball.sy) or s.sy
            if d < best_d then
                best_d = d
                best = s
            end
        end
    end
    return best
end

local function find_rivals(sprites, player)
    local rivals = {}
    if not player then return rivals end
    for _, s in ipairs(sprites) do
        if s.code >= 0x10 and s.offs ~= player.offs then
            if dist_xy(s.sx, s.sy, player.sx, player.sy) < 80 then
                rivals[#rivals + 1] = s
            end
        end
    end
    return rivals
end

local function nearest_rival(player, rivals)
    local best, best_d = nil, 9999
    for _, r in ipairs(rivals) do
        local d = dist_xy(r.sx, r.sy, player.sx, player.sy)
        if d < best_d then
            best_d = d
            best = r
        end
    end
    return best, best_d
end

local function has_ball(player, ball)
    return player and ball and dist_xy(player.sx, player.sy, ball.sx, ball.sy) < 20
end

local function decide_attack_side(player, ball)
    if ball then
        attack_right = ball.sx >= MID_X
    elseif player then
        attack_right = player.sx < MID_X
    end
end

-- Diagonal continua hacia portería rival (↗ o ↘ / ↖ o ↙)
local function diagonal_mask()
    if attack_right then
        if zig_up then return P1_RIGHT | P1_UP else return P1_RIGHT | P1_DOWN end
    else
        if zig_up then return P1_LEFT | P1_UP else return P1_LEFT | P1_DOWN end
    end
end

local function in_final_third(player)
    if attack_right then return player.sx >= FIELD_W - FINAL_THIRD end
    return player.sx <= FINAL_THIRD
end

local function boot_sequence()
    if frame == 90 then press_coin(true)
    elseif frame == 104 then press_coin(false)
    elseif frame == 150 then press_start(true)
    elseif frame == 162 then press_start(false)
    elseif frame == 300 then press_start(true)
    elseif frame == 312 then press_start(false)
    elseif frame == 450 then press_start(true)
    elseif frame == 462 then press_start(false)
    elseif frame == 520 then boot_done = true
    end
end

local function act_with_ball(player, ball, rivals)
    decide_attack_side(player, ball)
    local rival, rd = nearest_rival(player, rivals)

    if rival and rd < 36 then
        zig_cd = zig_cd + 1
        if zig_cd > 20 then
            zig_up = not zig_up
            zig_cd = 0
        end
    end

    local mask = diagonal_mask()
    local shoot = false
    local pass = false

    if in_final_third(player) then
        shoot = true
        btn1_hold = 4
    elseif rival and rd < 28 then
        shoot = false
    else
        shoot = (game_frames % 18) < 3
    end

    if shoot and btn1_hold > 0 then
        mask = mask | P1_BTN1
        btn1_hold = btn1_hold - 1
    end
    set_p1(mask)
end

local function act_without_ball(player, ball, rivals)
    decide_attack_side(player, ball)
    local mask = 0
    local rival, rd = nearest_rival(player, rivals)

    if ball then
        local cut_x = ball.sx + (player.sx - ball.sx) * 0.3
        local cut_y = ball.sy + (player.sy - ball.sy) * 0.3
        if cut_x > player.sx then mask = mask | P1_RIGHT elseif cut_x < player.sx then mask = mask | P1_LEFT end
        if cut_y > player.sy then mask = mask | P1_DOWN elseif cut_y < player.sy then mask = mask | P1_UP end
    else
        mask = diagonal_mask()
    end

    if rival and rd < 22 then
        mask = mask | P1_BTN1
        btn1_hold = 3
    elseif (game_frames % 45) < 4 then
        mask = mask | P1_BTN2
    end

    set_p1(mask)
end

local function act_heuristic()
    local sprites = read_sprites()
    local ball = find_ball(sprites)
    local player = find_player(sprites, ball)
    local rivals = find_rivals(sprites, player)

    if not player then
        if game_frames % 180 == 0 then press_start(true)
        elseif game_frames % 180 == 6 then press_start(false) end
        set_p1(diagonal_mask())
        update_prev(sprites)
        return
    end

    if has_ball(player, ball) then
        act_with_ball(player, ball, rivals)
    else
        act_without_ball(player, ball, rivals)
    end
    update_prev(sprites)
end

local function draw_overlay()
    local screen = manager.machine.screens[":screen"]
    if not screen then return end
    local mode = "BOOT"
    if not boot_done then
        if frame < 104 then mode = "COIN 5"
        elseif frame < 312 then mode = "START 1"
        else mode = "READY" end
    else
        local sprites = read_sprites()
        local ball = find_ball(sprites)
        local player = find_player(sprites, ball)
        if player and ball and has_ball(player, ball) then
            mode = attack_right and "ATK↗" or "ATK↖"
        elseif player then
            mode = "DEF"
        else
            mode = "AI"
        end
    end
    screen:draw_text(4, 4, string.format("WC90 %s f%d", mode, frame), 0xffffffff, 0xff000000)
end

emu.register_frame_done(function()
    frame = frame + 1
    if not boot_done then
        boot_sequence()
        draw_overlay()
        return
    end
    game_frames = game_frames + 1
    if AGENT == "random" then
        set_p1(((frame * 3) % 16))
    else
        act_heuristic()
    end
    draw_overlay()
end)
