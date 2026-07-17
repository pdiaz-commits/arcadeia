-- Tehkan World Cup — driver para entorno Gym (entrenamiento RL)
-- Protocolo TCP: heartbeat por frame_done (obs JSON), recibe accion JSON y
-- la inyecta via trackball. Mantiene la "diagonal sostenida" (HOLD_MIN frames)
-- para que el arcade registre el empuje como trackball real.
--
-- Variables de entorno que pone Python antes de lanzar MAME:
--   ARCAIDEIA_LUA_HOST  (def. 127.0.0.1)
--   ARCAIDEIA_LUA_PORT  (def. 9878)
--   ARCAIDEIA_LUA_NAME  (def. tehkan_learn)

local ROOT = os.getenv("ARCAIDEIA_ROOT") or "/Users/pablo/Documents/arcade-ai"
local HOST = os.getenv("ARCAIDEIA_LUA_HOST") or "127.0.0.1"
local PORT = tonumber(os.getenv("ARCAIDEIA_LUA_PORT")) or 9878
local NAME = os.getenv("ARCAIDEIA_LUA_NAME") or "tehkan_learn"

-- Intenta cargar luasocket — aborta con mensaje claro si MAME 0.288 no lo trae compilado.
local ok_socket, socket = pcall(require, "socket")
if not ok_socket then
    error("Falta modulo 'socket' en MAME Lua. Compila MAME con luasocket o usa FIFO fallback.")
end

local TB = (function()
    local chunk = loadfile(ROOT .. "/scripts/mame/tehkan_trackball.lua")
    if chunk then return chunk() end
    if dofile then return dofile(ROOT .. "/scripts/mame/tehkan_trackball.lua") end
    error("tehkan_trackball.lua missing")
end)()

local SPRITE_BASE      = 0xe800
local CROWD_PANEL_X    = 200
local FIELD_Y_MIN      = 24
local FIELD_Y_MAX      = 228
local OPP_GOAL_Y       = 36   -- porteria rival arriba
local OUR_GOAL_Y       = 200  -- nuestra porteria abajo
local MID_Y            = 112
local CENTER_X         = 128

local BALL_CODE        = 0x0c
local POSSESSION_DIST  = 28

local HOLD_MIN = 18  -- frames minimos para que el trackball registre la diagonal

local sys        = manager.machine.ioport.ports[":SYSTEM"]
local fld_p1x    = manager.machine.ioport.ports[":P1X"].fields["Trackball X"]
local fld_p1y    = manager.machine.ioport.ports[":P1Y"].fields["Trackball Y"]
local fld_btn    = manager.machine.ioport.ports[":P1BUT"].fields["P1 Button 1"]
local cpu        = manager.machine.devices[":maincpu"]
local mem        = cpu.spaces["program"]

-- score: TODO hunts via MAME debugger. Mientras tanto, fallback por sprite ball
-- cruzando porterias. Reemplazar estas dos constantes con las direcciones
-- reales una vez se haga el `find /,10000,<us>` / `<them>` (ver README).
local SCORE_US_ADDR  = nil  -- p.ej. 0xc4a0
local SCORE_THEM_ADDR = nil -- p.ej. 0xc4a1

local input = manager.machine.input

local frame = 0
local game_frames = 0
local boot_done = false
local phase = "boot"
local tcp = nil
local last_ball = { x = nil, y = nil, age = 0, valid = 0 }
local last_player = { x = nil, y = nil, age = 0, valid = 0 }
local hold = { dx = 0, dy = 0, kick = 0, frames_left = 0 }

local SYS_COIN1  = 0x01
local SYS_START1 = 0x04

-- ------------------------------------------------------------------
-- Boot arcade: inserta moneda, start, espera a que begin. Replica el
-- timing de tehkanwc_ai.lua (frames 90 / 150 / 300 / 450 -> boots 520)
-- ------------------------------------------------------------------
local function press_sys(mask, on)
    local f = sys:field(mask)
    if f then f:set_value(on and 1 or 0) end
end

