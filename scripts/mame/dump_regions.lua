-- MAME 0.289 Lua: dump nost ROM regions as MAME holds them (byte order of the region memory;
-- maincpu is read as big-endian 16-bit words). Output dir: $NOST_OUT.
local dir = os.getenv("NOST_OUT")
local regs = {maincpu="maincpu", soundcpu="soundcpu", sprdata="sprdata", bg0="bg0", bg1="bg1",
              adpcma="ymsnd:adpcma"}
for name, tag in pairs(regs) do
  local r = manager.machine.memory.regions[":" .. tag]
  local f = io.open(dir .. "/" .. name .. ".bin", "wb")
  local t = {}
  if name == "maincpu" then
    for i = 0, r.size - 2, 2 do local w = r:read_u16(i); t[#t+1] = string.char(w >> 8, w & 0xff)
      if #t >= 4096 then f:write(table.concat(t)); t = {} end end
  else
    for i = 0, r.size - 1 do t[#t+1] = string.char(r:read_u8(i))
      if #t >= 8192 then f:write(table.concat(t)); t = {} end end
  end
  f:write(table.concat(t)); f:close()
end
manager.machine:exit()
