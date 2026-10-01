-- MAME 0.289 Lua: capture nost video state + rendered pixels at selected frames.
--   NOST_OUT     output directory (one subdirectory fNNNNN per frame)
--   NOST_FRAMES  comma-separated frame numbers, or "a-b/s" ranges (screen frame_number at frame_done)
--   NOST_INPUTS  optional script "frame:port:field:value;..." e.g. "1200:P1:Coin 1:1;1206:P1:Coin 1:0"
-- Per frame (state at frame_done = MAME's render instant, vblank start, line 224):
--   pixels.bin   320x224 ARGB32 LE, MAME's rendered visible area (see the delay note below)
--   palette.bin  0x1000 BE words (0x600000)          vram0/1.bin 0x1000 BE words (0x400000/0x500000)
--   tmregs.bin   6 BE words: 038 #0 regs 0-2, 038 #1 regs 0-2 (live)
--   vidregs.bin  8 BE words live;  vidbuf.bin 8 BE words = vidregs at the previous frame_done
--   sprbuf.bin   0x4000 BE words = sprite RAM at the previous frame_done (the buffer MAME draws)
--   ram.bin      work RAM 64 KB (BE words)
-- Timing basis (src/emu/screen.cpp vblank_begin): frame_update() renders, THEN the vblank callbacks
-- run buffered_spriteram16_device::vblank_copy_rising (sprite RAM and vidregs). frame_done fires
-- inside frame_update, so "previous frame_done" contents are the buffers used for this frame.
-- screen:pixels() returns the previously completed bitmap, so the pixels of the frame rendered at
-- frame_done(N) are read at frame_done(N+1) (NOST_PIXDELAY=1, as established for R-Shark).
if _G.nost_capture then return end      -- MAME re-runs autoboot scripts after a (watchdog) reset
_G.nost_capture = true
local dir = os.getenv("NOST_OUT")
local want = {}
local last = 0
local pixdelay = tonumber(os.getenv("NOST_PIXDELAY") or "1")
for item in string.gmatch(os.getenv("NOST_FRAMES") or "", "[^,]+") do
  local a, b, s = item:match("^(%d+)-(%d+)/(%d+)$")
  if a then
    for f = tonumber(a), tonumber(b), tonumber(s) do want[f] = true; last = math.max(last, f) end
  else
    want[tonumber(item)] = true; last = math.max(last, tonumber(item))
  end
end
local inputs = {}
for f, port, field, v in string.gmatch(os.getenv("NOST_INPUTS") or "", "(%d+):([^:]+):([^:]+):(%d+)") do
  inputs[#inputs + 1] = {frame = tonumber(f), port = port, field = field, value = tonumber(v)}
end
local m = manager.machine
local scr = m.screens[":screen"]
local sp = m.devices[":maincpu"].spaces["program"]
local function words(base, n)
  local t = {}
  for i = 0, n - 1 do local w = sp:read_u16(base + 2 * i); t[#t + 1] = string.char(w >> 8, w & 0xff) end
  return table.concat(t)
end
local function wfile(path, data) local f = io.open(path, "wb"); f:write(data); f:close() end
local prev_spr = words(0x700000, 0x4000)
local prev_vid = words(0xb00000, 8)
emu.register_frame_done(function()
  local fn = scr:frame_number()
  for _, e in ipairs(inputs) do
    if e.frame == fn then
      local f = m.ioport.ports[":" .. e.port].fields[e.field]
      if f.type_class == "dipswitch" or f.type_class == "config" then f.user_value = e.value else f:set_value(e.value) end
    end
  end
  if want[fn - pixdelay] then
    wfile(string.format("%s/f%05d/pixels.bin", dir, fn - pixdelay), scr:pixels())
    wfile(string.format("%s/f%05d/palette_next.bin", dir, fn - pixdelay), words(0x600000, 0x1000))
  end
  if want[fn] then
    local d = string.format("%s/f%05d", dir, fn)
    os.execute('mkdir "' .. d:gsub("/", "\\") .. '" 2>nul')
    wfile(d .. "/palette.bin", words(0x600000, 0x1000))
    wfile(d .. "/vram0.bin", words(0x400000, 0x1000))
    wfile(d .. "/vram1.bin", words(0x500000, 0x1000))
    wfile(d .. "/tmregs.bin", words(0x200000, 3) .. words(0x300000, 3))
    wfile(d .. "/vidregs.bin", words(0xb00000, 8))
    wfile(d .. "/vidbuf.bin", prev_vid)
    wfile(d .. "/sprbuf.bin", prev_spr)
    wfile(d .. "/ram.bin", words(0x100000, 0x8000))
  end
  prev_spr = words(0x700000, 0x4000)
  prev_vid = words(0xb00000, 8)
  if fn >= last + pixdelay then m:exit() end
end)
