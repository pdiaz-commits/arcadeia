local out = io.open("/Users/pablo/Documents/arcade-ai/logs/iofields.txt", "w")
local p1 = manager.machine.ioport.ports[":P1"]
local sys = manager.machine.ioport.ports[":SYSTEM"]
if out and p1 and p1.fields then
    out:write("P1:\n")
    for k, f in pairs(p1.fields) do
        local ok, name = pcall(function() return f:name() end)
        out:write(string.format("  key=%s mask=0x%x name=%s\n", tostring(k), f.mask or 0, ok and name or "?"))
    end
end
if out and sys and sys.fields then
    out:write("SYSTEM:\n")
    for k, f in pairs(sys.fields) do
        local ok, name = pcall(function() return f:name() end)
        out:write(string.format("  key=%s mask=0x%x name=%s\n", tostring(k), f.mask or 0, ok and name or "?"))
    end
end
if out then out:close() end
manager.machine:exit()
