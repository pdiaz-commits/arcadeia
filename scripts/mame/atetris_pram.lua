local ROOT = "/Users/pablo/Documents/arcade-ai"
local LOG = ROOT .. "/logs/demos/atetris_pram.jsonl"
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local in0 = manager.machine.ioport.ports[":IN0"]
local in1 = manager.machine.ioport.ports[":IN1"]
local frame = 0
local log = nil

local function pram_hash(a, b)
    local h = 0
    for addr = a, b do
        h = (h * 17 + mem:read_u8(addr)) % 2147483647
    end
    return h
end

emu.register_frame_done(function()
    frame = frame + 1
    if frame == 90 then in0:field(0x2):set_value(1)
    elseif frame == 100 then in0:field(0x2):set_value(0)
    elseif frame >= 140 and frame <= 320 then in1:field(0x1):set_value(1)
    elseif frame == 330 then in1:field(0x1):set_value(0)
    end
    if frame % 15 ~= 0 then return end
    if not log then
        os.execute("mkdir -p " .. ROOT .. "/logs/demos")
        log = io.open(LOG, "w")
    end
    log:write(string.format(
        '{"f":%d,"p000":%d,"p400":%d,"p800":%d,"v1000":%d,"coin":%d,"btn":%d}\n',
        frame,
        pram_hash(0x000, 0x0ff),
        pram_hash(0x400, 0x4ff),
        pram_hash(0x800, 0x8ff),
        pram_hash(0x1000, 0x10ff),
        in0:field(0x2).live and in0:field(0x2).live.value or -1,
        in1:field(0x1).live and in1:field(0x1).live.value or -1
    ))
    log:flush()
    if frame > 3000 then log:close(); manager.machine:exit() end
end)
