-- Debug possession: log ball/player/dist/possessed every 4 frames during AI match
local ROOT = "/Users/pablo/Documents/arcade-ai"
local LOG_PATH = ROOT .. "/logs/demos/debug_possession.jsonl"
local MAX_FRAMES = 2400  -- ~40s

local io_ports = manager.machine.ioport
local sys = io_ports.ports[":SYSTEM"]
local fld_p1x = io_ports.ports[":P1X"].fields["Trackball X"]
local fld_p1y = io_ports.ports[":P1Y"].fields["Trackball Y"]

local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]
local SPRITE_BASE = 0xe800
local CROWD_PANEL_X = 200
local CENTER_X, CENTER_Y = 128, 112
local POSSESSION_DIST = 22
local MID_Y = 112

local frame = 0
local boot_done = false
local game_frames = 0
local prev = {}
local log = nil

local function open_log()
    if log then return end
    os.execute("mkdir -p " .. ROOT .. "/logs/demos")
    log = io.open(LOG_PATH, "w")
end

local function press(mask, on)
    local f = sys:field(mask)
    if f then f:set_value(on and 1 or 0) end
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

local function find_ball_current(sprites)
    local best, best_score = nil, -1
    for _, s in ipairs(sprites) do
        if s.sx >= CROWD_PANEL_X or s.sy <= 20 or s.sy >= 230 then goto continue end
        local m = motion(s)
        local score = m * 4
        if s.code == 0x0c then
            score = score + (m > 0 and 24 or 6)
        elseif s.code <= 0x1f and s.code ~= 0x01 and s.code ~= 0x0b then
            score = score + 10
        else
            goto continue
        end
        if score > best_score then best_score, best = score, s end
        ::continue::
    end
    return best, best_score
end

local function find_ball_0c(sprites)
    for _, s in ipairs(sprites) do
        if s.code == 0x0c and s.sx < CROWD_PANEL_X and s.sy > 20 and s.sy < 230 then
            return s
        end
    end
    return nil
end

local function is_outfield(s)
    return s.code >= 0x08 and s.sy > 28 and s.sy < 225 and s.sx < CROWD_PANEL_X
end

local function find_player(sprites, ball)
    local outfield = {}
    for _, s in ipairs(sprites) do
        if is_outfield(s) then outfield[#outfield + 1] = s end
    end
    if #outfield == 0 or not ball then return nil, 9999 end
    local closest, best_d = nil, 9999
    for _, s in ipairs(outfield) do
        local d = dist(s, ball)
        if d < best_d then best_d, closest = d, s end
    end
    return closest, best_d
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
    if not boot_done then
        boot_sequence()
        return
    end
    game_frames = game_frames + 1

    -- minimal movement so match progresses
    fld_p1x:set_value(0)
    fld_p1y:set_value(-40)

    if game_frames % 4 == 0 and game_frames <= MAX_FRAMES then
        open_log()
        local sprites = read_sprites()
        local ball_h, score_h = find_ball_current(sprites)
        local ball_0c = find_ball_0c(sprites)
        local player, pd = find_player(sprites, ball_h)
        local player_0c, pd0 = find_player(sprites, ball_0c)

        local n_0c = 0
        for _, s in ipairs(sprites) do
            if s.code == 0x0c and s.sx < CROWD_PANEL_X then n_0c = n_0c + 1 end
        end

        log:write(string.format(
            '{"gf":%d,"ball_h":{"x":%d,"y":%d,"code":"%02x","offs":%d,"score":%d},"ball_0c":{"x":%d,"y":%d},"player_h":{"x":%d,"y":%d},"dist_h":%d,"player_0c":{"x":%d,"y":%d},"dist_0c":%d,"n_0c":%d,"poss_h":%s,"poss_0c":%s,"dx":%d,"dy":%d}\n',
            game_frames,
            ball_h and ball_h.sx or -1, ball_h and ball_h.sy or -1,
            ball_h and ball_h.code or 0, ball_h and ball_h.offs or -1, score_h or -1,
            ball_0c and ball_0c.sx or -1, ball_0c and ball_0c.sy or -1,
            player and player.sx or -1, player and player.sy or -1, pd,
            player_0c and player_0c.sx or -1, player_0c and player_0c.sy or -1, pd0,
            n_0c,
            (player and ball_h and pd < POSSESSION_DIST) and "true" or "false",
            (player_0c and ball_0c and pd0 < POSSESSION_DIST) and "true" or "false",
            tonumber(fld_p1x.live and fld_p1x.live.value or 0) or 0,
            tonumber(fld_p1y.live and fld_p1y.live.value or 0) or 0
        ))
        if game_frames % 120 == 0 then log:flush() end

        for _, s in ipairs(sprites) do
            prev[s.offs] = { sx = s.sx, sy = s.sy }
        end
    end

    if game_frames >= MAX_FRAMES then
        if log then log:close() end
        manager.machine:exit()
    end
end)
