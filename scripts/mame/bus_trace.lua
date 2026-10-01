-- MAME 0.289 Lua: 68000 bus transactions of nost (reads incl. opcode fetches, writes), one line
-- each: "R|W address data mask" (address = word address * 2). Logging starts after NOST_RESETS
-- machine resets (default 1: the watchdog reset at 3.0 s that ends the cold-boot 'nost' wait;
-- MAME re-runs this script after each reset) and stops after NOST_N transactions.
-- Output: $NOST_OUT. Reference for sim/tb/tb_boot.sv.
_G.nost_runs = (_G.nost_runs or 0) + 1
if _G.nost_runs <= tonumber(os.getenv("NOST_RESETS") or "1") then return end
local out = io.open(os.getenv("NOST_OUT") or "bus_trace.txt", "w")
local n, max = 0, tonumber(os.getenv("NOST_N") or "20000")
local sp = manager.machine.devices[":maincpu"].spaces["program"]
local scr = manager.machine.screens[":screen"]
local FP, SP = scr.frame_period, scr.scan_period
local function log(kind, off, data, mask)
  if n < max then
    out:write(string.format("%s %06x %04x %04x\n", kind, off & 0xfffffe, data & 0xffff, mask & 0xffff))
    n = n + 1
    if n == max then out:close() end
  end
end
rt = sp:install_read_tap(0x000000, 0xffffff, "r", function(off, data, mask) log("R", off, data, mask) end)
wt = sp:install_write_tap(0x000000, 0xffffff, "w", function(off, data, mask) log("W", off, data, mask) end)
emu.register_frame_done(function() if n >= max then manager.machine:exit() end end)
