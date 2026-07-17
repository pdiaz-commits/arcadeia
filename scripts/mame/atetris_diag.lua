-- Diagnóstico Atari Tetris: logea estado RAM tras boot
local ROOT = "/Users/pablo/Documents/arcade-ai"
local LOG = ROOT .. "/logs/demos/atetris_diag.jsonl"
local PF_BASE = 0x1000
local COL_LO, COL_HI, ROW_LO, ROW_HI = 10, 31, 2, 29

local in0 = manager.machine.ioport.ports[":IN0"]
local in1 = manager.machine.ioport.ports[":IN1"]
local mem = manager.machine.devices[":maincpu"].spaces["program"]

local frame = 0
local boot_done = false
local log = nil

local function tile_code(row, col)
    local idx = row * 64 + col
    local addr = PF_BASE + idx * 2
    return mem:read_u8(addr) | ((mem:read_u8(addr + 1) & 7) << 8)
end

local function boot_sequence()
    if frame == 60 then in0:field(0x2):set_value(1)
    elseif frame == 70 then in0:field(0x2):set_value(0)
    elseif frame >= 120 and frame <= 280 then in1:field(0x1):set_value(1)
    elseif frame == 300 then in1:field(0x1):set_value(0); boot_done = true
    end
end

emu.register_frame_done(function()
    frame = frame + 1
    if not boot_done then boot_sequence(); return end
    if frame % 30 ~= 0 then return end

    if not log then
        os.execute("mkdir -p " .. ROOT .. "/logs/demos")
        log = io.open(LOG, "w")
    end

    local counts = {}
    local filled = 0
    local min_row = ROW_HI + 1
    for row = ROW_LO, ROW_HI do
        for col = COL_LO, COL_HI do
            local c = tile_code(row, col)
            counts[c] = (counts[c] or 0) + 1
            if c ~= 0 then filled = filled + 1 end
            if c ~= 0 and row < min_row then min_row = row end
        end
    end
    local bg, bg_n = 0, -1
    for c, n in pairs(counts) do
        if n > bg_n then bg_n = n; bg = c end
    end
    local piece_cells = 0
    for row = ROW_LO, math.min(min_row + 4, ROW_HI) do
        for col = COL_LO, COL_HI do
            if tile_code(row, col) ~= bg then piece_cells = piece_cells + 1 end
        end
    end

    local hash = 0
    for row = ROW_LO, ROW_HI do
        for col = COL_LO, COL_HI do
            hash = (hash * 31 + tile_code(row, col)) % 2147483647
        end
    end
    log:write(string.format(
        '{"f":%d,"bg":%d,"filled":%d,"min_row":%d,"piece_zone":%d,"hash":%d}\n',
        frame, bg, filled, min_row, piece_cells, hash
    ))
    log:flush()

    if frame > 3600 then
        log:close()
        manager.machine:exit()
    end
end)
