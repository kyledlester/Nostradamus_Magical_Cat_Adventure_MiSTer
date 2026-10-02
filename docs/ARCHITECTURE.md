# Architecture

One core for both LINDA games: the MRA's ioctl index 1 byte selects Magical Cat Adventure
(`nost_core.mcat`), which changes only the Z80 memory map and mix level (`nost_sound`), unused input
and DIP bits (`nost_core`), the tile-code wrap (`nost_tilemap`, `nost_tilemap_cave`) and the
screen rotation (top level); everything else is shared, as in MAME's driver.

```
                 clk_sys 98.058240 MHz (nost_pll) - main board and video are clock enables of it
 HPS ioctl ──► nost_loader ──► nost_sdram_arb ◄── 68000 ROM cache (nost_rom_cache, in nost_main)
                                  ▲   ▲   ▲     ◄── ADPCM-A / Z80 ROM line caches (nost_sound)
                                  │   │   └──── ◄── nost_tilemap or nost_tilemap_cave (038 x2, OSD)
                                  │   └──────── ◄── nost_sprites
                             sdram.sv (ch1, 4-word bursts) ─── SDRAM 32 MB
 nost_main (FX68K 16 MHz, BRAM work/tile/palette/sprite RAM, I/O, IRQ1, watchdog, sprite-half copy)
   ├─ tile RAM / line RAM / 038 registers (live) ─► nost_tilemap
   ├─ sprite display buffer (copied at vblank) ───► nost_sprites
   ├─ palette (second port) ──────────────────────► nost_video mixer ─► rgb
   └─ sound latch / latch 2 ◄────────────────────► nost_sound (clk_snd = clk_sys/2: T80 4 MHz,
                                                     jt10 YM2610 8 MHz) ─► mono audio
 nost_video_timing (456 x 256 @ ce_pix = clk/14) ─► vblank at line 224: IRQ1 + sprite copy
 Nostradamus.sv: hps_io, pause, CRT Adjust, screen_rotate (ROT270 -> CCW, DDR3 FB), arcade_video
```

## Clocks

| Enable | Rate | Derivation |
| --- | --- | --- |
| ce_pix | 7.004160 MHz | clk_sys / 14, jitter-free |
| tick32 | 32 MHz average | fractional 3125/9576 of clk_sys (3-4 clocks apart) |
| phi1/phi2 | 16 MHz 68000 | alternate tick32 |
| ce_8m | 8 MHz average | fractional 3125/19152 of clk_snd (YM2610) |
| ce_4m | 4 MHz | ce_8m / 2 (Z80) |

`pause` freezes the emulated time bases, the vblank interrupt/copy and the watchdog; the raster keeps
running.

## Memory

| Data | Resource |
| --- | --- |
| 68000 program 1 MB | SDRAM, 32 KB direct-mapped cache of 8-byte lines (hit = zero wait states) |
| work RAM 64 KB, tile RAM 2 x 8 KB, palette 12 KB, sprite RAM 64 KB, sprite buffer 16 KB | BRAM |
| Z80 program 256 KB | SDRAM, 4 KB cache in the sound domain (miss -> WAIT_n) |
| Z80 RAM 8 KB | BRAM |
| sprite ROM 5 MB, tile ROMs 2 x 1.5 MB, ADPCM-A 1 MB | SDRAM (docs/ROM_LAYOUT.md) |

## Bus timing

The 68000 bus uses the owner's NA-1 / R-Shark FX68K transport (held request, registered DTACK) and a
backend that answers RAM reads and ROM cache hits after 2 clocks and writes immediately: every bus
cycle is 4 CPU clocks, as MAME (which has no wait states). A ROM cache miss costs ~15-25 clk_sys
(1-2 wait states at 16 MHz). Sprite RAM writes to entries not yet copied by the vblank copy wait
for it (the copy is an atomic snapshot like MAME's).

## Video

docs/VIDEO.md. Line-buffered renderer, one line ahead of the raster; the busiest measured line uses
2561 of 6384 clocks.

## Verification benches (`scripts/sim.sh <test>`)

| Bench | What |
| --- | --- |
| `loader` | full MRA stream through loader + arbiter + sdram.sv + chip model == romtool SDRAM image |
| `boot` / `bootc` | FX68K + nost_main bus transactions vs MAME (zero-wait ROM / production cache); `+WDTEST` cold boot through the watchdog reset |
| `render` | video path (engines, arbiter, sdram.sv, chip model) renders captured MAME frames pixel-exactly |
| `sound` | Z80 + jt10 + caches: Z80 I/O writes vs MAME in order, audio vs MAME |
| `system` / `systemns` | whole board (with / without the sound board); `+SNAP` starts from a MAME snapshot |
| `refrender.py` | Python executable spec of the video, pixel-exact on all captured MAME frames |
| `romtool.py` | ROM regions byte-exact vs MAME; MRA stream check |
