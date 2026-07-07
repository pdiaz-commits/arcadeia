-- Wonder Boy — agente platformer (v2)
-- Saltar rocas/fuego a tiempo, coger frutas y herramientas, hacha a rivales.

local ROOT = "/Users/pablo/dossier/arcade-ai"
local AGENT = "heuristic"

local sys = manager.machine.ioport.ports[":SYSTEM"]
local p1 = manager.machine.ioport.ports[":P1"]
local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]

local SPRITE_BASE = 0xd000

-- Sprites identificados en partidas reales
local PLAYER_CODES = { [0x83] = true, [0x82] = true, [0x84] = true }
local IGNORE_CODES = { [0x8d] = true }
local ROCK_CODES   = { [0x7c] = true, [0x7b] = true, [0x7f] = true }
local FIRE_CODES   = { [0x69] = true, [0x67] = true, [0xd8] = true, [0x68] = true }
local ENEMY_CODES  = { [0x49] = true, [0x48] = true, [0x4a] = true, [0x4b] = true }
local FRUIT_CODES  = { [0x8f] = true, [0x91] = true, [0x87] = true, [0x67] = true }
local TOOL_CODES   = { [0x80] = true, [0x81] = true, [0x85] = true, [0x86] = true }

local SCAN_AHEAD = 96
local GROUND_TOL = 22
local JUMP_HOLD = 26
local AXE_RANGE = 36

local frame = 0
local boot_done = false
local jump_cd = 0
local prev_player_x = nil
local prev_player_sy = nil
local airborne = 0

local P1_RIGHT = 0x40
local P1_LEFT  = 0x80
local P1_JUMP  = 0x02
local P1_AXE   = 0x04

local function press_sys(mask, on)
    local f = sys:field(mask)
    if f then f:set_value(on and 1 or 0) end
end

local function set_p1(right, left, jump, axe)
    local function bit(m, on)
        local f = p1:field(m)
        if f then f:set_value(on and 1 or 0) end
    end
    bit(P1_RIGHT, right)
    bit(P1_LEFT, left)
    bit(P1_JUMP, jump)
    bit(P1_AXE, axe)
end

local function classify(code)
    if ROCK_CODES[code] then return "rock" end
    if FIRE_CODES[code] then return "fire" end
    if ENEMY_CODES[code] then return "enemy" end
    if FRUIT_CODES[code] then return "fruit" end
    if TOOL_CODES[code] then return "tool" end
    return "other"
end

local function read_sprites()
    local sprites = {}
    for offs = 0, 0x7f8, 8 do
        local base = SPRITE_BASE + offs
        local code = mem:read_u8(base)
        if code ~= 0 and not IGNORE_CODES[code] then
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
    if airborne > 0 then return false end
    return math.abs(player.sy - prev_player_sy) < 4
end

local function ahead_dx(player, s)
    return s.sx - player.sx
end

local function same_lane(player, s)
    return math.abs(s.sy - player.sy) <= GROUND_TOL
end

local function jump_window(kind, dx)
    if kind == "fire" then
        return dx >= 34 and dx <= 62
    elseif kind == "rock" then
        return dx >= 26 and dx <= 50
    elseif kind == "enemy" then
        return dx >= 20 and dx <= 44
    elseif kind == "fruit" or kind == "tool" then
        return dx >= 14 and dx <= 48
    end
    if dx >= 28 and dx <= 55 and kind == "other" then
        return same_lane -- obstáculo genérico en el suelo
    end
    return false
end

