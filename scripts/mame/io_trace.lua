-- MAME 0.289 Lua: nost 68000 I/O and video traffic with frame/line/dot stamps.
--   NOST_OUT     output file (default io_trace.txt)
--   NOST_FRAMES  frames to run (default 600)
--   NOST_INPUTS  optional "frame:port:field:value;..." input script
-- Logged individually: tilemap regs 0x200000/0x300000, vidregs/watchdog 0xB00000-0xB0001F,
-- sound latch 0xC00000, inputs 0x800000/0xA00000, reads of unmapped space. Summarized per frame:
-- tile RAM, palette and sprite RAM write counts (with first/last line), ROM page coverage
-- (4 KB pages read: opcode fetches and data) written at the end.
if _G.nost_io_trace then return end          -- MAME re-runs autoboot scripts after a reset
_G.nost_io_trace = true
local m = manager.machine
local out = io.open(os.getenv("NOST_OUT") or "io_trace.txt", "w")
local frames = tonumber(os.getenv("NOST_FRAMES") or "600")
local scr = m.screens[":screen"]
local sp = m.devices[":maincpu"].spaces["program"]
local FP, SP, PP = scr.frame_period, scr.scan_period, scr.pixel_period
local inputs = {}
for f, port, field, v in string.gmatch(os.getenv("NOST_INPUTS") or "", "(%d+):([^:]+):([^:]+):(%d+)") do
  inputs[#inputs + 1] = {frame = tonumber(f), port = port, field = field, value = tonumber(v)}
end
local function beam()
  local e = (FP - scr:time_until_pos(0, 0)) % FP
  local v = math.floor(e / SP + 1e-9)
  return v, math.floor((e - v * SP) / PP + 1e-9)
end
local function stamp() local v, h = beam(); return string.format("%5d %3d %3d", scr:frame_number(), v, h) end
local function pc() return m.devices[":maincpu"].state["PC"].value end
local cnt = {}
local function bump(k) local v, h = beam(); local c = cnt[k]
  if not c then c = {n = 0, first = v, last = v}; cnt[k] = c end
  c.n = c.n + 1; c.last = v end
local pages = {}
taps = {}
local function W(a, b, name, f) taps[#taps + 1] = sp:install_write_tap(a, b, name, f) end
local function R(a, b, name, f) taps[#taps + 1] = sp:install_read_tap(a, b, name, f) end
local function logw(tag) return function(off, data, mask)
  out:write(string.format("%s W %06x %04x %04x %s pc=%06x\n", stamp(), off, data, mask, tag, pc())) end end
local function logr(tag) return function(off, data, mask)
  out:write(string.format("%s R %06x %04x %04x %s pc=%06x\n", stamp(), off, data, mask, tag, pc())) end end
R(0x000000, 0x0fffff, "rom", function(off) pages[off >> 12] = (pages[off >> 12] or 0) + 1 end)
W(0x200000, 0x2fffff, "tm0", logw("TM0")); R(0x200000, 0x2fffff, "tm0r", logr("TM0"))
W(0x300000, 0x3fffff, "tm1", logw("TM1")); R(0x300000, 0x3fffff, "tm1r", logr("TM1"))
W(0x400000, 0x4fffff, "vr0", function(off) bump(off < 0x401000 and "VRAM0" or off < 0x401800 and "LINE0" or "SCR0") end)
W(0x500000, 0x5fffff, "vr1", function(off) bump(off < 0x501000 and "VRAM1" or off < 0x501800 and "LINE1" or "SCR1") end)
W(0x600000, 0x6fffff, "pal", function(off) bump(off < 0x602000 and "PAL" or "PALX") end)
W(0x700000, 0x7fffff, "spr", function(off) bump(off < 0x708000 and "SPR" or "SPRX") end)
R(0x800000, 0x8fffff, "in", logr("IN")); R(0xa00000, 0xafffff, "dsw", logr("DSW"))
W(0x800000, 0xafffff, "inw", logw("INW"))
local logvid = logw("VID")
W(0xb00000, 0xbfffff, "vid", function(off, data, mask) if off == 0xb00018 then bump("WDOG") else logvid(off, data, mask) end end); R(0xb00000, 0xbfffff, "vidr", logr("VID"))
W(0xc00000, 0xffffff, "snd", logw("SND")); local logsnd = logr("SND")
R(0xc00000, 0xffffff, "sndr", function(off, data, mask) if off == 0xc00000 then bump("LATCH2_RD") else logsnd(off, data, mask) end end)
R(0x110000, 0x1fffff, "unm", logr("UNMAPPED"))
W(0x110000, 0x1fffff, "unmw", logw("UNMAPPED"))
resetsub = emu.add_machine_reset_notifier(function()
  out:write(string.format("%s RESET\n", stamp())) end)
emu.register_frame_done(function()
  local fn = scr:frame_number()
  for _, e in ipairs(inputs) do
    if e.frame == fn then
      local f = m.ioport.ports[":" .. e.port].fields[e.field]
      if f.type_class == "dipswitch" or f.type_class == "config" then f.user_value = e.value else f:set_value(e.value) end
    end
  end
  local ks = {}
  for k, _ in pairs(cnt) do ks[#ks + 1] = k end
  table.sort(ks)
  for _, k in ipairs(ks) do local c = cnt[k]
    out:write(string.format("%5d SUM %s n=%d lines %d-%d\n", fn, k, c.n, c.first, c.last)) end
  cnt = {}
  if fn >= frames then
    local ps = {}
    for p, n in pairs(pages) do ps[#ps + 1] = p end
    table.sort(ps)
    for _, p in ipairs(ps) do out:write(string.format("ROMPAGE %06x %d\n", p << 12, pages[p])) end
    out:close(); m:exit()
  end
end)
