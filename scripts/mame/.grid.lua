
local LOG="/tmp/atetris_grid.log"
local in0=manager.machine.ioport.ports[":IN0"]
local in1=manager.machine.ioport.ports[":IN1"]
local mem=manager.machine.devices[":maincpu"].spaces["program"]
local frame=0
local function tile(r,c)
  local a=0x1000+(r*64+c)*2
  return mem:read_u8(a)|((mem:read_u8(a+1)&7)<<8)
end
io.open(LOG,"w"):write("grid\n"):close()
emu.register_frame_done(function()
  frame=frame+1
  if frame==60 then in0:field(0x2):set_value(1)
  elseif frame==75 then in0:field(0x2):set_value(0)
  elseif frame>=120 and frame<=200 then in1:field(0x1):set_value(1)
  elseif frame==210 then in1:field(0x1):set_value(0)
  elseif frame==250 then
    local f=io.open(LOG,"a")
    -- dump wider area
    for row=0,29 do
      local line=string.format("%02d ",row)
      for col=0,39 do
        local t=tile(row,col)
        if t==0 then line=line.."."
        elseif t<16 then line=line..string.format("%x",t)
        else line=line.."#" end
      end
      f:write(line.."\n")
    end
    f:close()
    manager.machine:exit()
  end
end)
