local ROOT = "/Users/pablo/Documents/arcade-ai"
local LOG = ROOT .. "/logs/demos/atetris_scan.jsonl"
local PF_BASE = 0x1000
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local frame = 0
local log = nil

local function tile_code(row, col)
    local idx = row * 64 + col
    local addr = PF_BASE + idx * 2
    return mem:read_u8(addr) | ((mem:read_u8(addr + 1) & 7) << 8)
end

local function full_hash(r0, r1, c0, c1)
    local h = 0
    for row = r0, r1 do
        for col = c0, c1 do
            h = (h * 33 + tile_code(row, col)) % 2147483647
        end
    end
    return h
end

emu.register_frame_done(function()
    frame = frame + 1
    if frame % 20 ~= 0 then return end
    if not log then
        os.execute("mkdir -p " .. ROOT .. "/logs/demos")
        log = io.open(LOG, "w")
    end
    log:write(string.format(
        '{"f":%d,"all":%d,"play10_31":%d,"play0_63":%d,"rows8_24":%d}\n',
        frame,
        full_hash(0, 31, 0, 63),
        full_hash(2, 29, 10, 31),
        full_hash(0, 31, 0, 63),
        full_hash(8, 24, 12, 27)
    ))
    log:flush()
    if frame > 2400 then log:close(); manager.machine:exit() end
end)
