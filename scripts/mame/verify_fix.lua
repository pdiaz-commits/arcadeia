-- Compare possession stats with fixed find_ball (0x0c priority)
local ROOT = "/Users/pablo/Documents/arcade-ai"
local LOG_PATH = ROOT .. "/logs/demos/verify_fix.jsonl"
local MAX_FRAMES = 1800

local io_ports = manager.machine.ioport
local sys = io_ports.ports[":SYSTEM"]
local fld_p1x = io_ports.ports[":P1X"].fields["Trackball X"]
local fld_p1y = io_ports.ports[":P1Y"].fields["Trackball Y"]
local fld_btn = io_ports.ports[":P1BUT"].fields["P1 Button 1"]

local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]
local SPRITE_BASE = 0xe800

local POSSESSION_DIST = 35
local NEAR_BALL_DIST = 40
local CROWD_PANEL_X = 200
local FIELD_Y_MIN = 24
local FIELD_Y_MAX = 228
local CENTER_X, CENTER_Y = 128, 112
local SPRINT = 58
local OPP_GOAL_X = 128
local OPP_GOAL_Y = 36
local MID_Y = 112
local MAX_DELTA = SPRINT

local frame = 0
local boot_done = false
local game_frames = 0
local prev = {}
local log = nil
local last_dx, last_dy = 0, 0

local function press(mask, on)
    local f = sys:field(mask)
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

local function read_sprites()
    local sprites = {}
    for offs = 0, 0x3fc, 4 do
        local base = SPRITE_BASE + offs
        local code = mem:read_u8(base)
        if code ~= 0 then
            local attr = mem:read_u8(base + 1)
            local sx = mem:read_u8(base + 2) + ((attr & 0x20) * 8) - 128
            local sy = mem:read_u8(base + 3)
            sprites[#sprites + 1] = { sx = sx, sy = sy, code = code, offs = offs }
        end
    end
    return sprites
end

local function motion(s)
    local p = prev[s.offs]
    if not p then return 0 end
    return math.abs(s.sx - p.sx) + math.abs(s.sy - p.sy)
end

local function on_field(s)
    return s.sx < CROWD_PANEL_X and s.sy > FIELD_Y_MIN and s.sy < FIELD_Y_MAX
end

local function is_ball_code(code)
    return code == 0x0c
        or (code <= 0x1f and code ~= 0x01 and code ~= 0x0a and code ~= 0x0b)
end

local function find_ball(sprites)
    local candidates = {}
    for _, s in ipairs(sprites) do
        if on_field(s) and is_ball_code(s.code) then
            candidates[#candidates + 1] = s
        end
    end
    for _, s in ipairs(candidates) do
        if s.code == 0x0c then return s end
    end
    local best, best_score = nil, -1
    for _, s in ipairs(candidates) do
        local m = motion(s)
        local at_center = math.abs(s.sx - CENTER_X) < 20 and math.abs(s.sy - CENTER_Y) < 20
        if at_center and m == 0 then goto continue end
        local score = m * 5 + 8
        if score > best_score then best_score, best = score, s end
        ::continue::
    end
    return best
end

local function is_outfield(s)
    return s.code >= 0x08 and s.sy > 28 and s.sy < 225 and s.sx < CROWD_PANEL_X
end

local function find_player(sprites, ball)
    local outfield = {}
    for _, s in ipairs(sprites) do
        if is_outfield(s) then outfield[#outfield + 1] = s end
    end
    if #outfield == 0 or not ball then return nil end
    local closest, best_d = nil, 9999
    for _, s in ipairs(outfield) do
        local d = dist(s, ball)
        if d < best_d then best_d, closest = d, s end
    end
    return closest
end

local function sprint_diagonal(player)
    local goal_bias = clamp(OPP_GOAL_X - player.sx, -SPRINT, SPRINT)
    return clamp(math.floor(goal_bias * 0.55), -SPRINT, SPRINT), -SPRINT
end

local function boot_sequence()
    if frame == 90 then press(0x01, true)
    elseif frame == 104 then press(0x01, false)
    elseif frame == 150 then press(0x04, true)
    elseif frame == 162 then press(0x04, false)
    elseif frame == 300 then press(0x04, true)
    elseif frame == 312 then press(0x04, false)
    elseif frame == 450 then press(0x04, true)
    elseif frame == 462 then press(0x04, false)
    elseif frame == 520 then boot_done = true
    end
end

emu.register_frame_done(function()
    frame = frame + 1
    if not boot_done then boot_sequence(); return end
    game_frames = game_frames + 1

    local sprites = read_sprites()
    local ball = find_ball(sprites)
    local player = find_player(sprites, ball)
    local bd = (ball and player) and dist(player, ball) or 9999
    local poss = bd <= POSSESSION_DIST
    local close = bd <= NEAR_BALL_DIST

    local dx, dy = 0, 0
    if poss or close then
        dx, dy = sprint_diagonal(player)
    elseif ball and player then
        dx = clamp(ball.sx - player.sx, -SPRINT, SPRINT)
        dy = clamp(ball.sy - player.sy, -SPRINT, SPRINT)
    end
    if close and math.abs(dx) + math.abs(dy) < 12 then
        dx, dy = sprint_diagonal(player)
    end
    last_dx, last_dy = dx, dy
    fld_p1x:set_value(dx)
    fld_p1y:set_value(dy)
    fld_btn:set_value(0)

    if game_frames % 4 == 0 and game_frames <= MAX_FRAMES then
        if not log then
            os.execute("mkdir -p " .. ROOT .. "/logs/demos")
            log = io.open(LOG_PATH, "w")
        end
        log:write(string.format(
            '{"gf":%d,"ball":{"x":%d,"y":%d,"code":"%02x"},"player":{"x":%d,"y":%d},"dist":%d,"poss":%s,"close":%s,"dx":%d,"dy":%d,"idle":%s}\n',
            game_frames,
            ball and ball.sx or -1, ball and ball.sy or -1, ball and ball.code or 0,
            player and player.sx or -1, player and player.sy or -1,
            bd, poss and "true" or "false", close and "true" or "false",
            dx, dy, (close and math.abs(dx)+math.abs(dy)<12) and "true" or "false"
        ))
        if game_frames % 120 == 0 then log:flush() end
    end

    for _, s in ipairs(sprites) do prev[s.offs] = { sx = s.sx, sy = s.sy } end

    if game_frames >= MAX_FRAMES then
        if log then log:close() end
        manager.machine:exit()
    end
end)
