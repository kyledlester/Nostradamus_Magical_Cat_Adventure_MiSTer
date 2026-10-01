-- MAME 0.289 Lua: nost sound traffic with timestamps (microseconds since machine start).
--   M <t> <value>            68000 sound-latch write (0xC00000 low byte)
--   Z <t> R|W <port> <value> Z80 I/O access (YM2610 00-07, bank 40, latches 80)
--   X <t> RESET              machine reset (the watchdog reset at 3 s)
-- Output $NOST_OUT, duration $NOST_SECONDS (default 20). Optional $NOST_INPUTS as io_trace.lua.
if _G.nost_sound_trace then return end
_G.nost_sound_trace = true
local m = manager.machine
local out = io.open(os.getenv("NOST_OUT") or "sound_trace.txt", "w")
local stop = tonumber(os.getenv("NOST_SECONDS") or "20")
local scr = m.screens[":screen"]
local inputs = {}
for f, port, field, v in string.gmatch(os.getenv("NOST_INPUTS") or "", "(%d+):([^:]+):([^:]+):(%d+)") do
  inputs[#inputs + 1] = {frame = tonumber(f), port = port, field = field, value = tonumber(v)}
end
local function t() return m.time:as_double() * 1e6 end
local msp = m.devices[":maincpu"].spaces["program"]
local zio = m.devices[":soundcpu"].spaces["io"]
t1 = msp:install_write_tap(0xc00000, 0xc00001, "lat", function(o, d, mk)
  if (mk & 0xff) ~= 0 then out:write(string.format("M %.3f %02x\n", t(), d & 0xff)) end end)
t2 = zio:install_read_tap(0x00, 0xff, "zr", function(o, d, mk)
  out:write(string.format("Z %.3f R %02x %02x\n", t(), o & 0xff, d & 0xff)) end)
t3 = zio:install_write_tap(0x00, 0xff, "zw", function(o, d, mk)
  out:write(string.format("Z %.3f W %02x %02x\n", t(), o & 0xff, d & 0xff)) end)
rs = emu.add_machine_reset_notifier(function() out:write(string.format("X %.3f RESET\n", t())) end)
emu.register_frame_done(function()
  local fn = scr:frame_number()
  for _, e in ipairs(inputs) do
    if e.frame == fn then
      local f = m.ioport.ports[":" .. e.port].fields[e.field]
      if f.type_class == "dipswitch" or f.type_class == "config" then f.user_value = e.value else f:set_value(e.value) end
    end
  end
  if m.time:as_double() >= stop then out:close(); m:exit() end
end)
