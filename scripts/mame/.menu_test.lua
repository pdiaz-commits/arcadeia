
local LOG = "/Users/pablo/Documents/arcade-ai/logs/atetris_menu_test.log"
local in0 = manager.machine.ioport.ports[":IN0"]
local in1 = manager.machine.ioport.ports[":IN1"]
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local PF_BASE = 0x1000
local frame = 0
local function log(msg)
  local f = io.open(LOG, "a")
  if f then f:write(string.format("f%d %s\n", frame, tostring(msg))); f:close() end
end
local function tile(row, col)
  local addr = PF_BASE + (row * 64 + col) * 2
  return mem:read_u8(addr) | ((mem:read_u8(addr + 1) & 7) << 8)
end
io.open(LOG, "w"):write("menu_test2\n"):close()
emu.register_frame_done(function()
  local ok, err = pcall(function()
    frame = frame + 1
    if frame == 1 then log("frame1 ok") end
    in0:field(0x2):set_value(0)
    in1:field(0x1):set_value(0)
    in1:field(0x2):set_value(0)
    in1:field(0x4):set_value(0)
    in1:field(0x8):set_value(0)
    if frame == 60 then in0:field(0x2):set_value(1); log("coin")
    elseif frame == 75 then in0:field(0x2):set_value(0)
    elseif frame >= 120 and frame <= 200 then in1:field(0x1):set_value(1)
    elseif frame == 210 then
      local f = io.open(LOG, "a")
      for row = 8, 24 do
        local line = ""
        for col = 14, 27 do
          local t = tile(row, col)
          line = line .. (t == 0 and "." or (t < 16 and string.format("%x", t) or "#"))
        end
        f:write(line .. "\n")
      end
      f:close()
      log("grid dumped")
    elseif frame >= 230 and frame <= 350 then
      in1:field(0x4):set_value(1)
      in1:field(0x2):set_value(1)
    elseif frame == 360 then
      local f = io.open(LOG, "a")
      f:write("AFTER R+D\n")
      for row = 8, 24 do
        local line = ""
        for col = 14, 27 do
          local t = tile(row, col)
          line = line .. (t == 0 and "." or (t < 16 and string.format("%x", t) or "#"))
        end
        f:write(line .. "\n")
      end
      f:close()
      log("second grid")
    end
    if frame % 30 == 0 then
      local nz,h=0,0
      for row=8,24 do for col=14,27 do
        local t=tile(row,col); h=(h*31+t)%2147483647; if t~=0 then nz=nz+1 end
      end end
      log(string.format("nz=%d hash=%d IN1=%02x", nz,h,in1:read()%256))
    end
    if frame > 400 then manager.machine:exit() end
  end)
  if not ok then log("ERR "..tostring(err)) end
end)
