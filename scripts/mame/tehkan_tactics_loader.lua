-- Tehkan World Cup — loader unificado de tácticas pattern-based.
--
-- Carga reglas desde DOS fuentes con esquema compatible:
--   • attract_tactics.lua — auto-generado por scripts/learn_from_attract.py
--     (demo de atract mode del arcade, sin intervención humana)
--   • learned_tactics.lua — auto-generado por scripts/learn_from_demos.py
--     (partidas humanas grabadas con teach.py + markers)
--
-- Ambos archivos exponen la misma forma:
--   local TABLA = {
--     { name = "...", bx = N, by = N, bx_tol = N, by_tol = N,
--       py_max = N, dx = N, dy = N, kick = bool },
--     ...
--   }
--   return TABLA
--
-- El módulo devuelve un array combinado. Las reglas LEARNED tienen mayor
-- prioridad que las ATTRACT porque vienen de juego humano real contra
-- este mismo hardware. Si un archivo falta, simplemente se omite sin
-- fallar (pcall + nil checks).
--
-- Uso desde el agente:
--     local T = require_or_load(root .. "/scripts/mame/tehkan_tactics_loader.lua")
--     local tactics = T.load_combined(root)
--     for _, t in ipairs(tactics) do ... end
--
-- El módulo es robusto a:
--   • Cualquiera de los dos archivos ausente
--   • loadfile/dofile no disponible en el build (caso exótico MAME)
--   • loadfile devuelve nil (ruta errónea)

local M = {}

-- Carga un módulo Lua arbitrario desde una ruta absoluta.
-- Devuelve el valor retornado por el módulo, o nil si falla.
function M.try_load(path)
    if not path then return nil end
    local chunk = loadfile(path)
    if chunk then
        local ok, val = pcall(chunk)
        if ok and type(val) == "table" then return val end
    end
    if dofile then
        local ok, val = pcall(dofile, path)
        if ok and type(val) == "table" then return val end
    end
    return nil
end

-- Fusiona dos tablas de tácticas preservando prioridad: `priority` va
-- primero, `baseline` después. Si alguno es nil o no es tabla, se omite.
function M.merge(priority, baseline)
    local out = {}
    if type(priority) == "table" then
        for i, t in ipairs(priority) do out[#out + 1] = t end
    end
    if type(baseline) == "table" then
        local offset = #out
        for i, t in ipairs(baseline) do out[offset + i] = t end
    end
    return out
end

-- Atajo: dada la raíz del proyecto, devuelve un array de tácticas ya
-- fusionadas. La firma `load_combined(root)` mantiene el contrato
-- simple desde el exterior; este módulo se ocupa de todo lo interno.
function M.load_combined(root)
    if not root then return {} end
    local learned = M.try_load(root .. "/scripts/mame/learned_tactics.lua")
    local attract = M.try_load(root .. "/scripts/mame/attract_tactics.lua")
    return M.merge(learned, attract)
end

-- Cobertura mínima de un match_attract genérico. Cada táctica debe tener
-- los campos `bx`, `by`, `bx_tol`, `by_tol`, `py_max`, `dx`, `dy`,
-- `kick`. Si ball/player son nil, devuelve nil (no hay trigger).
--
-- BUGFIX v3: el patrón `goto … label-continuación` con label tras un `return`
-- dentro del bloque `for` produce un error de sintaxis en MAME 0.288
-- (parser de Lua embedded en MAME estricto): "'end' expected (to close
-- 'for') near label-token". Refactorizamos a early-return con
-- condiciones positivas encadenadas — sin goto/label, semánticamente
-- equivalente.
function M.match(tactics, ball, player)
    if type(tactics) ~= "table" or #tactics == 0 then return nil end
    if not ball or not player then return nil end
    for i = 1, #tactics do
        local t = tactics[i]
        if type(t) == "table"
            and type(t.bx) == "number"
            and type(t.by) == "number"
            and math.abs(ball.sx - t.bx) <= (t.bx_tol or 36)
            and math.abs(ball.sy - t.by) <= (t.by_tol or 36)
            and (not t.py_max or player.sy <= t.py_max) then
            return t
        end
    end
    return nil
end

return M
