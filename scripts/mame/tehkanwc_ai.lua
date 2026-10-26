-- Tehkan World Cup (tehkanwc, 1985) — agente trackball v18.0 MINIMAL
-- v18.0 — fix REAL de 8 iteraciones fallidas.
-- v17.2–v17.7 atacaron la cascade + accumulator + wrap-around, pero el
-- root cause estaba en mame.ini línea 151: `trackball_device keyboard`.
-- Con esa config, MAME hace polling de flechas cada frame y SOBREESCRIBE
-- el set_value() que hacíamos en frame_done, cancelando la IA. v18.0:
-- 1) mame.ini ahora tiene `trackball_device none` (el polling del
--    teclado ya no pisa nuestros valores).
-- 2) Cascade en 2 ramas (sin SHOOT, sin set-pieces, sin chase de
--    predicción) — solo lo que el usuario pidió:
--      - CON BALÓN → correr en diagonal hacia arriba A TOPE sin parar.
--      - SIN BALÓN → perseguir balón al destino actual.
--    dx = ±42 según banda (siempre hacia poste lejano),
--    dy = -SPRINT = -58 (siempre hacia arriba en H1).
-- 3) Logger CSV arranca en frame 1 (no espera a boot_done) para
--    probar EMPÍRICAMENTE que el script ejecuta. Antes el diag solo
--    escribía post-boot y nunca llegó a escribir nada.
-- 4) Imports tolerantes a fallo (`or error()` mataba el script en
--    silencio si un módulo cambiaba de path).

-- v18.0 PROOF-OF-EXECUTION — primer log antes de cualquier lógica.
-- Si este archivo existe, el script fue cargado por MAME.
pcall(function()
    local f = io.open("/tmp/tehkan_boot.log", "a")
    if f then
        f:write("[" .. os.date("%H:%M:%S") .. "] tehkanwc_ai.lua v18.0 cargó OK\n")
        f:close()
    end
end)

-- v18.1 — ONE-OFF INJECTION TEST en frame 250 (antes de boot_done).
-- Escribe un set_value MASIVO (+5000) UNA vez. Si el sprite del
-- jugador salta visiblemente a la derecha (o el cursor del menú se
-- desplaza), confirma que el pathway Lua→MAME→CPU est\u00e1 vivo.
-- Si nada cambia, el problema no es el c\u00e1lculo de deltas sino la
-- tuber\u00eda entera (MAME ignora set_value al port IPT_TRACKBALL_X).
-- BUGFIX v18.1: usa write_at(0xe800) en lugar de KEYCODE porque
-- algunos drivers mapean las teclas a set_value hooks.
local ONE_OFF_DONE = false
local function one_off_injection_test()
    if ONE_OFF_DONE or frame ~= 250 then return end
    ONE_OFF_DONE = true
    -- Conservador: NO salimos del casillero del jugador; inyectamos
    -- SUFICIENTE delta para que se vea un jitter claro en pantalla.
    -- 100 = ~2 frames de full sprint (58/frame) en el eje X.
    pcall(function()
        fld_p1x:set_value(100)
        fld_p1y:set_value(0)
    end)
    pcall(function()
        local f = io.open("/tmp/tehkan_oneoff.log", "a")
        if f then f:write("frame 250: one_off X=100 Y=0 inyectado\n"); f:close() end
    end)
end

-- v17.7: bug gameplay REAL finalmente resuelto.
-- v17.6 introdujo accumulator de deltas en tehkan_trackball.lua pero
-- wrap-around a 8-bit (-128..+127) era el bug REAL: cuando accum_x
-- cruzaba +127 con +42, accumulator wrapeaba a -87, MAME veía
-- set_value(+127) → set_value(-87), calculaba delta = -214
-- (¡huge en dirección opuesta!), y su anti-glitch clamp rechazaba
-- el delta. Resultado visible: cero movimiento (porque el wrap
-- ocurría cada ~3 frames). v17.7 elimina el wrap completamente:
-- Lua doubles acumulan sin overflow (53-bit precision), MAME maneja
-- el contador 32-bit con propia lógica de overflow correcta.
-- v17.6 también fallido (mismo síntoma, distinta causa: wrap).
-- v17.5/v17.4/v17.3/v17.2: sin accumulator, set_value(42) cada frame
-- producía delta=0 → sprite congelado.
--
-- Una vez resuelto el accumulator, el cascade vuelve a la forma
-- limpia v17.3 (sin hacks de kick=true): el dribble Tehkan es
-- trackball + sprite solapando balón mientras corres, no requiere
-- botón chut mantenido. v17.6 = v17.3 cascade + v17.6 trackball fix.
--
-- Histórico:
-- v17.5: pulsed kick '(frame % 4 == 0)' (era teatro).
-- v17.4: continuous kick=true (era teatro).
-- v17.3: PUSH↑ con chase_dx (sin moverse realmente).
-- v17.2: DIAG↑ con dx fijo (sin moverse realmente).
-- v17.1: auto-gol H2 mitigado (HALF_FRAMES 2700→27000).
-- v17.1: auto-gol del swap H2 mitigado (HALF_FRAMES 2700→27000, TACKLE_DX/DY
-- 22→8, RETREAT_BAND 144→180) tras jugar "fatal" en v16.4.
-- v17.0 = v16.4: bugfixes de boot (goto::continue:: rechazado por parser
-- MAME 0.288, refactor a condiciones positivas anidadas).
-- v16: set-piece routines (kickoff/corner/goal-kick/throw-in) + half-time
-- symmetry + detección de marcador. Antes el agente seguía atacando
-- arriba (nuestra portería en H2) tras el cambio de campos y todos los
-- saques se trataban como chase genérico. v16 corrige ambos.
-- v15: 13 reglas expertas inyectadas via learned_tactics.lua.
-- v14: predicción de trayectoria del balón — cuando el balón se mueve
-- rápido (motion > PRED_MIN_MOTION), chase_ball apunta a la posición
-- extrapolada 4 frames en el futuro en lugar de la posición actual.
-- Esto permite interceptar pases largos y centros en vez de perseguir
-- detrás del balón.
-- v14.2: bugfix — el typo CENTER_CENTER or CENTER_X (en chase_ball)
-- rompía la rama `if dx==0` y la función no devolvía nada para algunos
-- paths. Ahora corrigido.
-- v14.1: bugfix — predict_ball retorna tabla {bx, by}, antes era
-- multi-return que se desempaquetaba mal con `predicted[1]`.
-- v13.2: PANIC_DUMP invertía banda cuando el rival bloqueaba dirección.
-- v13.1: filtra a NUESTRO GK (sy>=168) de la lista de rivales.
-- v13: conciencia de rivales (PANIC/DODGE/RETREAT/ATR-guard).
-- v12: fusión de attract_tactics.lua + learned_tactics.lua.
-- Diagonal MANTENIDA varios frames. Inyección en frame_done.

local ROOT = "/Users/pablo/Documents/arcade-ai"
local AGENT = "heuristic"

local function load_lua_module(path)
    local chunk = loadfile(path)
    if chunk then return chunk() end
    if dofile then return dofile(path) end
    return nil
end

local TB = load_lua_module(ROOT .. "/scripts/mame/tehkan_trackball.lua") or error("tehkan_trackball.lua missing")
-- v18.0: TL tolerante a fallo. Antes `or error(...)` mataba el script
-- en silencio si el módulo cambiaba. Ahora fallback a tabla vacía —
-- el agente puede correr sin tactics (actuacion levemente peor pero
-- no se queda TOTO).
local TL = load_lua_module(ROOT .. "/scripts/mame/tehkan_tactics_loader.lua") or {}
if type(TL) ~= "table" then TL = {} end

