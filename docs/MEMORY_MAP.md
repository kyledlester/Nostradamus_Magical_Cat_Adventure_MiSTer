# Memory map

From MAME 0.289 `mcatadv_state::main_map` (both games), `nost_sound_map`, `nost_sound_io_map`,
`mcatadv_sound_map`, `mcatadv_sound_io_map`
(`src/mame/misc/mcatadv.cpp`), implemented in `rtl/nost/nost_main.sv` and `rtl/nost/nost_sound.sv`.

## 68000 (16 MHz)

| Address | R/W | Contents | FPGA |
| --- | --- | --- | --- |
| 000000-0FFFFF | R | program ROM (`nos-pe-u` even, `nos-po-u` odd) | SDRAM 0x0000000 through a 32 KB direct-mapped cache |
| 100000-10FFFF | RW | work RAM | BRAM 64 KB (kept across the watchdog reset) |
| 200000-200005 | RW | 038 #0 registers: 0 = {flip X\*, row scroll, -, scroll X[8:0]}, 1 = {flip Y\*, row select, 16x16, -, scroll Y[8:0]}, 2 = {-, disable, colour bank[3:0]} (\* 0 = flipped) | registers |
| 300000-300005 | RW | 038 #1 registers | registers |
| 400000-400FFF | RW | 038 #0 tile map: 32 x 32 entries of {word0 = cat[15:14], colour[13:8]; word1 = code} | BRAM 8 KB (with the next two) |
| 401000-4017FF | RW | 038 #0 line RAM: 512 x {row scroll, row select} | |
| 401800-401FFF | RW | 038 #0 "scratchpad" RAM | |
| 500000-501FFF | RW | 038 #1 tile map, line RAM, scratch | BRAM 8 KB |
| 600000-601FFF | RW | palette, 4096 x xGRB_555 | BRAM 8 KB, second port to the video mixer |
| 602000-602FFF | RW | RAM | BRAM 4 KB |
| 700000-707FFF | RW | sprite RAM, two halves of 2048 x 4 words | BRAM (4 word banks); vblank copy of one half to a 16 KB display buffer |
| 708000-70FFFF | RW | RAM ("tests more than is needed?") | BRAM 32 KB |
| 800000 | R | P1 (active low): 0 up, 1 down, 2 left, 3 right, 4 button 1, 5/6 nost: unknown (buttons 2/3 in test mode), mcatadv: jump / button 3 (test mode), 7 start 1, 8 coin 1, 9 unknown; nost: **11 active high, reads 0**; mcatadv: 9-15 read 1 | joystick 0 |
| 800002 | R | P2: as P1 with 7 start 2, 8 coin 2, **9 SERVICE1** (mcatadv: bit 6 unknown, reads 1) | joystick 1 (service: either player) |
| A00000 | R | DSW1 = {SW1, 0x00} (mcatadv: {SW1, 0xFF}) | MRA DIP byte 0 |
| A00002 | R | DSW2 = {SW2, 0x00} (mcatadv: {SW2, 0xFF}) | MRA DIP byte 1 |
| B00000-B0000F | RW | vidregs (buffered at vblank; word 0/1 live = sprite X/Y offsets + 0x184/0x1F1, word 2 buffered = sprite half) | registers |
| B00018 | W | watchdog reset (used by Nostradamus) | 3 s watchdog (MAME guess) |
| B0001E | R | watchdog reset (used by Magical Cat), returns 0x0C00 | both games: MAME maps both |
| C00000 | W | sound latch (low byte; MAME umask 0x00FF) -> Z80 NMI | |
| C00001 | R | latch 2 (Z80 -> 68000); a word read returns {0x00, latch 2} | |
| other | | unmapped: reads 0, writes ignored (Nostradamus writes 0x900000 once: Magical Cat's coin counter / lockout, unmapped in MAME) | |

Interrupts: IRQ1 (autovector) at vblank start (line 224), held until acknowledged.

## Z80 (4 MHz), Nostradamus (`nost_sound_map` / `nost_sound_io_map`)

| Address | Contents | FPGA |
| --- | --- | --- |
| 0000-7FFF | ROM (first 32 KB of `nos-ps.u9`) | block RAM copy written by the loader (no wait states) |
| 8000-BFFF | ROM bank: page n (16 KB) of the 256 KB ROM, n = port 40 (MAME starts with page 1) | SDRAM 0x0100000 through a 4 KB cache with next-line prefetch (WAIT_n on a miss) |
| C000-DFFF | RAM | BRAM 8 KB |

| Port (A7-A0) | R/W | Contents |
| --- | --- | --- |
| 00-03 | W | YM2610 (address/data, part 0 and 1) |
| 04-07 | R | YM2610 (status 0, data, status 1, -) |
| 40 | W | ROM bank |
| 80 | R | sound latch (clears NMI) |
| 80 | W | latch 2 |

## Z80 (4 MHz), Magical Cat Adventure (`mcatadv_sound_map` / `mcatadv_sound_io_map`)

| Address | R/W | Contents | FPGA |
| --- | --- | --- | --- |
| 0000-3FFF | R | ROM (first 16 KB of `u9.bin`) | block RAM copy |
| 4000-BFFF | R | ROM window: 32 KB from page n * 16 KB of the 128 KB ROM (MAME starts with page 1) | SDRAM cache as above |
| C000-DFFF | RW | RAM | BRAM 8 KB |
| E000-E003 | RW | YM2610 (write: address/data part 0/1; read: status 0, data, status 1, -) | |
| F000 | W | ROM bank n | |

| Port (A7-A0) | R/W | Contents |
| --- | --- | --- |
| 80 | R | sound latch (clears NMI) |
| 80 | W | latch 2 |

NMI = sound latch pending; INT = YM2610 IRQ (the program runs IM 1 with a bare RETI at 0x38 and
polls the YM2610 timers through port 04 instead).
