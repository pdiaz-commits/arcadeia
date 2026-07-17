-- Graba la demo de atract mode (antes de moneda) → logs/demos/attract_*.jsonl
-- El juego muestra cómo jugar; observamos sprites y entradas del trackball.

local ROOT = "/Users/pablo/Documents/arcade-ai"
local LOG_DIR = ROOT .. "/logs/demos"
local SESSION = "attract_" .. os.date("%Y%m%d_%H%M%S")
local LOG_PATH = LOG_DIR .. "/" .. SESSION .. ".jsonl"

local io_ports = manager.machine.ioport
local fld_p1x = io_ports.ports[":P1X"].fields["Trackball X"]
local fld_p1y = io_ports.ports[":P1Y"].fields["Trackball Y"]
local fld_btn = io_ports.ports[":P1BUT"].fields["P1 Button 1"]

local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]
local SPRITE_BASE = 0xe800

local OPP_GOAL_Y = 36
local MID_Y = 112
local POSSESSION_DIST = 17
local CROWD_PANEL_X = 200  -- panel lateral derecho (no es el balón)

local frame = 0
local log = nil
local RECORD_FRAMES = 1200  -- ~60 s a 60 fps
local prev = {}

local function motion(offs)
    return function(s)
        local p = prev[offs or s.offs]
        if not p then return 0 end
        return math.abs(s.sx - p.sx) + math.abs(s.sy - p.sy)
    end
end

local function dist(a, b)
    return math.abs(a.sx - b.sx) + math.abs(a.sy - b.sy)
end

local function is_outfield(s)
    return s.code >= 0x08 and s.sy > 28 and s.sy < 225 and s.sx < CROWD_PANEL_X
end

local function find_ball(sprites)
    -- Balón real: sprite code 0x0c (offs 0x000 en Tehkan WC)
    for _, s in ipairs(sprites) do
        if s.code == 0x0c and s.sx < CROWD_PANEL_X and s.sy > 20 and s.sy < 230 then
            return s
        end
    end

    local best, best_score = nil, -1
    for _, s in ipairs(sprites) do
        if s.sx >= CROWD_PANEL_X then goto continue end
        local m = motion()(s)
        local score = m * 3
        if s.code <= 0x1f and s.code ~= 0x01 and s.code ~= 0x0b then
            score = score + 8
        end
        if s.sy > 20 and s.sy < 230 then score = score + 2 end
        if score > best_score then
            best_score = score
            best = s
        end
        ::continue::
    end
    return best
end

local function find_carrier(sprites, ball)
    local outfield = {}
    for _, s in ipairs(sprites) do
        if is_outfield(s) then outfield[#outfield + 1] = s end
    end
    if #outfield == 0 or not ball then return nil, 9999 end

    local closest, best_d = nil, 9999
    for _, s in ipairs(outfield) do
        local d = dist(s, ball)
        if d < best_d then
            best_d = d
            closest = s
        end
    end

    -- Sin posesión en ataque: portador suele ir detrás del balón hacia nuestra portería
    if best_d > POSSESSION_DIST * 2 and ball.sy < MID_Y then
        for _, s in ipairs(outfield) do
            if s.sy >= ball.sy - 18 and dist(s, ball) < best_d + 24 then
                return s, dist(s, ball)
            end
        end
    end
    return closest, best_d
end

local function read_sprites()
    local all = {}
    for offs = 0, 0x3fc, 4 do
        local b = SPRITE_BASE + offs
        local code = mem:read_u8(b)
        if code ~= 0 then
            local attr = mem:read_u8(b + 1)
            local sx = mem:read_u8(b + 2) + ((attr & 0x20) * 8) - 128
            local sy = mem:read_u8(b + 3)
            all[#all + 1] = { sx = sx, sy = sy, code = code, offs = offs }
        end
    end

    local ball = find_ball(all)
    local carrier, dist_bp = find_carrier(all, ball)

    for _, s in ipairs(all) do
        prev[s.offs] = { sx = s.sx, sy = s.sy }
    end

    local n_players = 0
    for _, s in ipairs(all) do
        if is_outfield(s) then n_players = n_players + 1 end
    end

    return ball, carrier, n_players, dist_bp
end

local function open_log()
    if log then return true end
    os.execute("mkdir -p " .. LOG_DIR)
    log = io.open(LOG_PATH, "w")
    if not log then return false end
    log:write(string.format('{"type":"meta","session":"%s","source":"attract_demo"}\n', SESSION))
    return true
end

local function live_val(field)
    if field and field.live and field.live.value then
        return tonumber(field.live.value) or 0
    end
    return 0
end

emu.register_frame_done(function()
    frame = frame + 1
    if not open_log() then return end

    if frame % 2 == 0 and frame <= RECORD_FRAMES then
        local ball, carrier, n_players, dist_bp = read_sprites()
        local p1x = live_val(fld_p1x)
        local p1y = live_val(fld_p1y)
        local btn = live_val(fld_btn)
        if dist_bp == 9999 then dist_bp = -1 end
        log:write(string.format(
            '{"frame":%d,"phase":"attract","ball":{"x":%d,"y":%d},"player":{"x":%d,"y":%d},"carrier_dist":%d,"players":%d,"input":{"dx":%d,"dy":%d,"btn":%d}}\n',
            frame,
            ball and ball.sx or -1, ball and ball.sy or -1,
            carrier and carrier.sx or -1, carrier and carrier.sy or -1,
            dist_bp,
            n_players,
            p1x, p1y, btn ~= 0 and 1 or 0
        ))
        if frame % 120 == 0 then log:flush() end
    end

    if frame == RECORD_FRAMES then
        log:write('{"type":"end"}\n')
        log:close()
        log = nil
        manager.machine:exit()
    end
end)

local function draw_overlay()
    local screen = manager.machine.screens[":screen"]
    if not screen then return end
    screen:draw_text(4, 4, string.format("REC ATTRACT  %d/%d", frame, RECORD_FRAMES), 0xffffffff, 0xff000000)
end

emu.register_frame_done(draw_overlay)
