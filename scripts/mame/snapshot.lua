-- MAME 0.289 Lua: snapshot of the nost 68000 board at the entry of the first IRQ1 handler of frame
-- NOST_SNAP (the first opcode fetch at the autovector-1 handler, 0x000898, after frame_done(NOST_SNAP)),
-- for sim/tb/tb_system.sv +SNAP (start the integrated simulation there instead of at reset).
--   NOST_OUT    output directory
--   NOST_SNAP   frame number
--   NOST_INPUTS optional input script as io_trace.lua (applied before the snapshot)
-- Files: regs.txt (D0-D7 A0-A6 SP USP SR PC, beam line/dot, frame), ram.bin (0x100000, 64 KB),
-- vram0.bin / vram1.bin (8 KB each), pal.bin (0x600000-0x602FFF), spr.bin (0x700000-0x70FFFF),
-- tmregs.bin (6 words), vidregs.bin (8 words); all big-endian words.
-- At the handler's first fetch the exception frame (SR, PC) is already on the stack at SP.
_G.nost_snap_runs = (_G.nost_snap_runs or 0) + 1
dofile((debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "") .. "bootpatch.lua")
if _G.nost_snap_runs > 1 and _G.nost_snap_done then return end
local m = manager.machine
local scr = m.screens[":screen"]
local cpu = m.devices[":maincpu"]
local sp = cpu.spaces["program"]
local dir = os.getenv("NOST_OUT")
local snap = tonumber(os.getenv("NOST_SNAP"))
local FP, SP, PP = scr.frame_period, scr.scan_period, scr.pixel_period
local inputs = {}
for f, port, field, v in string.gmatch(os.getenv("NOST_INPUTS") or "", "(%d+):([^:]+):([^:]+):(%d+)") do
  inputs[#inputs + 1] = {frame = tonumber(f), port = port, field = field, value = tonumber(v)}
end
local function words(base, n)
  local t = {}
  for i = 0, n - 1 do local w = sp:read_u16(base + 2 * i); t[#t + 1] = string.char(w >> 8, w & 0xff) end
  return table.concat(t)
end
local function wfile(path, data) local f = io.open(path, "wb"); f:write(data); f:close() end
local armed = false
if _G.nost_snap_runs == 1 then
  emu.register_frame_done(function()
    local fn = scr:frame_number()
    for _, e in ipairs(inputs) do
      if e.frame == fn then
        local f = m.ioport.ports[":" .. e.port].fields[e.field]
        if f.type_class == "dipswitch" or f.type_class == "config" then f.user_value = e.value else f:set_value(e.value) end
      end
    end
    if fn == snap then armed = true end
  end)
  _G.nost_tap = sp:install_read_tap(0x000898, 0x000899, "snap", function(off, data, mask)
    if not armed or _G.nost_snap_done then return end
    _G.nost_snap_done = true
    local e = (FP - scr:time_until_pos(0, 0)) % FP
    local v = math.floor(e / SP + 1e-9)
    local h = math.floor((e - v * SP) / PP + 1e-9)
    os.execute('mkdir "' .. dir:gsub("/", "\\") .. '" 2>nul')
    local f = io.open(dir .. "/regs.txt", "w")
    for _, r in ipairs({"D0","D1","D2","D3","D4","D5","D6","D7","A0","A1","A2","A3","A4","A5","A6","SP","USP","SR","PC"}) do
      f:write(string.format("%s %08x\n", r, cpu.state[r].value))
    end
    f:write(string.format("frame %d line %d dot %d\n", scr:frame_number(), v, h))
    f:close()
    wfile(dir .. "/ram.bin", words(0x100000, 0x8000))
    wfile(dir .. "/vram0.bin", words(0x400000, 0x1000))
    wfile(dir .. "/vram1.bin", words(0x500000, 0x1000))
    wfile(dir .. "/pal.bin", words(0x600000, 0x1800))
    wfile(dir .. "/spr.bin", words(0x700000, 0x8000))
    wfile(dir .. "/tmregs.bin", words(0x200000, 3) .. words(0x300000, 3))
    wfile(dir .. "/vidregs.bin", words(0xb00000, 8))
    m:exit()
  end)
end
