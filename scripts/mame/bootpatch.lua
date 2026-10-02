-- Simulation-acceleration ROM patches (NOT part of the core): applied identically to MAME (this
-- file, when NOST_BOOTPATCH is set) and to the FPGA bench's SDRAM image (tb_system +BOOTPATCH), so
-- both still compute the same thing while the boot reaches attract mode ~13 s sooner:
--   68000 0x000162: cmpa.l #$040000 (ROM checksum over 256 KB instead of 1 MB: ~0.5 s, so the
--                   sound handshake still comes long after the Z80 has initialised)
--   68000 0x00016A, 0x000174: beq -> bra (the shortened sums count as correct)
--   68000 0x00026A: bra $422        (skip the RAM tests; D7 = 0 = "RAM OK")
--   Z80   0x0005F9: jp  $0604       (skip the Z80 ROM checksum; reports 0x80 = "OK")
if os.getenv("NOST_BOOTPATCH") then
  local mc = manager.machine.memory.regions[":maincpu"]
  local zc = manager.machine.memory.regions[":soundcpu"]
  -- NOST_BOOTPATCH=2: checksum over 64 KB (~0.13 s; still after the Z80's ~42 ms start-up)
  mc:write_u8(0x163, os.getenv("NOST_BOOTPATCH") == "2" and 0x01 or 0x04)
  mc:write_u8(0x16a, 0x60); mc:write_u8(0x174, 0x60)
  mc:write_u8(0x26a, 0x60); mc:write_u8(0x26b, 0x00); mc:write_u8(0x26c, 0x01); mc:write_u8(0x26d, 0xb6)
  zc:write_u8(0x5f9, 0xc3); zc:write_u8(0x5fa, 0x04); zc:write_u8(0x5fb, 0x06)
end