local io = manager.machine.ioport
local sys = io.ports[":SYSTEM"]
local fld_p1x = io.ports[":P1X"].fields["Trackball X"]
local fld_p1y = io.ports[":P1Y"].fields["Trackball Y"]
local fld_btn = io.ports[":P1BUT"].fields["P1 Button 1"]

-- Forward decl: handle_set_pieces / cascade call apply_input before its body.
local apply_input

local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]
local SPRITE_BASE = 0xe800

local OPP_GOAL_X = 128
local OPP_GOAL_Y = 36
local OUR_GOAL_Y = 200
local MID_Y = 112
local CENTER_X = 128
local CENTER_Y = 112

local SPRINT = TB.SPRINT
local MAX_DELTA = TB.MAX_DELTA

local POSSESSION_DIST = 50
local CHASE_DIST = 60
local CROWD_PANEL_X = 200
local FIELD_Y_MIN = 24
local FIELD_Y_MAX = 228
local SHOOT_MAX_Y = 74
local SHOOT_MAX_X_OFF = 46

-- Conciencia de rivales (enseñanza v13): el agente antes ignoraba a los
-- sprites outfield no-jugador, perdiendo el balón cada ~2s en línea recta.
-- Asume cualquier sprite no-player como amenaza potencial: en Tehkan
-- ambos equipos comparten paleta y sin leer color RAM no hay forma
-- barata de distinguirlos. Sin embargo, los falsos positivos (confundir
-- un teammate con rival) hacen que PANIC/RETREAT/DODGE se disparen
-- contra nuestros propios defensas. v17.1 los calibra:
-- - Caja de tackle mucho más pequeña (TACKLE_DX de 22→8, DY de 18→6):
--   antes cubría 1500 px² y atrapaba al compañero más cercano; ahora
--   64 px² solo para tackles reales cuerpo-a-cuerpo.
-- - RETREAT_BAND de 144→180: ya no huye cuando un teammate cruza
--   mediocampo; solo dispara en el tercio defensivo, donde de verdad
--   tiene sentido volver a cubrir portería.
--
-- v17.2: simplificación radical ordenada por el usuario —
-- "coger balón / hacer falta si no lo tiene / correr diagonal / máximo diagonal /
--  acercarse a portería rival". Cascada a 3 ramas:
-- 1. INTERCEPT  — sin balón, corre a por él (chase_ball). Full sprint.
-- 2. DIAG↑    — con balón, corre en diagonal hacia portería rival (45°).
-- 3. SHOOT    — con balón en zona de tiro, chuta.
-- Eliminadas: PANIC espurio, RETREAT, DODGE lateral, ATR aprendido
-- (que venía de un longplay de YouTube y es demasiado conservador
-- en mediocampo). Esto es heurística amiga de la velocidad, no amiga
-- de la táctica.
local DIAG_DX            = 42  -- componente lateral en diagonal (45° robusto)
local DIAG_DY            = 42  -- componente hacia portería rival (attenuado a 45° vs SPRINT=58)
local THREAT_SCAN_DX     = 38  -- (legacy, mantenido por compatibilidad)
local THREAT_SCAN_DY     = 28
local TACKLE_DX          = 8   -- legado (PANIC ya no se dispara en cascada v17.2)
local TACKLE_DY          = 6
local PANIC_KICK         = true
local DODGE_OFFSET       = 26
local RETREAT_BAND       = 180
local GK_MIN_Y           = 168

-- v17.1 — Auto-gol del medio tiempo (BLOQUEANTE):
-- El swap H1→H2 disparado por `game_frames > HALF_FRAMES` con 2700 era
-- demasido pronto: las animaciones de gol/saque/intro consumen frames
-- sin que avance el tiempo real de partido, así que el swap se
-- activaba durante H1 y el agente empezaba a tirar a SU PROPIA
-- portería. Subimos el umbral a 27000 (~7.5 min reales) — más alla de
-- cualquier partido posible. H2 detection fiable requiere leer
-- color RAM y estado de scoreboard, lo dejamos para v18.
local HALF_FRAMES        = 27000
local GOALKICK_BAND      = 25  -- sy dentro de ±25 de OUR_GOAL_Y → goal kick
local HUD_BYTE_BASE      = 0xe880
local KICKOFF_TOL_X      = 10
local KICKOFF_TOL_Y      = 10
local KICKOFF_STREAK_MIN = 10  -- frames consecutivos en el círculo central
local KICKOFF_TIMEOUT    = 60  -- ~1s sobre umbral: liberar control
local CORNER_MARGIN_X    = 30
local CORNER_MARGIN_Y    = 56
local THROWIN_Y_MAX      = 30
local THROWIN_Y_BOT      = 230

local SYS_COIN1  = 0x01
local SYS_START1 = 0x04

local input = manager.machine.input
local frame = 0
local game_frames = 0
local boot_done = false
local prev = {}
local debug_pos = ""
local phase = "boot"
local hold = TB.new_hold_state(22)

-- v16: estado dinámico del partido. `half` controla la simetría
-- de campos (Tehkan WC cambia equipos en el descanso). `kickoff_streak`
-- detecta el saque inicial. `set_phase` se asigna cuando un set-piece
-- toma el control del act_heuristic y se muestra en overlay. `us_score`
-- / `them_score` solo se usan si `score_valid = true` (HUD dígitos
-- legítimos en sprite RAM 0xe880).
local half = 1
local kickoff_streak = 0
local set_phase = nil
local us_score = 0
local them_score = 0
local score_valid = false
local last_hud_check_frame = 0

-- Carga reglas de DOS pipelines con prioridad: LEARNED (demos humanos
-- -> scripts/learn_from_demos.py -> learned_tactics.lua) tiene prioridad
-- sobre ATTRACT (demo arcade -> scripts/learn_from_attract.py ->
-- attract_tactics.lua). Bug histórico: v12+ solo cargaba attract_tactics,
-- ignorando los goles marcados por el humano durante la enseñanza.
local TACTICS = (function()
    if not TL then return {} end
    local ok, tactics = pcall(TL.load_combined, ROOT)
    if ok and type(tactics) == "table" then return tactics end
    return {}
end)()
local TACTICS_LEARNED_N = 0
pcall(function()
    local learned = TL.try_load and TL.try_load(
        ROOT .. "/scripts/mame/learned_tactics.lua") or {}
    if type(learned) == "table" then TACTICS_LEARNED_N = #learned end
end)

local function press_sys(mask, on)
    local f = sys:field(mask)
    if f then f:set_value(on and 1 or 0) end
end

local function press_key(seq_str, on)
    if not input then return end
    -- BUGFIX v16.4: la API MAME 0.288 espera un objeto seq en
    -- seq_set_value, no un string. Si le pasamos "KEYCODE_5" crudo,
    -- la llamada falla en runtime. Convertimos vía seq_from_tokens
    -- (canónico en MAME Lua). Todo envuelto en pcall para que
    -- cualquier inconsistencia API no rompa el agente.
    pcall(function()
        if input.seq_from_tokens then
            local seq = input:seq_from_tokens(seq_str)
            if seq and input.seq_set_value then
                input:seq_set_value(seq, on and 1 or 0)
            end
        end
    end)
end

local function force_freeplay()
    pcall(function()
        local coin_a = manager.machine.ioport.ports[":DSW2"].fields["Coin A"]
        if coin_a then coin_a:set_value(7) end
    end)
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
            sprites[#sprites + 1] = {
                sx = sx, sy = sy, code = code, attr = attr, offs = offs,
            }
        end
    end
    return sprites
