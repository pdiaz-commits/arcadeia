-- Graba partida humana → logs/demos/*.jsonl (sin socket)

local ROOT = "/Users/pablo/dossier/arcade-ai"
local LOG_DIR = ROOT .. "/logs/demos"
local SESSION = os.date("session_%Y%m%d_%H%M%S")
local LOG_PATH = LOG_DIR .. "/" .. SESSION .. ".jsonl"
local FRAME_FILE = LOG_DIR .. "/current_frame.txt"
local SESSION_FILE = LOG_DIR .. "/current_session.txt"

local io_ports = manager.machine.ioport
local fld_p1x = io_ports.ports[":P1X"].fields["Trackball X"]
local fld_p1y = io_ports.ports[":P1Y"].fields["Trackball Y"]
local fld_btn = io_ports.ports[":P1BUT"].fields["P1 Button 1"]

local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]
local SPRITE_BASE = 0xe800

local frame = 0
local log = nil

local function open_log()
    if log then return true end
    os.execute("mkdir -p " .. LOG_DIR)
    log = io.open(LOG_PATH, "w")
    if not log then return false end
    local idx = io.open(SESSION_FILE, "w")
    if idx then
        idx:write(LOG_PATH .. "\n")
        idx:close()
    end
    return true
end

local function read_ball_player()
    local ball, player = nil, nil
    local best_d = 9999
    for offs = 0, 0x3fc, 4 do
        local b = SPRITE_BASE + offs
        local code = mem:read_u8(b)
        if code ~= 0 then
            local attr = mem:read_u8(b + 1)
            local sx = mem:read_u8(b + 2) + ((attr & 0x20) * 8) - 128
            local sy = mem:read_u8(b + 3)
            if code <= 0x1f then
                ball = { sx = sx, sy = sy }
            end
            if code >= 0x08 and sy > 28 and sy < 225 then
                local d = ball and (math.abs(sx - ball.sx) + math.abs(sy - ball.sy)) or sy
                if d < best_d then
                    best_d = d
                    player = { sx = sx, sy = sy }
                end
            end
        end
    end
    return ball, player
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

    if frame % 2 == 0 then
        local ball, player = read_ball_player()
        log:write(string.format(
            '{"frame":%d,"ball":{"x":%d,"y":%d},"player":{"x":%d,"y":%d},"input":{"dx":%d,"dy":%d,"btn":%d}}\n',
            frame,
            ball and ball.sx or -1, ball and ball.sy or -1,
            player and player.sx or -1, player and player.sy or -1,
            live_val(fld_p1x), live_val(fld_p1y),
            live_val(fld_btn) ~= 0 and 1 or 0
        ))
        if frame % 60 == 0 then log:flush() end
    end

    local ff = io.open(FRAME_FILE, "w")
    if ff then
        ff:write(tostring(frame))
        ff:close()
    end
end)

local function draw_overlay()
    local screen = manager.machine.screens[":screen"]
    if not screen then return end
    local tag = log and "REC+TEACH" or "REC ERROR"
    screen:draw_text(4, 4, string.format("%s  frame %d", tag, frame), 0xffffffff, 0xff000000)
end

emu.register_frame_done(draw_overlay)
