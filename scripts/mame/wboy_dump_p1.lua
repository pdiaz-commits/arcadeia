-- Dump P1 port fields for wboy
local p1 = manager.machine.ioport.ports[":P1"]
local LOG = "/Users/pablo/Documents/arcade-ai/logs/wboy_p1_fields.log"
local f = io.open(LOG, "w")
if p1 and p1.fields then
    for name, field in pairs(p1.fields) do
        if f then f:write(tostring(name) .. "\n") end
    end
end
if f then f:close() end

local frame = 0
emu.register_frame_done(function()
    frame = frame + 1
    if frame == 120 then manager.machine:exit() end
end)