end

local function update_prev(sprites)
    for _, s in ipairs(sprites) do
        prev[s.offs] = { sx = s.sx, sy = s.sy }
    end
end

local function on_field(s)
    return s.sx < CROWD_PANEL_X and s.sy > FIELD_Y_MIN and s.sy < FIELD_Y_MAX
end

-- v16.2 — BUGFIX del reviewer: helper CRÍTICO. Las funciones de tiro
-- (shoot_on_goal, attract_sprint, shoot-range, chase, panic_dump)
-- estaban hardcoded con dy=-SPRINT (asumiendo "arriba=atacar") y
-- SHOOT_MAX_Y=74 (constant que solo tenía sentido en H1 con
-- OPP_GOAL_Y=36). Tras el half-time swap, OPP_GOAL_Y=200 y las
-- asunciones se rompían completamente: el agente "remataba" hacia
-- arriba cuando el gol rival estaba abajo, y jumás entraba en
-- zona de tiro porque player.sy≈200 > 74. `attack_unit_dy()`
-- resuelve dinámicamente: devuelve ±SPRINT según la portería rival
-- esté arriba o abajo del centro del campo.
-- También `goal_in_shoot_range` cambia de `player.sy > 74` a
-- `|player.sy - OPP_GOAL_Y| > 64`, válido en ambas mitades.
local function attack_unit_dy()
    return (OPP_GOAL_Y < MID_Y) and -SPRINT or SPRINT
end

local function motion(s)
    local p = prev[s.offs]
    if not p then return 0 end
    return math.abs(s.sx - p.sx) + math.abs(s.sy - p.sy)
end

-- Predicción de la posición futura del balón (v14).
-- Extrapola 4 frames en la dirección de movimiento usando prev[].
-- El umbral PRED_MIN_MOTION evita predecir cuando el balón está
-- casi quieto (p.ej. después de un gol o fuera de juego) — en ese
-- caso la predicción es ruido y haría al agente sobrereaccionar.
-- Retorna tabla {bx, by} o nil (table, no multi-return) para que el
-- caller pueda hacer `predicted.bx` / `predicted.by` sin unpacking.
local PRED_FRAMES = 4
local PRED_MIN_MOTION = 5
local function predict_ball(ball)
    if not ball then return nil end
    local p = prev[ball.offs]
    if not p then return nil end
    local vx = ball.sx - p.sx
    local vy = ball.sy - p.sy
    local m = math.abs(vx) + math.abs(vy)
    if m < PRED_MIN_MOTION then return nil end
    local bx = TB.clamp(ball.sx + vx * PRED_FRAMES, 0, 256)
    local by = TB.clamp(ball.sy + vy * PRED_FRAMES, 0, 240)
    return { bx = bx, by = by }
end

-- Module-level flag: chase_ball() lo activa cuando la predicción
-- sustituye la posición actual del balón. act_heuristic lo lee para
-- mostrar "[P]" en overlay. Module-scope (no local de act_heuristic)
-- porque chase_ball() está definido fuera de act_heuristic.
-- BUGFIX v16.3: se restaura esta línea (se borró por accidente
-- durante los duplicados de goal_in_shoot_range en v16). Sin ella,
-- chase_ball y act_heuristic asignarían a un global implícito:
-- funciona en Lua estándar (los globals son auto-creados y
-- escribibles), pero pierde module scoping + incurre en una
-- búsqueda de env table por chase_ball cada frame (medible en
-- profiling).
local debug_predicted = false