local function force_freeplay()
    pcall(function()
        local coin_a = manager.machine.ioport.ports[":DSW2"].fields["Coin A"]
        if coin_a then coin_a:set_value(7) end
    end)
end

local function boot_sequence()
    if frame == 1 then force_freeplay() end
    if frame == 90 then
        press_sys(SYS_COIN1, true)
    elseif frame == 104 then
        press_sys(SYS_COIN1, false)
    elseif frame == 150 then
        press_sys(SYS_START1, true)
    elseif frame == 162 then
        press_sys(SYS_START1, false)
    elseif frame == 300 then
        press_sys(SYS_START1, true)
    elseif frame == 312 then
        press_sys(SYS_START1, false)
    elseif frame == 450 then
        press_sys(SYS_START1, true)
    elseif frame == 462 then
        press_sys(SYS_START1, false)
    elseif frame == 520 then
        boot_done = true
        phase = "play"
    end
end

-- ------------------------------------------------------------------
-- Lectura de sprites (replica tehkanwc_ai.lua con persistencia para
-- evitar flicker — el agente PPO necesita obs estables).
-- ------------------------------------------------------------------
local function dist(a, b)
    return math.abs(a.sx - b.sx) + math.abs(a.sy - b.sy)
end

local function decode_sprite(offs)
    local base = SPRITE_BASE + offs
    local code = mem:read_u8(base)
    if code == 0 then return nil end
    local attr = mem:read_u8(base + 1)
    local sx   = mem:read_u8(base + 2) + ((attr & 0x20) * 8) - 128
    local sy   = mem:read_u8(base + 3)
    return { sx = sx, sy = sy, code = code, offs = offs }
end

