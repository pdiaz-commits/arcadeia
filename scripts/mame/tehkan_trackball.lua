-- Tehkan World Cup — utilidades trackball (mantener diagonal pulsada)

local M = {}

M.SPRINT = 58
M.MAX_DELTA = 58

function M.clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

function M.new_hold_state(min_frames)
    return { dx = 0, dy = 0, frames = 0, min = min_frames or 18 }
end

-- El trackball del arcade necesita el mismo empuje varios frames seguidos (diagonal mantenida).
function M.hold_apply(state, dx, dy)
    dx = M.clamp(dx or 0, -M.MAX_DELTA, M.MAX_DELTA)
    dy = M.clamp(dy or 0, -M.MAX_DELTA, M.MAX_DELTA)

    if dx ~= 0 or dy ~= 0 then
        state.dx = dx
        state.dy = dy
        state.frames = state.min
    elseif state.frames > 0 then
        state.frames = state.frames - 1
        dx, dy = state.dx, state.dy
    else
        dx, dy = 0, 0
    end
    return dx, dy
end

function M.read_keyboard_delta(input)
    if not input or not input.seq_pressed then
        return 0, 0
    end
    local dx, dy = 0, 0
    local function held(seq)
        local ok, val = pcall(function() return input:seq_pressed(seq) end)
        return ok and val
    end
    if held("KEYCODE_LEFT") or held("KEYCODE_Z") then dx = dx - M.SPRINT end
    if held("KEYCODE_RIGHT") or held("KEYCODE_X") then dx = dx + M.SPRINT end
    if held("KEYCODE_UP") or held("KEYCODE_A") then dy = dy - M.SPRINT end
    if held("KEYCODE_DOWN") or held("KEYCODE_S") then dy = dy + M.SPRINT end
    return M.clamp(dx, -M.MAX_DELTA, M.MAX_DELTA), M.clamp(dy, -M.MAX_DELTA, M.MAX_DELTA)
end

-- v17.7 BUGFIX FINAL — eliminamos wrap-around buggy.
-- La causa raíz REAL de los seis intentos fallidos:
--
-- MAME's IPT_TRACKBALL_X/Y stores a 32-bit absolute tracking counter.
-- Cada frame MAME calcula `delta = m_value - m_old_value` y aplica al
-- juego. Si llamamos `fld_x:set_value(42)` cada frame sin accumulator,
-- delta = 42-42 = 0 → sprite congelado (v17.2-v17.5 fallaron por esto).
--
-- En v17.6 añadimos accumulator Lua + wrap a 8 bits [-128, +127] para
-- "mantener el rango del trackball". Idea: estaba bien, wrap mal:
-- cuando accum_x cruza 127 con +42, accumulator pasa de +127 → +169,
-- wrap kicks in → -87. MAME ve el set_value jump de +127 a -87, calcula
-- delta = -87 - 127 = -214 (¡huge en dirección opuesta!). MAME's
-- trackball analog handler clamps deltas extremos (anti-glitch) → el
-- delta efectivo es 0 o un jitter minúsculo. Eso explica por qué
-- v17.6 (zig-zag real en boot) funcionaba: zig-zag era simétrico
-- (±40 a 0, ±40 a 0) y NUNCA cruzaba el wrap boundary.
--
-- CORRECCIÓN en v17.7: ELIMINAMOS el wrap-around completamente.
-- Lua acumula en doubles (53-bit precision, ~9e15 sin overflow). MAME
-- internamente maneja el contador 32-bit con su propia lógica de
-- overflow (no salta artificialmente cuando el value está lejos del
-- wrap; trata el delta correctamente para aritmética signada).
-- NO recalculamos el valor; emitimos el accumulator tal cual.
-- set_value acepta cualquier valor C int (32-bit); math.floor de
-- double a int cabe sin perder precisión para cualquiera de
-- nuestros rangos prácticos (SPRINT=58 * 60fps * 60min = ~200k, lejos
-- de int32 max=2.1e9).
local accum_x = 0
local accum_y = 0

function M.inject_trackball(fld_x, fld_y, fld_btn, dx, dy, kick)
    accum_x = accum_x + (dx or 0)
    accum_y = accum_y + (dy or 0)
    -- NO wrap-around (esto era la causa del bug v17.6:
    -- los wrap cruzados generaban deltas -214 que MAME rechazaba).
    fld_x:set_value(math.floor(accum_x))
    fld_y:set_value(math.floor(accum_y))
    if fld_btn then fld_btn:set_value(kick and 1 or 0) end
end

-- v17.7 DIAG: expone estado interno del accumulator para diagnóstico.
-- Llamable desde el agente (TB.get_diag()) y desde emu.print_error()
-- para logging sin acoplarse al state interno.
function M.get_diag()
    return accum_x, accum_y
end

-- v17.7: reset() para tests. Permite reiniciar el accumulator entre
-- runs (e.g., después de un gol detectable) sin acumulación residual
-- que falsee los primeros frames.
function M.reset()
    accum_x = 0
    accum_y = 0
end

return M