local function find_ball(sprites)
    local candidates = {}
    for _, s in ipairs(sprites) do
        if on_field(s) and (s.code == 0x0c or (s.code <= 0x1f and s.code ~= 0x01 and s.code ~= 0x0a and s.code ~= 0x0b)) then
            candidates[#candidates + 1] = s
        end
    end
    for _, s in ipairs(candidates) do
        if s.code == 0x0c then return s end
    end
    -- BUGFIX v16.4: el patrón `goto ::continue::` original también
    -- dispara el error de parser MAME 0.288 cuando hay `goto` antes
    -- del `end` del `for`. Refactor a condición positiva anidada
    -- (idéntica semántica, pero evita la label dentro del bloque).
    local best, best_score = nil, -1
    for _, s in ipairs(candidates) do
        local m = motion(s)
        local at_center = math.abs(s.sx - CENTER_X) < 20 and math.abs(s.sy - CENTER_Y) < 20
        -- Saltar sprites “fantasma” (balón parado en el centro absoluto,
        -- típico de pantalla título/atract que la RAM conserva).
        if not (at_center and m == 0) then
            local score = m * 5 + 8
            if score > best_score then
                best_score, best = score, s
            end
        end
    end
    return best
end

local function is_outfield(s)
    return s.code >= 0x08 and s.sy > 28 and s.sy < 225 and s.sx < CROWD_PANEL_X
end

local function find_player(sprites, balls)
    local outfield = {}
    for _, s in ipairs(sprites) do
        if is_outfield(s) then outfield[#outfield + 1] = s end
    end
    if #outfield == 0 then return nil end
    if #balls == 0 then
        local best = outfield[1]
        for _, s in ipairs(outfield) do
            if s.sy > best.sy then best = s end
        end
        return best
    end

    local closest, best_d = nil, 9999
    for _, p in ipairs(outfield) do
        for _, b in ipairs(balls) do
            local d = dist(p, b)
            if d < best_d then
                best_d = d
                closest = p
            end
        end
    end
    return closest
end

-- Devuelve el sprite outfield NO-jugador más cercano dentro de un radio
-- (THREAT_SCAN_DX, THREAT_SCAN_DY). Tambien cuenta cuántos sprites
-- quedan en el campo (outfield) aparte de nuestro player, para que el
-- overlay muestre la "densidad" de rivales cercana.
-- BUGFIX v13.1: filtra a NUESTRO portero (sprite outfield más profundo
-- en sy, sentado sobre OUR_GOAL_Y) para no tratarlo como rival.
-- Sin este filtro, DODGE curvaba en torno al GK y RETREAT corría
-- hacia nuestra propia portería ante cualquier teammate en ataque
-- (porque todo sprite outfield != player era "amenaza").
local function find_goalkeeper(sprites, player)
    local gk, gk_y = nil, -1
    for _, s in ipairs(sprites) do
        if is_outfield(s) and (not player or s.offs ~= player.offs) then
            if s.sy > gk_y then gk_y, gk = s.sy, s end
        end
    end
    -- Solo devolver si está claramente en zona de portero.
    if gk and gk_y > GK_MIN_Y then return gk end
    return nil
end

local function find_nearest_threat(sprites, player)
    local gk = find_goalkeeper(sprites, player)
    local nearest, best_d = nil, 9999
    local opp_count = 0
    if not player then
        for _, s in ipairs(sprites) do
            if is_outfield(s) then opp_count = opp_count + 1 end
        end
        return nil, opp_count
    end
    for _, s in ipairs(sprites) do
        if is_outfield(s)
            and s.offs ~= player.offs
            and (not gk or s.offs ~= gk.offs) then
            opp_count = opp_count + 1
            local dx = s.sx - player.sx
            local dy = s.sy - player.sy
            if math.abs(dx) <= THREAT_SCAN_DX
                and math.abs(dy) <= THREAT_SCAN_DY then
                local d = math.abs(dx) + math.abs(dy)
                if d < best_d then
                    best_d = d
                    nearest = s
                end
            end
        end
    end
    return nearest, opp_count
end

-- v16 — Media parte: en Tehkan WC los equipos cambian de campo tras
-- ~45s × 60Hz = 2700 frames desde el kick-off inicial. Una sola
-- vez en el partido: H1 → H2, swap de OUR_GOAL_Y ↔ OPP_GOAL_Y para
-- que RETREAT ("defender nuestra portería") y ATR/POS ("tirar a la
-- portería rival") sigan apuntando en la dirección correcta. `half`
-- bloquea el re-disparo; si swap_goals se llama dos veces por error,
-- las constantes vuelven a su valor original (invariante).
local function check_half_time()
    if half == 1 and game_frames > HALF_FRAMES then
        half = 2
        local tmp = OUR_GOAL_Y
        OUR_GOAL_Y = OPP_GOAL_Y
        OPP_GOAL_Y = tmp
    end
end

-- v16 — Lectura defensiva del marcador en sprite RAM. Hipótesis:
-- 4 slots de 4 bytes cada uno en 0xe880 (2 dígitos por equipo),
-- códigos 0x40-0x49 para "0"-"9". Si los códigos no casan,
-- `score_valid` queda en false y la IA ignora el marcador (actitud
-- adaptativa defensiva/ofensiva queda para v17 una vez verificado).
-- Muestreo cada 60 frames — el HUD no cambia a 60Hz así que no
-- perdemos precisión y ahorramos lecturas de sprite RAM.
-- IMPORTANTE: `mem:read_u8` es un método definido via metamethods
-- en MAME Lua; no se puede extraer con `mem.read_u8` y llamarlo
-- directamente. Por eso envolvemos el colon-call en un closure:
-- `pcall(function() return mem:read_u8(addr) end)`. Esto captura
-- el `mem` userdata correctamente y deja que el metamethod
-- resuelva la llamada.
-- BUGFIX v16.2: durante el boot (boot_done=false) no hay marcador
-- aún (atract mode o test screen). Salimos sin leer para evitar 240
-- lecturas/seg innecesarias.
local function detect_scoreboard()
    if not boot_done then return end
    if frame - last_hud_check_frame < 60 then return end
    last_hud_check_frame = frame
    local function read_digit(offs)
        local ok, code = pcall(function()
            return mem:read_u8(HUD_BYTE_BASE + offs)
        end)
        if ok and code and code >= 0x40 and code <= 0x49 then
            return code - 0x40
        end
        return nil
    end
    local u1, u2 = read_digit(0), read_digit(4)
    local t1, t2 = read_digit(8), read_digit(12)
    local prev_us, prev_them = us_score, them_score
    if u1 and u2 and t1 and t2 then
        us_score = u1 * 10 + u2
        them_score = t1 * 10 + t2
        score_valid = true
        -- v17.7: reset accumulator on score change. Sin esto, el sprite
        -- arrastra el residuo del accumulator pre-gol durante 1-2 frames
        -- post-gol (drift en dirección antigua hasta que chase lo corrija).
        -- La primera lectura válida (0-0 → 0-0) NO dispara reset porque
        -- us_score == prev_us en ese caso (ambos 0 inicializados).
        -- Ningún gol posterior se pierde: el segundo AND-clause sin la
        -- guarda prev-not-zero solo filtra el caso sin-cambio real.
        if us_score ~= prev_us or them_score ~= prev_them then
            TB.reset()
        end
    else
        score_valid = false
    end
end

-- v16 — Cascada de set-pieces: kickoff, corner, goal kick, throw-in.
-- Estas situaciones se repiten cada ~30s de partido y el chase
-- genérico las trata mal (pierde el balón, va directo al área).
-- Devuelve true si ha tomado el control del input; en ese caso el
-- `phase` se copia desde `set_phase` para el overlay.
-- Guardas: solo aplica si `boot_done` (juego en juego, no attract),
-- ball + player presentes, y todas las rutinas usan `motion(ball)
-- < umbral` para evitar disparar saques falsos.
local function handle_set_pieces(player, ball)
    if not boot_done or not player or not ball then
        set_phase = nil
        return false
    end
    local bm = motion(ball)
    local bx, by = ball.sx, ball.sy

    -- 1) Kickoff — balón en círculo central quieto varios frames.
    if math.abs(bx - CENTER_X) <= KICKOFF_TOL_X
        and math.abs(by - MID_Y) <= KICKOFF_TOL_Y
        and bm <= 1 then
        kickoff_streak = kickoff_streak + 1
        if kickoff_streak >= KICKOFF_STREAK_MIN then
            set_phase = "SET:KICK"
            -- Mantener posición de saque (mini-impulso diagonal para
            -- no activar RESET por inactividad). No chutamos: el
            -- reglamento exige tocar el balón dos veces; aquí solo
            -- "estamos listos".
            -- BUGFIX v16.1: si el partido está parado (referee
            -- preparando), no podemos seguir reclamando control
            -- indefinidamente. Tras KICKOFF_TIMEOUT frames (~1s) sin
            -- que el balón se mueva, devolvemos el control al árbol
            -- genérico; las reglas de CHASE/ATR decidirán.
            if kickoff_streak > KICKOFF_STREAK_MIN + KICKOFF_TIMEOUT then
                set_phase = nil
                return false
            end
            apply_input(20, 0, false)
            return true
        end
        -- Aún no streak completo, no tomar control todavía (deja que
        -- las reglas genéricas decidan moverse al círculo central).
        return false
    else
        kickoff_streak = 0
    end

    -- 2) Corner — esquina superior (close to opp goal).
    if by < CORNER_MARGIN_Y
        and (bx < CORNER_MARGIN_X or bx > 256 - CORNER_MARGIN_X)
        and bm < 3 then
        -- Curler hacia el palo lejano. La portería rival siempre
        -- está en sy=OPP_GOAL_Y (que apunta hacia donde atacamos):
        --     - en H1 sy=OPP_GOAL_Y=36, así dy<0 (hacia arriba)
        --     - en H2 sy=OPP_GOAL_Y=200 (post-swap), dy>0 (abajo)
        -- Usamos el signo para elegir dirección:
        local attack_sign = (OPP_GOAL_Y < MID_Y) and -1 or 1
        if bx < CORNER_MARGIN_X then
            set_phase = "SET:CRNL"
            apply_input(SPRINT, attack_sign * 32, true)
        else
            set_phase = "SET:CRNR"
            apply_input(-SPRINT, attack_sign * 32, true)
        end
        return true
    end

    -- 3) Goal kick — balón cerca de NUESTRA portería quieto.
    --    Tras el gol, el árbitro pone el balón y nosotros sacamos.
    if bm < 3
        and math.abs(by - OUR_GOAL_Y) <= GOALKICK_BAND
        and math.abs(bx - CENTER_X) <= 60 then
        set_phase = "SET:GKICK"
        -- Saque CORTO al mediocampista (pasamos, no puntaleamos):
        -- dx determina el lado del mediocampista y dy hacia donde
        -- tiene que ir el balón (campo contrario). attack_sign es
        -- dirección de portería rival.
        local attack_sign = (OPP_GOAL_Y < MID_Y) and -1 or 1
        apply_input(20, attack_sign * 48, true)
        return true
    end

    -- 4) Throw-in — balón pegado a la banda lateral (sy extremos),
    --    quieto. Saque corto al medio.
    if bm < 3
        and (by < THROWIN_Y_MAX or by > THROWIN_Y_BOT) then
        set_phase = "SET:THROW"
        local attack_sign = (OPP_GOAL_Y < MID_Y) and -1 or 1
        apply_input(0, attack_sign * 30, true)
        return true
    end

    set_phase = nil
    return false