local function read_sprites()
    local all = {}
    for offs = 0, 0x3fc, 4 do
        local s = decode_sprite(offs)
        if s then all[#all + 1] = s end
    end
    return all
end

local function on_field(s)
    return s.sx < CROWD_PANEL_X and s.sy > FIELD_Y_MIN and s.sy < FIELD_Y_MAX
end

local function find_ball(sprites)
    for _, s in ipairs(sprites) do
        if s.code == BALL_CODE and on_field(s) then
            return s
        end
    end
    return nil
end

local function find_player(sprites, ball)
    local outfield = {}
    for _, s in ipairs(sprites) do
        if s.code >= 0x08 and s.sy > 28 and s.sy < 225 and s.sx < CROWD_PANEL_X then
            outfield[#outfield + 1] = s
        end
    end
    if #outfield == 0 then return nil end
    if not ball then
        local best = outfield[1]
        for _, s in ipairs(outfield) do
            if s.sy > best.sy then best = s end
        end
        return best
    end
    local best, best_d = nil, 9999
    for _, p in ipairs(outfield) do
        local d = dist(p, ball)
        if d < best_d then best_d, best = d, p end
    end
    return best
end

-- ------------------------------------------------------------------
-- TCP connection con reintentos. Bloqueamos el emu thread hasta que
-- conecte — eso garantiza handshake antes del primer frame "play".
-- ------------------------------------------------------------------
local function connect_tcp()
    local attempt = 0
    while not tcp do
        attempt = attempt + 1
        local s = socket.tcp()
        s:settimeout(2)
        local ok, err = s:connect(HOST, PORT)
        if ok == 1 then
            s:settimeout(0)
            tcp = s
            return true
        end
        s:close()
        if attempt > 60 then
            error(string.format("tehkan_learn: no pude conectar %s:%d tras %d intentos (%s)",
                HOST, PORT, attempt, tostring(err)))
        end
        -- emu.wait no existe en MAME's embedded Lua; socket.sleep si.
        socket.sleep(0.25)
    end
    -- En lockstep la latencia de Nagle duele; desactiva Nagle.
    pcall(function() tcp:setoption("tcp-nodelay", true) end)
    return true
end

local function send_json(obj)
    if not tcp then return false end
    -- JSON minimo: solo ints/bool/strings — evitamos dependencias.
    local parts = {}
    parts[#parts + 1] = string.format('{"type":"%s"', obj.type)
    if obj.frame then parts[#parts + 1] = string.format(',"frame":%d', obj.frame) end
    if obj.phase then parts[#parts + 1] = string.format(',"phase":"%s"', obj.phase) end
    if obj.dx ~= nil then parts[#parts + 1] = string.format(',"dx":%d', obj.dx) end
    if obj.dy ~= nil then parts[#parts + 1] = string.format(',"dy":%d', obj.dy) end
    if obj.kick ~= nil then parts[#parts + 1] = string.format(',"kick":%s', obj.kick and "true" or "false") end
    parts[#parts + 1] = "}\n"
    local payload = table.concat(parts)
    local ok = tcp:send(payload)
    if ok == nil then
        -- Server se fue (MAME murio / puerto cerrado). Forzar cerrado.
        tcp:close()
        tcp = nil
        return false
    end
    return true
end

local function recv_action()
    if not tcp then return nil end
    -- Bloqueante: MAME espera la accion antes del siguiente frame_done.
    local line, err = tcp:receive("*l")
    if not line then
        tcp:close()
        tcp = nil
        return nil
    end
    -- Parser minimalista — campos esperados: dx, dy, kick.
    local dx = tonumber(line:match('"dx"%s*:%s*(-?%d+)')) or 0
    local dy = tonumber(line:match('"dy"%s*:%s*(-?%d+)')) or 0
    local kick_raw = line:match('"kick"%s*:%s*(%a+)')
    local kick = kick_raw == "true"
    local cmd = line:match('"cmd"%s*:%s*"(%w+)"')
    if cmd == "quit" then
        emu.register_stop(function() end)
        manager.machine:exit()
    end
    if cmd == "reset" then
        -- Reset solicitado por Python: forzamos re-arranque del boot.
        boot_done = false
        frame = 0
        game_frames = 0
        phase = "boot"
    end
    return { dx = dx, dy = dy, kick = kick }
end

-- ------------------------------------------------------------------
-- Inyeccion con hold sostenido (sin esto, un tap = 0 movimiento).
-- ------------------------------------------------------------------
local function apply_action(raw_dx, raw_dy, kick)
    if raw_dx ~= 0 or raw_dy ~= 0 or kick then
        hold.dx = raw_dx
        hold.dy = raw_dy
        hold.kick = kick and 1 or 0
        hold.frames_left = HOLD_MIN
    elseif hold.frames_left > 0 then
        hold.frames_left = hold.frames_left - 1
    else
        hold.dx, hold.dy, hold.kick = 0, 0, 0
    end
    fld_p1x:set_value(hold.dx)
    fld_p1y:set_value(hold.dy)
    fld_btn:set_value(hold.kick)
end

-- ------------------------------------------------------------------
-- Lectura de score RAM (si tenemos direcciones). Fallback a sprite.
-- ------------------------------------------------------------------
-- Distincion explicita score_unknown=0 (enviar 0 al env hasta cazar las
-- direcciones en lugar de -1 que envenenaba la obs de PPO).
local function read_score()
    if not SCORE_US_ADDR then return 0 end
    local v = mem:read_u8(SCORE_US_ADDR)
    return v or 0
end

local function read_score_them()
    if not SCORE_THEM_ADDR then return 0 end
    local v = mem:read_u8(SCORE_THEM_ADDR)
    return v or 0
end

-- ------------------------------------------------------------------
-- Construccion del heartbeat JSON. Mantener el orden de campos estable
-- porque Python usa posiciones implicitas en obs_to_array si quisiéramos
-- pero de hecho parsea por keys.
-- ------------------------------------------------------------------
local function emit_obs(ball, player)
    -- Ball con persistencia (flicker < 5 frames se rellena con last_ball).
    local bx, by, bvalid
    if ball then
        bx, by, bvalid = ball.sx, ball.sy, 1
        last_ball.x, last_ball.y, last_ball.age, last_ball.valid = bx, by, 0, 1
    elseif last_ball.valid == 1 and last_ball.age < 5 then
        bx, by, bvalid = last_ball.x, last_ball.y, 0
        last_ball.age = last_ball.age + 1
    else
        bx, by, bvalid = 128, MID_Y, 0
    end

    local px, py, pvalid
    if player then
        px, py, pvalid = player.sx, player.sy, 1
        last_player.x, last_player.y, last_player.age, last_player.valid = px, py, 0, 1
    elseif last_player.valid == 1 and last_player.age < 5 then
        px, py, pvalid = last_player.x, last_player.y, 0
        last_player.age = last_player.age + 1
    else
        px, py, pvalid = 128, MID_Y, 0
    end

    local possessed = (bvalid == 1 and pvalid == 1)
        and (math.abs(bx - px) + math.abs(by - py) < POSSESSION_DIST)
        or false
    local in_attack = bvalid == 1 and by < MID_Y
    local near_shoot_zone = pvalid == 1 and bvalid == 1
        and py < OPP_GOAL_Y + 32 and math.abs(px - CENTER_X) < 60

    -- goal_detect por sprite: util hasta cazar direcciones RAM.
    local goal_event = "none"
    if bvalid == 1 then
        if by < OPP_GOAL_Y + 6 then goal_event = "us"
        elseif by > OUR_GOAL_Y - 6 then goal_event = "them" end
    end

    local parts = {
        '{"type":"obs"',
        string.format(',"frame":%d', frame),
        string.format(',"phase":"%s"', phase),
        string.format(',"ball":{"x":%d,"y":%d,"valid":%d}', bx, by, bvalid),
        string.format(',"player":{"x":%d,"y":%d,"valid":%d}', px, py, pvalid),
        string.format(',"possessed":%s', possessed and "true" or "false"),
        string.format(',"in_attack":%s', in_attack and "true" or "false"),
        string.format(',"near_shoot_zone":%s', near_shoot_zone and "true" or "false"),
        string.format(',"score_us":%d', read_score()),
        string.format(',"score_them":%d', read_score_them()),
        string.format(',"goal_event":"%s"', goal_event),
    }
    parts[#parts + 1] = "}\n"
    return table.concat(parts)
end

-- ------------------------------------------------------------------
-- Overlay debug (no afecta entrenamiento; solo ayuda visual en local).
-- ------------------------------------------------------------------
local function draw_overlay()
    local ok, screen = pcall(function() return manager.machine.screens[":screen"] end)
    if not ok or not screen then return end
    pcall(function()
        screen:draw_text(4, 4,
            string.format("tehkan_learn  f%d  %s  port=%s:%d",
                frame, phase, HOST, PORT),
            0xffffffff, 0xff000000)
    end)
end

-- ------------------------------------------------------------------
-- Handshake inicial: nada se hace hasta que el server acepta.
-- ------------------------------------------------------------------
connect_tcp()
-- Handshake — Python lo usa para saber que MAME esta listo.
send_json({ type = "hello", frame = 0, phase = "boot" })

-- ------------------------------------------------------------------
-- Loop principal: ejecuta el boot hasta phase=play, despues un
-- send+recv por frame para mantener lockstep perfecto.
-- ------------------------------------------------------------------
emu.register_frame_done(function()
    frame = frame + 1

    if not boot_done then
        boot_sequence()
        draw_overlay()
        -- Mientras el server este vivo, mandamos heartbeat pero NO
        -- esperamos accion (no queremos enganchar antes de empezar a jugar).
        if tcp then
            local s = read_sprites()
            local ball = find_ball(s)
            local player = find_player(s, ball)
            local _ = emit_obs(ball, player)
            tcp:send(_)
        end
        return
    end

    -- Phase play: send obs, block hasta recibir accion.
    if not tcp then connect_tcp() end

    local sprites = read_sprites()
    local ball = find_ball(sprites)
    local player = find_player(sprites, ball)
    local payload = emit_obs(ball, player)
    tcp:send(payload)

    local action = recv_action()
    if action then
        apply_action(action.dx, action.dy, action.kick)
    end
    game_frames = game_frames + 1
    draw_overlay()
end)
