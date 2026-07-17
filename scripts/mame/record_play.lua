-- Graba TU partida humana → logs/demos/*.jsonl
-- El trackball lo controla MAME nativo via flag -trackball_device keyboard
-- (flechas / Z X A S). También funciona con ratón (-mouse en teach_session.sh).

local ROOT = "/Users/pablo/Documents/arcade-ai"
local LOG_DIR = ROOT .. "/logs/demos"
local SESSION = os.date("session_%Y%m%d_%H%M%S")
local LOG_PATH = LOG_DIR .. "/" .. SESSION .. ".jsonl"
local FRAME_FILE = LOG_DIR .. "/current_frame.txt"
local SESSION_FILE = LOG_DIR .. "/current_session.txt"

local io_ports = manager.machine.ioport
local sys = io_ports.ports[":SYSTEM"]
local fld_p1x = io_ports.ports[":P1X"].fields["Trackball X"]
local fld_p1y = io_ports.ports[":P1Y"].fields["Trackball Y"]
local fld_btn = io_ports.ports[":P1BUT"].fields["P1 Button 1"]

local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]
local SPRITE_BASE = 0xe800
local CROWD_PANEL_X = 200

local frame = 0
local log = nil
local boot_done = false
local function press_sys(mask, on)
    local f = sys:field(mask)
    if f then f:set_value(on and 1 or 0) end
end

local function boot_sequence()
    if frame == 90 then press_sys(0x01, true)
    elseif frame == 104 then press_sys(0x01, false)
    elseif frame == 150 then press_sys(0x04, true)
    elseif frame == 162 then press_sys(0x04, false)
    elseif frame == 300 then press_sys(0x04, true)
    elseif frame == 312 then press_sys(0x04, false)
    elseif frame == 520 then boot_done = true
    end
end

local function open_log()
    if log then return true end
    os.execute("mkdir -p " .. LOG_DIR)
    log = io.open(LOG_PATH, "w")
    if not log then return false end
    log:write('{"type":"meta","session":"' .. SESSION .. '","source":"human_teaching"}\n')
    local idx = io.open(SESSION_FILE, "w")
    if idx then
        idx:write(LOG_PATH .. "\n")
        idx:close()
    end
    return true
end

local function read_ball_player()
    local balls, outfield = {}, {}
    for offs = 0, 0x3fc, 4 do
        local b = SPRITE_BASE + offs
        local code = mem:read_u8(b)
        if code ~= 0 then
            local attr = mem:read_u8(b + 1)
            local sx = mem:read_u8(b + 2) + ((attr & 0x20) * 8) - 128
            local sy = mem:read_u8(b + 3)
            if code == 0x0c and sx < CROWD_PANEL_X and sy > 24 and sy < 228 then
                balls[#balls + 1] = { sx = sx, sy = sy }
            end
            if code >= 0x08 and sy > 28 and sy < 225 and sx < CROWD_PANEL_X then
                outfield[#outfield + 1] = { sx = sx, sy = sy }
            end
        end
    end
    local ball = balls[1]
    local player = nil
    if ball then
        local best_d = 9999
        for _, p in ipairs(outfield) do
            local d = math.abs(p.sx - ball.sx) + math.abs(p.sy - ball.sy)
            if d < best_d then best_d, player = d, p end
        end
    elseif #outfield > 0 then
        player = outfield[1]
    end
    return ball, player
end

local function live_val(field)
    if field and field.live and field.live.value then
        return tonumber(field.live.value) or 0
    end
    return 0
end

local function direction_label(dx, dy)
    if dx == 0 and dy == 0 then return "—" end
    local parts = {}
    if dy < -8 then parts[#parts + 1] = "↑"
    elseif dy > 8 then parts[#parts + 1] = "↓" end
    if dx < -8 then parts[#parts + 1] = "←"
    elseif dx > 8 then parts[#parts + 1] = "→" end
    if #parts == 0 then return "~" end
    return table.concat(parts)
end

emu.register_frame_done(function()
    frame = frame + 1
    if not boot_done then
        boot_sequence()
    end

    -- El trackball lo controla MAME nativo vía trackball_device=keyboard
    -- (configurado en teach_session.sh). El script solo LEE y graba.

    if not open_log() then return end

    local ball, player = read_ball_player()
    local dx = live_val(fld_p1x)
    local dy = live_val(fld_p1y)
    local btn = live_val(fld_btn) ~= 0 and 1 or 0

    log:write(string.format(
        '{"frame":%d,"ball":{"x":%d,"y":%d},"player":{"x":%d,"y":%d},"input":{"dx":%d,"dy":%d,"btn":%d}}\n',
        frame,
        ball and ball.sx or -1, ball and ball.sy or -1,
        player and player.sx or -1, player and player.sy or -1,
        dx, dy, btn
    ))
    if frame % 30 == 0 then log:flush() end

    local ff = io.open(FRAME_FILE, "w")
    if ff then
        ff:write(tostring(frame))
        ff:close()
    end

    local screen = manager.machine.screens[":screen"]
    if screen then
        local tag = boot_done and "REC+TEACH" or "INSERT COIN..."
        local hint = "Mantén diagonal: ↑← ↑→  o ratón"
        screen:draw_text(4, 4, string.format("%s f%d %s", tag, frame, direction_label(dx, dy)), 0xffffffff, 0xff000000)
        screen:draw_text(4, 16, hint, 0xffccff66, 0xff000000)
    end
end)
