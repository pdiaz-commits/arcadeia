-- Tehkan World Cup — CONTROL PROOF (Paso 1)
-- Objetivo: demostrar que fld:set_value en :P1X/:P1Y mueve el sprite.
-- Sin heurística, sin tácticas, sin attract learning.
-- Ver: prompts/tehkan_control_first.md

local ROOT = "/Users/pablo/Documents/arcade-ai"
-- En MAME Lua, `io` global funciona (como en record_attract.lua).
-- NO declarar `local io = ioport` en este archivo.

local LOG_PATH = ROOT .. "/logs/tehkan_control_proof.csv"
local SUMMARY_PATH = "/tmp/tehkan_control_proof.log"

local ioport = manager.machine.ioport
local sys = ioport.ports[":SYSTEM"]
local fld_p1x = ioport.ports[":P1X"] and ioport.ports[":P1X"].fields["Trackball X"]
local fld_p1y = ioport.ports[":P1Y"] and ioport.ports[":P1Y"].fields["Trackball Y"]
local fld_btn = ioport.ports[":P1BUT"] and ioport.ports[":P1BUT"].fields["P1 Button 1"]
local input = manager.machine.input

local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]
local SPRITE_BASE = 0xe800
local CROWD_PANEL_X = 200

local SYS_COIN1 = 0x01
local SYS_START1 = 0x04

local frame = 0
local boot_done = false
local accum_x = 0
local accum_y = 0
local prev_sx, prev_sy = -1, -1
local csv = nil

-- Boot corto fijo (documentado): monedas + starts, luego inyección.
local BOOT_DONE_FRAME = 900
local PROOF_END_FRAME = 1800  -- ~15 s de prueba tras boot
local INJECT_EVERY = 1
local INJECT_DX = 42
local INJECT_DY = -58

local function log_line(path, line)
    pcall(function()
        local f = io.open(path, "a")
        if f then
            f:write(line)
            f:close()
        end
    end)
end

local function press_sys(mask, on)
    if not sys then return end
    local f = sys:field(mask)
    if f then f:set_value(on and 1 or 0) end
end

local function press_key(seq_str, on)
    if not input then return end
    pcall(function()
        if input.seq_from_tokens and input.seq_set_value then
            local seq = input:seq_from_tokens(seq_str)
            if seq then input:seq_set_value(seq, on and 1 or 0) end
        end
    end)
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
                sx = sx, sy = sy, code = code, offs = offs,
            }
        end
    end
    return sprites
end

local function pick_player(sprites)
    -- Heurística mínima: outfield más bajo (suele ser P1 en H1) o
    -- el más cercano al balón code 0x0c.
    local ball = nil
    for _, s in ipairs(sprites) do
        if s.code == 0x0c and s.sx < CROWD_PANEL_X then
            ball = s
            break
        end
    end
    local best, best_score = nil, -1e9
    for _, s in ipairs(sprites) do
        if s.code >= 0x08 and s.sy > 28 and s.sy < 225 and s.sx < CROWD_PANEL_X then
            local score = s.sy
            if ball then
                score = score - (math.abs(s.sx - ball.sx) + math.abs(s.sy - ball.sy)) * 0.5
            end
            if score > best_score then
                best_score = score
                best = s
            end
        end
    end
    return best
end

local function boot_sequence()
    if frame == 120 or frame == 200 or frame == 280 then
        press_sys(SYS_COIN1, true); press_key("KEYCODE_5", true)
    elseif frame == 134 or frame == 214 or frame == 294 then
        press_sys(SYS_COIN1, false); press_key("KEYCODE_5", false)
    elseif frame == 360 or frame == 480 or frame == 600
        or frame == 720 or frame == 840 then
        press_sys(SYS_START1, true); press_key("KEYCODE_1", true)
    elseif frame == 372 or frame == 492 or frame == 612
        or frame == 732 or frame == 852 then
        press_sys(SYS_START1, false); press_key("KEYCODE_1", false)
    elseif frame == BOOT_DONE_FRAME then
        boot_done = true
        accum_x, accum_y = 0, 0
        log_line(SUMMARY_PATH, string.format("[%s] boot_done frame=%d\n", os.date("%H:%M:%S"), frame))
    end
end

local function inject()
    if not fld_p1x or not fld_p1y then return end
    accum_x = accum_x + INJECT_DX
    accum_y = accum_y + INJECT_DY
    fld_p1x:set_value(math.floor(accum_x))
    fld_p1y:set_value(math.floor(accum_y))
    if fld_btn then fld_btn:set_value(0) end
end

local function fld_alive()
    local x = (fld_p1x ~= nil) and 1 or 0
    local y = (fld_p1y ~= nil) and 1 or 0
    local b = (fld_btn ~= nil) and 1 or 0
    return x, y, b
end

-- Init logs
pcall(function()
    local f = io.open(LOG_PATH, "w")
    if f then
        f:write("frame,boot,accum_x,accum_y,player_sx,player_sy,delta_sx,delta_sy,fldx,fldy,fldbtn\n")
        f:close()
    end
    local s = io.open(SUMMARY_PATH, "w")
    if s then
        s:write(string.format("[%s] tehkan_control_proof.lua loaded\n", os.date("%H:%M:%S")))
        s:write(string.format("fields: P1X=%s P1Y=%s P1BUT=%s\n",
            tostring(fld_p1x ~= nil), tostring(fld_p1y ~= nil), tostring(fld_btn ~= nil)))
        s:close()
    end
end)

emu.register_frame_done(function()
    frame = frame + 1

    if not boot_done then
        boot_sequence()
    elseif frame <= PROOF_END_FRAME then
        if frame % INJECT_EVERY == 0 then
            inject()
        end
    end

    local sprites = read_sprites()
    local player = pick_player(sprites)
    local sx, sy = -1, -1
    if player then sx, sy = player.sx, player.sy end
    local dsx, dsy = 0, 0
    if prev_sx >= 0 and sx >= 0 then
        dsx = sx - prev_sx
        dsy = sy - prev_sy
    end
    if sx >= 0 then
        prev_sx, prev_sy = sx, sy
    end

    local fx, fy, fb = fld_alive()
    local row = string.format(
        "%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d\n",
        frame, boot_done and 1 or 0,
        math.floor(accum_x), math.floor(accum_y),
        sx, sy, dsx, dsy, fx, fy, fb
    )
    -- Log cada frame tras boot (volumen OK ~900 líneas)
    if boot_done or frame % 30 == 0 then
        log_line(LOG_PATH, row)
    end

    local screen = manager.machine.screens[":screen"]
    if screen then
        local mode = boot_done and "PROOF↑" or "BOOT"
        screen:draw_text(4, 4,
            string.format("%s f%d ax=%d ay=%d p=%d,%d d=%+d,%+d",
                mode, frame, math.floor(accum_x), math.floor(accum_y),
                sx, sy, dsx, dsy),
            0xffffffff, 0xff000000)
    end

    if frame == PROOF_END_FRAME then
        log_line(SUMMARY_PATH, string.format("[%s] proof_end frame=%d — exiting MAME\n",
            os.date("%H:%M:%S"), frame))
        pcall(function() manager.machine:exit() end)
    end
end)