end

local function goal_in_shoot_range(player, ball)
    -- v16.2 — usar OPP_GOAL_Y dinámico en lugar de SHOOT_MAX_Y=74.
    -- En H1 OPP_GOAL_Y=36, `|player.sy-36|>64` equivale a "no en área rival".
    -- En H2 OPP_GOAL_Y=200, `|player.sy-200|>64` también correcto
    -- (el striker está en sy≈200). X_OFFSET sigue siendo válido
    -- porque OPP_GOAL_X=128 (eje vertical, simétrico entre mitades).
    if math.abs(player.sy - OPP_GOAL_Y) > 64 then return false end
    if math.abs(player.sx - OPP_GOAL_X) > SHOOT_MAX_X_OFF then return false end
    if math.abs(ball.sx - OPP_GOAL_X) > SHOOT_MAX_X_OFF + 10 then return false end
    return true
end

local function attract_sprint(player)
    local goal_dx = TB.clamp(OPP_GOAL_X - player.sx, -SPRINT, SPRINT)
    local band = (player.sx < CENTER_X) and 1 or -1
    local dx
    if math.abs(goal_dx) < 12 then
        dx = band * 29
    else
        dx = goal_dx
    end
    -- v16.2: dy dinámico. Antes `return ..., -SPRINT` (siempre arriba),
    -- tras el swap H2 rompía porque atacamos hacia abajo.
    return TB.clamp(dx, -SPRINT, SPRINT), attack_unit_dy()
end

local function chase_ball(player, ball)
    -- v14: si el balón se mueve rápido, perseguimos la posición FUTURA
    -- (predict_ball). Si está casi quieto, posición actual.
    -- BUGFIX v14.1: predict_ball devuelve TABLA {bx, by}, no multi-return.
    -- BUGFIX v14.2: typo `CENTER_CENTER or CENTER_X` + `end` perdido.
    -- BUGFIX v16.2: el seno `dy > -20 then dy = -SPRINT end` solo
    -- corregía dirección en H1. En H2 dy>−20 inicial (vamos abajo)
    -- ya era correcto. Combinado: si |dy|<20 usamos attack_unit_dy().
    local bx, by = ball.sx, ball.sy
    local pred = predict_ball(ball)
    if pred then
        bx, by = pred.bx, pred.by
        debug_predicted = true
    end
    local dx = TB.clamp(bx - player.sx, -SPRINT, SPRINT)
    local dy = TB.clamp(by - player.sy, -SPRINT, SPRINT)
    if math.abs(dx) + math.abs(dy) < SPRINT then
        if math.abs(dy) < 20 then dy = attack_unit_dy() end
        if dx == 0 then
            dx = (player.sx < CENTER_X) and 29 or -29
        end
    end
    return dx, dy
end

local function shoot_on_goal(player)
    local target_x = (player.sx <= CENTER_X) and (OPP_GOAL_X + 42) or (OPP_GOAL_X - 42)
    local dx = TB.clamp(target_x - player.sx, -SPRINT, SPRINT)
    -- v16.2: dy dinámico (antes era literal hardcoded hacia arriba).
    return dx, attack_unit_dy()
end

local function match_attract(ball, player)
    -- Itera sobre el array fusionado (learned + attract). La prioridad
    -- viene del orden en TACTICS: aprendidas primero, demo arcade después.
    -- Si no hay reglas, cae al heurístico puro sin penalizar rendimiento.
    if type(TACTICS) ~= "table" or #TACTICS == 0 then return nil end
    if not ball or not player then return nil end
    for _, t in ipairs(TACTICS) do
        if type(t) ~= "table" or type(t.bx) ~= "number"
            or type(t.by) ~= "number" then
            -- skip malformed entry defensivo
        else
            local bx_tol = t.bx_tol or 36
            local by_tol = t.by_tol or 36
            if math.abs(ball.sx - t.bx) <= bx_tol
                and math.abs(ball.sy - t.by) <= by_tol
                and (not t.py_max or player.sy <= t.py_max) then
                return t
            end
        end
    end
    return nil
end

apply_input = function(raw_dx, raw_dy, kick)
    local dx, dy = TB.hold_apply(hold, raw_dx, raw_dy)
    TB.inject_trackball(fld_p1x, fld_p1y, fld_btn, dx, dy, kick)
end

-- v17.8 DIAG — instrumentación temporal para identificar por qué set_value
-- no llega al juego tras 7 iteraciones. Escribe CSV a /tmp/tehkan_diag.log
-- cada 30 frames con: frame,phase,bd,dx,dy,kick,ball,player,accum_x,accum_y
-- + alive check de fields. Se mantiene hasta que el root cause esté
-- confirmado empíricamente; después se elimina esta sección.
-- v18.0 — Logger arranca SIN esperar a boot_done. Cada 30 frames
-- escribe una línea CSV a /tmp/tehkan_diag.log con todo el estado
-- relevante. Sirve para diagnóstico EMPÍRICO: si está vacío, el
-- script no llegó al frame 30; si tiene líneas pero accum_x=0,
-- MAME no procesó el set_value; etc.
local DIAG_PATH = "/tmp/tehkan_diag.log"
local DIAG_INIT = false
local function diag_init()
    if DIAG_INIT then return end
    DIAG_INIT = true
    pcall(function()
        local f = io.open(DIAG_PATH, "w")
        if f then
            f:write("frame,phase,bd,dx,dy,kick,ball_x,ball_y,ball_code,"
                .. "player_x,player_y,player_code,accum_x,accum_y,"
                .. "fldx_alive,fldy_alive,fldbtn_alive\n")
            f:close()
        end
    end)
end
local function diag_log(phase_s, bd_v, dx_v, dy_v, kick_v,
                        ball_v, player_v)
    if frame % 30 ~= 0 then return end
    diag_init()
    local ax, ay = 0, 0
    pcall(function() ax, ay = TB.get_diag() end)
    local bx, by, bc = -1, -1, -1
    if ball_v then bx, by, bc = ball_v.sx, ball_v.sy, ball_v.code end
    local px, py, pc = -1, -1, -1
    if player_v then px, py, pc = player_v.sx, player_v.sy, player_v.code end
    local fldx_ok = (fld_p1x ~= nil) and (tostring(fld_p1x) ~= "nil") and 1 or 0
    local fldy_ok = (fld_p1y ~= nil) and (tostring(fld_p1y) ~= "nil") and 1 or 0
    local fldb_ok = (fld_btn ~= nil) and (tostring(fld_btn) ~= "nil") and 1 or 0
    local row = string.format(
        "%d,%s,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d\n",
        frame, phase_s or "-", bd_v or -1,
        dx_v or 0, dy_v or 0, kick_v and 1 or 0,
        bx, by, bc, px, py, pc,
        math.floor(ax or 0), math.floor(ay or 0),
        fldx_ok, fldy_ok, fldb_ok)
    pcall(function()
        local f = io.open(DIAG_PATH, "a")
        if f then f:write(row); f:close() end
    end)
end