local function scan_ahead(player, sprites)
    local rock, fire, enemy, fruit, tool = nil, nil, nil, nil, nil
    local best_fruit_score = -999

    for _, s in ipairs(sprites) do
        if s.offs == player.offs or PLAYER_CODES[s.code] then goto continue end
        local dx = ahead_dx(player, s)
        if dx < 4 or dx > SCAN_AHEAD then goto continue end

        if s.kind == "rock" and same_lane(player, s) then
            if not rock or dx < ahead_dx(player, rock) then rock = s end
        elseif s.kind == "fire" and s.sy >= player.sy - 12 then
            if not fire or dx < ahead_dx(player, fire) then fire = s end
        elseif s.kind == "enemy" and math.abs(s.sy - player.sy) < 30 then
            if not enemy or dx < ahead_dx(player, enemy) then enemy = s end
        elseif s.kind == "fruit" then
            local score = 120 - dx + ((player.sy - s.sy) > 8 and 25 or 0)
            if score > best_fruit_score then
                best_fruit_score = score
                fruit = s
            end
        elseif s.kind == "tool" then
            if not tool or dx < ahead_dx(player, tool) then tool = s end
        elseif s.kind == "other" and same_lane(player, s) and s.sy >= player.sy - 8 then
            if not rock or dx < ahead_dx(player, rock) then rock = s end
        end
        ::continue::
    end
    return rock, fire, enemy, fruit, tool
end

local function boot_sequence()
    if frame == 40 then press_sys(0x01, true)
    elseif frame == 50 then press_sys(0x01, false)
    elseif frame == 90 then press_sys(0x10, true)
    elseif frame == 105 then press_sys(0x10, false)
    elseif frame == 180 then press_sys(0x10, true)
    elseif frame == 195 then press_sys(0x10, false)
    elseif frame == 240 then set_p1(true, false, true, false)
    elseif frame == 248 then set_p1(false, false, false, false)
    elseif frame == 260 then boot_done = true
    end
end

local function act_random()
    local r = frame % 47
    set_p1(r > 5, r < 3, r == 10 or r == 11, r == 20)
end

local function act_heuristic()
    local sprites = read_sprites()
    local player = find_player(sprites)

    local right, left, jump, axe = true, false, false, false
    local mode = "RUN"

    if player then
        if prev_player_sy and math.abs(player.sy - prev_player_sy) > 6 then
            airborne = JUMP_HOLD
        end
        if airborne > 0 then airborne = airborne - 1 end

        local rock, fire, enemy, fruit, tool = scan_ahead(player, sprites)
        local grounded = on_ground(player)

        -- Supervivencia: fuego y rocas (fuego = saltar antes)
        if grounded and jump_cd <= 0 then
            if fire then
                local dx = ahead_dx(player, fire)
                if jump_window("fire", dx) then
                    jump = true
                    mode = "FIRE"
                end
            elseif rock then
                local dx = ahead_dx(player, rock)
                if jump_window("rock", dx) then
                    jump = true
                    mode = "ROCA"
                end
            end
        end

        -- Rival en el suelo: hacha cerca, salto si no llega el hacha
        if enemy and not jump then
            local dx = ahead_dx(player, enemy)
            local dy = math.abs(enemy.sy - player.sy)
            if dx < AXE_RANGE and dy < 24 then
                axe = true
                mode = "HACHA"
            elseif grounded and jump_cd <= 0 and jump_window("enemy", dx) and dy < 28 then
                jump = true
                mode = "ENEMIGO"
            end
        end

        -- Frutas y herramientas: saltar para cogerlas
        if grounded and jump_cd <= 0 and not jump then
            local target = fruit or tool
            if target then
                local dx = ahead_dx(player, target)
                local above = target.sy < player.sy - 6
                if jump_window(target.kind, dx) and (above or dx < 30) then
                    jump = true
                    mode = target.kind == "fruit" and "FRUTA" or "TOOL"
                end
            end
        end

        if jump then jump_cd = JUMP_HOLD end
        prev_player_x = player.sx
        prev_player_sy = player.sy
    else
        right = true
    end

    if jump_cd > 0 and not jump then jump_cd = jump_cd - 1 end
    set_p1(right, left, jump, axe)

    return mode
end

local last_mode = "RUN"

local function draw_overlay()
    local screen = manager.machine.screens[":screen"]
    if not screen then return end
    local tag = boot_done and ("AI " .. last_mode) or "AI boot..."
    screen:draw_text(4, 4, string.format("%s  f%d", tag, frame), 0xffffffff, 0xff000000)
end

emu.register_frame_done(function()
    frame = frame + 1
    if not boot_done then
        boot_sequence()
        draw_overlay()
        return
    end
    if AGENT == "random" then
        act_random()
    else
        last_mode = act_heuristic() or "RUN"
    end
    draw_overlay()
end)