local function boot_sequence()
    -- Arranque robusto: varias monedas + starts espaciados.
    -- NO inyectar trackball aquí: en Tehkan el menú de equipos
    -- usa el trackball y el zig-zag del boot saltaba al GAME OVER
    -- del attract sin empezar partido.
    if frame == 1 then force_freeplay() end

    local function pulse_coin(on)
        press_sys(SYS_COIN1, on)
        press_key("KEYCODE_5", on)
    end
    local function pulse_start(on)
        press_sys(SYS_START1, on)
        press_key("KEYCODE_1", on)
    end

    -- 3 monedas (por si el DIP o el credit counter pide más de 1)
    if frame == 120 or frame == 200 or frame == 280 then
        pulse_coin(true)
    elseif frame == 134 or frame == 214 or frame == 294 then
        pulse_coin(false)
    -- Starts: título → select equipo → kickoff
    elseif frame == 360 or frame == 480 or frame == 600
        or frame == 720 or frame == 840 then
        pulse_start(true)
    elseif frame == 372 or frame == 492 or frame == 612
        or frame == 732 or frame == 852 then
        pulse_start(false)
    elseif frame == 900 then
        boot_done = true
        TB.reset()
    end
end

local function act_heuristic()
    -- v16: detectores baratos primero. check_half_time corre cada
    -- frame (un solo integer compare); detect_scoreboard se
    -- auto-muestrea a 1Hz (last_hud_check_frame gating) y nunca
    -- bloquea. handle_set_pieces cortocircuita el resto del
    -- decision tree cuando un saque domina la situación.
    if boot_done then check_half_time() end
    detect_scoreboard()

    local sprites = read_sprites()
    local ball = find_ball(sprites)
    local balls = ball and { ball } or {}
    local player = find_player(sprites, balls)

    if not ball or not player then
        phase = "NO_SPR"
        -- v16.2: dy dinámico. Antes `apply_input(0, -SPRINT, false)`
        -- empujaba arriba en H2 (portería propia).
        apply_input(0, attack_unit_dy(), false)
        update_prev(sprites)
        return
    end

    -- v16: set-piece short-circuit. Solo aplica cuando boot_done
    -- (durante attract no hay kickoff, etc.). Si toca un saque,
    -- aplicamos el input YA y salimos — el resto del árbol
    -- (PANIC/ATR/SHOOT/POS/RETREAT/CHASE) NO debe pisar la jugada.
    if handle_set_pieces(player, ball) then
        phase = set_phase or "SET:*"
        debug_pos = string.format("%s%s d=%d",
            phase, debug_predicted and "[P]" or "",
            dist(player, ball))
        update_prev(sprites)
        debug_predicted = false
        return
    end

    local bd = dist(player, ball)
    local possessed = bd < POSSESSION_DIST
    local dx, dy, kick = 0, attack_unit_dy(), false

    -- v18.0 — CASCADA MÍNIMA pedida por el usuario:
    --   "cuando tenga el balón, correr en diagonal hacia arriba sin
    --    parar, dirección hasta la otra portería"
    -- Solo dos ramas:
    --   SIN BALÓN (>50 px)   → INTERCEPT: chase_ball (persigue balón).
    --   CON BALÓN (<=50 px)  → DIAG↑: dx = ±42 (rama hacia palo lejano),
    --                          dy = -SPRINT = -58 (full sprint arriba),
    --                          kick=false (dribble Tehkan = trackball +
    --                          solapando balón; chut no se mantiene).
    -- Eliminadas: SHOOT (ahora siempre corre), set-pieces (mantengo
    -- solo handle_set_pieces para KICKOFF/CORNER/GKICK/THROWIN que
    -- ya teniamos y son útiles para no quedarse parado en saques).
    if not possessed then
        dx, dy = chase_ball(player, ball)
        kick = false
        phase = "INTERCEPT"
    else
        -- Regla del usuario: diagonal hacia portería rival, sin parar.
        -- Banda hacia el palo lejano (lado contrario a donde estamos):
        local band = (player.sx < CENTER_X) and 1 or -1
        dx = band * 42
        dy = -SPRINT
        kick = false
        phase = "DIAG↑"
    end

    debug_pos = string.format(
        "v18.0 %s%s d=%d dx=%+d dy=%+d",
        phase, debug_predicted and "[P]" or "", bd, dx, dy
    )
    apply_input(dx, dy, kick)
    diag_log(phase, bd, dx, dy, kick, ball, player)
    update_prev(sprites)
    debug_predicted = false
end

-- v19 — agente reescrito con datos medidos en partidas reales (oct 2026).
-- Errores de v18 que corrige:
--  1. El "jugador" era la sombra del balón (code 0x10, misma posición
--     que el balón) → distancia 0 → creía tener el balón siempre.
--     Jugadores reales: code >= 0x80.
--  2. No distinguía equipos. Color = attr & 0x0f: 0 = ROJO (nosotros),
--     1 = AZUL (máquina), 2/3 = porteros.
--  3. Posesión a 50 px (media pantalla). Medido: con el balón pegado
--     al pie la distancia es <= ~10 px → usamos 14.
--  4. La pantalla hace scroll, así que la Y de pantalla no dice dónde
--     está la portería. Usamos el balón del minimapa (code 0x01,
--     sx >= 220): y≈121 centro, ≈137 nuestra portería en la 1ª parte.
--  5. Dirección de ataque: en cada saque inicial cada equipo está en su
--     mitad. Si los rojos están debajo, atacamos hacia arriba. Así
--     también detecta el cambio de campo del descanso.
-- Marcador en RAM: 0xc100 = rojo, 0xc101 = máquina.
local V19_GOAL_X      = 112
local V19_POSSESS     = 12
local V19_MM_CENTER   = 121
local V19_MM_SHOOT   = 8    -- medido: 8 → 6G/6E/0P en 12 partidos (4, 14 y 20 peores)
local V19_MM_HALF     = 16
local v19_attack_dir  = -1   -- -1 = arriba, +1 = abajo
local v19_mm_ball_y   = V19_MM_CENTER
local V19_KICK_TAP      = 5    -- frames de botón: toque corto (0 = ráfagas antiguas 6+6)
local V19_SHOT_SPEED    = 24   -- trackball al chutar: máx. 24 para que el tiro siga raso
local V19_SHOT_DX       = 0    -- >0 = tiro cruzado (estilo humano), 0 = hacia el centro
local V19_KICK_COOLDOWN = 32   -- frames de espera entre toques
-- Ajustes que el entrenador (scripts/train_tehkan_params.py) puede cambiar
local V19_DRIBBLE_SPEED = 58   -- velocidad hacia portería con el balón
local V19_DRIBBLE_DX    = 38   -- corrección lateral máx. hacia el centro
local V19_DODGE_AHEAD   = 44   -- distancia del defensa delante para esquivar
local V19_DODGE_LAT     = 10   -- anchura de la zona de peligro
local V19_DODGE_FWD     = 0   -- avance mientras esquiva
local V19_LEAD          = 8    -- frames de anticipación al perseguir
local V19_TACKLE_DIST   = 26   -- distancia para intentar la entrada
local v19_kick_timer  = 0
local v19_prev_ball   = nil

local function v19_classify(sprites)
    local ball, red, blue = nil, {}, {}
    for _, s in ipairs(sprites) do
        if s.code == 0x01 and s.sx >= 220 then
            v19_mm_ball_y = s.sy
        elseif s.sx < CROWD_PANEL_X then
            if s.code == 0x0c then
                ball = s
            elseif s.code >= 0x80 then
                local pal = s.attr & 0x0f
                if pal == 0 then red[#red + 1] = s
                elseif pal == 1 then blue[#blue + 1] = s end
            end
        end
    end
    return ball, red, blue
end

local v19_dir_candidate, v19_dir_streak = nil, 0
local function v19_update_direction(ball, red, blue)
    if #red < 4 or #blue < 4 or not ball then v19_dir_streak = 0; return end
    if math.abs(ball.sx - 116) > 10 then return end
    local rmin, rmax, bmin, bmax = 999, -999, 999, -999
    for _, s in ipairs(red) do rmin = math.min(rmin, s.sy); rmax = math.max(rmax, s.sy) end
    for _, s in ipairs(blue) do bmin = math.min(bmin, s.sy); bmax = math.max(bmax, s.sy) end
    -- Solo cambiamos si la formación de saque se mantiene >= 30 frames
    -- (en una grabación humana el detector se equivocó 2 veces ~5 s).
    local seen = nil
    if rmin > bmax - 4 then seen = -1 elseif bmin > rmax - 4 then seen = 1 end
    if seen and seen == v19_dir_candidate then
        v19_dir_streak = v19_dir_streak + 1
    else
        v19_dir_candidate, v19_dir_streak = seen, (seen and 1 or 0)
    end
    if seen and v19_dir_streak >= 30 then v19_attack_dir = seen end
end

local function v19_nearest(list, ball)
    local best, bd = nil, 9999
    for _, s in ipairs(list) do
        local d = math.abs(s.sx - ball.sx) + math.abs(s.sy - ball.sy)
        if d < bd then best, bd = s, d end
    end
    return best, bd
end

local function v19_in_shoot_zone()
    local rival_end = V19_MM_CENTER + v19_attack_dir * V19_MM_HALF
    return math.abs(v19_mm_ball_y - rival_end) <= V19_MM_SHOOT
end

-- IMITACIÓN: memoria de jugadas humanas (scripts/learn_tehkan_demos.py).
-- Con balón, busca las K situaciones grabadas más parecidas y copia lo que
-- hizo el humano (trackball + botón). Si ninguna se parece lo bastante,
-- se usan las reglas de siempre.
local V19_IMITATE    = 0    -- 1 = usar tus jugadas, 0 = solo reglas
local V19_IMIT_K     = 7    -- vecinos que se consultan
local V19_IMIT_MAXD  = 60   -- distancia máxima media para fiarse de la memoria
local V19_IMIT_BTN   = 0    -- 1 = copiar también el botón, 0 = chutar con las reglas
local V19_IMIT_GOALW = 70   -- % de distancia para jugadas que acabaron en gol (prefiere goles)
local IMIT = nil
if V19_IMITATE == 1 then
    local ok, data = pcall(load_lua_module, ROOT .. "/scripts/mame/tehkan_imitation_data.lua")
    if ok and type(data) == "table" and #data > 0 then IMIT = data end
end
local IW = { 4, 0.5, 2, 2, 1, 1, 0.5, 0.5 }   -- pesos de cada rasgo

local function v19_imitate(me, ball, blue)
    if not IMIT then return nil end
    local d = v19_attack_dir
    table.sort(blue, function(a, b)
        return math.abs(a.sx - me.sx) + math.abs(a.sy - me.sy) < math.abs(b.sx - me.sx) + math.abs(b.sy - me.sy)
    end)
    local function rel(i)
        local b = blue[i]
        if not b then return 60, 60 end
        return TB.clamp(b.sx - me.sx, -60, 60), TB.clamp((b.sy - me.sy) * -d, -60, 60)
    end
    local r1x, r1y = rel(1)
    local r2x, r2y = rel(2)
    local f = { (121 - v19_mm_ball_y) * (-d), me.sx, ball.sx - me.sx, (ball.sy - me.sy) * (-d), r1x, r1y, r2x, r2y }
    local K = V19_IMIT_K
    local best = {}   -- {dist, idx} ordenado
    for i = 1, #IMIT do
        local s = IMIT[i]
        local acc = 0
        for j = 1, 8 do
            local e = (f[j] - s[j]) * IW[j]
            acc = acc + e * e
        end
        if s[12] == 1 then acc = acc * (V19_IMIT_GOALW / 100) ^ 2 end
        if #best < K or acc < best[#best][1] then
            local pos = #best + 1
            while pos > 1 and best[pos - 1][1] > acc do pos = pos - 1 end
            table.insert(best, pos, { acc, i })
            if #best > K then best[#best] = nil end
        end
    end
    local sd, ax, fw, bt = 0, 0, 0, 0
    for _, b in ipairs(best) do
        local s = IMIT[b[2]]
        sd = sd + math.sqrt(b[1]); ax = ax + s[9]; fw = fw + s[10]; bt = bt + s[11]
    end
    local n = #best
    if n == 0 or sd / n > V19_IMIT_MAXD then return nil end
    return ax / n, (fw / n) * d, (bt * 2 > n), sd / n
end

local function act_v19()
    local sprites = read_sprites()
    local ball, red, blue = v19_classify(sprites)
    if not ball or #red == 0 then
        phase = "WAIT"
        apply_input(0, 0, false)
        return
    end
    v19_update_direction(ball, red, blue)

    local me, my_d = v19_nearest(red, ball)
    local foe, foe_d = v19_nearest(blue, ball)
    local dx, dy, kick = 0, 0, false

    -- velocidad del balón para anticipar
    local vx, vy = 0, 0
    if v19_prev_ball then vx, vy = ball.sx - v19_prev_ball.sx, ball.sy - v19_prev_ball.sy end
    if math.abs(vx) > 12 or math.abs(vy) > 12 then vx, vy = 0, 0 end -- salto de scroll
    v19_prev_ball = { sx = ball.sx, sy = ball.sy }

    local imitating, imit_move = false, false
    if my_d <= V19_POSSESS and my_d <= foe_d and IMIT then
        local ix, iy, ik, idist = v19_imitate(me, ball, blue)
        if ix then
            dx, dy = ix, iy
            if V19_IMIT_BTN == 1 then
                kick = ik
                imitating = true
                phase = string.format("IMITA%s %d", ik and "+CHUT" or "", math.floor(idist))
            elseif v19_in_shoot_zone() then
                -- moverse como el humano, pero chutar con la regla (toque corto)
                dx = TB.clamp((V19_GOAL_X - me.sx) * 2, -V19_SHOT_SPEED, V19_SHOT_SPEED)
                dy = v19_attack_dir * V19_SHOT_SPEED
                kick = true
                phase = "IMITA:SHOOT"
            else
                kick = false
                phase = string.format("IMITA %d", math.floor(idist))
            end
            imit_move = true
        end
    end
    if imit_move then
        -- movimiento copiado del humano
    elseif my_d <= V19_POSSESS and my_d <= foe_d then
        -- CON BALÓN: correr hacia la portería rival esquivando
        dy = v19_attack_dir * V19_DRIBBLE_SPEED
        dx = TB.clamp((V19_GOAL_X - me.sx), -V19_DRIBBLE_DX, V19_DRIBBLE_DX)
        local threat, tdist = nil, 9999
        for _, b in ipairs(blue) do
            local ahead = (b.sy - me.sy) * v19_attack_dir
            local lat = b.sx - me.sx
            if ahead > 0 and ahead < V19_DODGE_AHEAD and math.abs(lat) < V19_DODGE_LAT then
                if ahead < tdist then threat, tdist = b, ahead end
            end
        end
        if threat then
            local side = (threat.sx >= me.sx) and -1 or 1
            if me.sx < 30 then side = 1 elseif me.sx > 180 then side = -1 end
            dx = side * SPRINT
            dy = v19_attack_dir * V19_DODGE_FWD
            phase = "DODGE"
        else
            phase = "DRIBBLE"
        end
        if v19_in_shoot_zone() then
            dx = TB.clamp((V19_GOAL_X - me.sx) * 2, -V19_SHOT_SPEED, V19_SHOT_SPEED)
            if V19_SHOT_DX > 0 then
                -- tiro cruzado como el humano: empujar hacia el lado contrario
                dx = ((me.sx < V19_GOAL_X) and 1 or -1) * V19_SHOT_DX
            end
            dy = v19_attack_dir * V19_SHOT_SPEED
            kick = true
            phase = "SHOOT"
        end
    else
        -- SIN BALÓN: ir a por él anticipando su trayectoria
        local tx = ball.sx + vx * V19_LEAD
        local ty = ball.sy + vy * V19_LEAD
        dx = TB.clamp((tx - me.sx) * 3, -SPRINT, SPRINT)
        dy = TB.clamp((ty - me.sy) * 3, -SPRINT, SPRINT)
        phase = "CHASE"
        -- entrada si el rival lo lleva y estamos encima
        if foe and foe_d <= V19_POSSESS and my_d <= V19_TACKLE_DIST then
            kick = true
            phase = "TACKLE"
        end
    end

    -- Toque corto de V19_KICK_TAP frames y espera de V19_KICK_COOLDOWN.
    -- (Medido: la altura del tiro depende sobre todo de la velocidad del
    -- trackball al chutar, ver V19_SHOT_SPEED.)
    if imitating then
        v19_kick_timer = 0   -- botón tal cual lo pulsaba el humano
    elseif V19_KICK_TAP == 0 then
        -- modo antiguo: ráfagas de 6 frames pulsado / 6 suelto
        if kick then
            v19_kick_timer = v19_kick_timer + 1
            if v19_kick_timer % 12 >= 6 then kick = false end
        else
            v19_kick_timer = 0
        end
    elseif kick then
        v19_kick_timer = v19_kick_timer + 1
        if v19_kick_timer > V19_KICK_TAP then kick = false end
        if v19_kick_timer >= V19_KICK_TAP + V19_KICK_COOLDOWN then v19_kick_timer = 0 end
    elseif v19_kick_timer > 0 then
        v19_kick_timer = v19_kick_timer + 1
        if v19_kick_timer >= V19_KICK_TAP + V19_KICK_COOLDOWN then v19_kick_timer = 0 end
    end

    debug_pos = string.format("v19 %s dir=%s d=%d mm=%d",
        phase, v19_attack_dir < 0 and "UP" or "DN", my_d, v19_mm_ball_y)
    apply_input(dx, dy, kick)
end

-- MODO HUMANO (enseñanza por imitación): la IA NO toca los controles.
-- Juegas tú con el ratón como trackball y se graba cada frame:
-- situación (balón, tu jugador, rivales cercanos, posición en el campo)
-- + lo que haces (movimiento del trackball y botón) + marcador.
-- CSV en logs/tehkan_demos/. Lo usa scripts/learn_tehkan_demos.py.
local HUMAN_FILE = nil
local human_prev_x, human_prev_y = nil, nil
local human_port_x = manager.machine.ioport.ports[":P1X"]
local human_port_y = manager.machine.ioport.ports[":P1Y"]
local human_port_b = manager.machine.ioport.ports[":P1BUT"]

local function signed8(d)
    d = d % 256
    if d > 127 then d = d - 256 end
    return d
end

local function act_human()
    if not HUMAN_FILE then
        pcall(function() os.execute('mkdir -p "' .. ROOT .. '/logs/tehkan_demos"') end)
        local path = ROOT .. "/logs/tehkan_demos/demo_" .. os.date("%Y%m%d_%H%M%S") .. ".csv"
        HUMAN_FILE = _G.io.open(path, "w")
        if HUMAN_FILE then
            HUMAN_FILE:write("frame,us,them,won,dir,mm_y,me_x,me_y,ball_x,ball_y,ball_vx,ball_vy,"
                .. "my_d,foe_d,r1dx,r1dy,r2dx,r2dy,r3dx,r3dy,tb_dx,tb_dy,btn\n")
        end
        phase = "HUMANO: grabando"
    end
    local x, y = human_port_x:read() & 0xff, human_port_y:read() & 0xff
    local tdx = human_prev_x and signed8(x - human_prev_x) or 0
    local tdy = human_prev_y and signed8(y - human_prev_y) or 0
    human_prev_x, human_prev_y = x, y
    local btn = ((human_port_b:read() & 0x20) == 0) and 1 or 0

    local sprites = read_sprites()
    local ball, red, blue = v19_classify(sprites)
    if not ball or #red == 0 or not HUMAN_FILE then return end
    v19_update_direction(ball, red, blue)
    local me, my_d = v19_nearest(red, ball)
    local _, foe_d = v19_nearest(blue, ball)
    local vx, vy = 0, 0
    if v19_prev_ball then vx, vy = ball.sx - v19_prev_ball.sx, ball.sy - v19_prev_ball.sy end
    if math.abs(vx) > 12 or math.abs(vy) > 12 then vx, vy = 0, 0 end
    v19_prev_ball = { sx = ball.sx, sy = ball.sy }
    -- 3 rivales más cercanos a mi jugador (relativos, orientados al ataque)
    table.sort(blue, function(a, b)
        return math.abs(a.sx - me.sx) + math.abs(a.sy - me.sy) < math.abs(b.sx - me.sx) + math.abs(b.sy - me.sy)
    end)
    local rel = {}
    for i = 1, 3 do
        local b = blue[i]
        if b then rel[#rel + 1] = (b.sx - me.sx) .. "," .. ((b.sy - me.sy) * -v19_attack_dir)
        else rel[#rel + 1] = "99,99" end
    end
    local mem_ = manager.machine.devices[":maincpu"].spaces["program"]
    HUMAN_FILE:write(string.format("%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%s,%d,%d,%d\n",
        frame, mem_:read_u8(0xc100), mem_:read_u8(0xc101), mem_:read_u8(0xc0c0),
        v19_attack_dir, v19_mm_ball_y, me.sx, me.sy, ball.sx, ball.sy, vx, vy,
        my_d, foe_d or 999, table.concat(rel, ","), tdx, tdy, btn))
    if frame % 60 == 0 then HUMAN_FILE:flush() end
    phase = "HUMANO: grabando"
    debug_pos = string.format("GRABANDO  %d-%d  ronda %d", mem_:read_u8(0xc100), mem_:read_u8(0xc101), mem_:read_u8(0xc0c0) + 1)
end

local function act_random()
    local dx = ((frame % 7) - 3) * 18
    local dy = -SPRINT
    apply_input(dx, dy, (frame % 47) == 0)
end

local function act_agent()
    if AGENT == "random" then
        act_random()
    elseif AGENT == "v18" then
        act_heuristic()
    elseif AGENT == "human" then
        act_human()
    else
        act_v19()
    end
end

local function draw_overlay()
    local screen = manager.machine.screens[":screen"]
    if not screen then return end
    local mode = debug_pos
    if not boot_done then
        if frame < 300 then mode = "COIN(5)"
        elseif frame < 900 then mode = "START(1)"
        else mode = "START..." end
    elseif mode == "" then
        local score_str = score_valid
            and string.format("S:%d-%d ", us_score, them_score) or ""
        mode = string.format("AI v%s H%d %s[tactics %d, learned %d] %s",
            "18.0", half, AGENT, #TACTICS, TACTICS_LEARNED_N, score_str)
    end
    screen:draw_text(4, 4, string.format("%s  f%d", mode, frame), 0xffffffff, 0xff000000)
end

emu.register_frame_done(function()
    frame = frame + 1
    if not boot_done then
        one_off_injection_test()
        boot_sequence()
        draw_overlay()
        return
    end
    game_frames = game_frames + 1
    act_agent()
    draw_overlay()
end)
