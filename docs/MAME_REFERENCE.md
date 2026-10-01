# MAME reference

MAME is the executable behavioural specification. Facts measured from MAME are marked
**(measured)**; things MAME itself approximates are marked **(MAME approximation)**.

| Item | Value |
| --- | --- |
| MAME binary | 0.289 (`mame0289`), `C:\Users\klest\Downloads\mame\mame.exe` |
| MAME source | tag `mame0289`, commit `f34f02505e32c1993c6a782b6814232cbfc74e36`; files extracted to `local/mame_src/` (not committed) |
| Driver | `src/mame/misc/mcatadv.cpp` (`mcatadv_state`, machine `nost`) |
| Tilemap device | `src/devices/video/tmap038.cpp/.h` (`tilemap038_device`) |
| Also read | `src/emu/tilemap.h` (`tile_data::set`: code `%` elements, colour `%` colours), `devices/video/bufsprite.h`, `devices/machine/gen_latch.*`, `emu/screen.cpp` |
| ROM set | `nost.zip`, 14 files; `mame -verifyroms nost`: **romset nost is good** (CRCs in `scripts/romtool.py`) |
| Target | MiSTer DE10-Nano + 32 MB SDRAM module |
| Tools | Quartus Prime Lite 17.0.0 Build 595; ModelSim-Intel Starter 10.5b; Python 3.10.11 |

## Machine summary (`nost`, from the driver)

* 68000 @ 16 MHz (XTAL 16 MHz, "verified on PCB"); IRQ1 = `irq1_line_hold` at vblank start
  (autovector 1, held until acknowledged).
* Z80 @ 4 MHz (16 MHz / 4), `nost_sound_map` / `nost_sound_io_map` (differ from Magical Cat).
* YM2610 @ 8 MHz (board: YMF286-K + Y3016-F). Routes for `nost`: SSG (output 0) x 0.6, FM+ADPCM
  left/right (outputs 1, 2) x 0.5 each, mono speaker.
* Two 038 tilemap chips, 16x16 tile RAM map only (`vram_16x16_map`), line RAM for row scroll /
  row select; tile colour bank from each chip's register 2 low nibble.
* Sprites: `buffered_spriteram16` (32 KB, two 16 KB halves), drawn from ROM region `sprdata`.
* `vidregs` 0xB00000-0xB0000F: buffered (copied at vblank) - `buffer()[2]` selects the sprite
  half; the sprite global offsets use the **live** words 0 and 1.
* Screen: 320 x 256 logical raster, visible 320 x 224 (lines 0-223), 60 Hz, `set_vblank_time(0)`
  **(MAME approximation: the PCB raster has not been measured)**; ROT270.
* Watchdog: 3 s, written at 0xB00018 (`// a guess, and certainly wrong`) **(MAME approximation)**.

## Capture tooling (`scripts/mame/`)

MAME Lua autoboot scripts, run from the MAME directory, e.g.

```
mame nost -rompath roms -autoboot_script <repo>/scripts/mame/io_trace.lua -nothrottle -video none -sound none -skip_gameinfo
```

MAME re-runs an autoboot script after every machine reset (including the watchdog reset at 3 s),
so every script guards itself with a global flag. MAME 0.289 Lua has no `screen:vpos()`; the beam
is derived from `screen:time_until_pos(0,0)`, `frame_period` and `scan_period` (as in R-Shark).

| Script | Output |
| --- | --- |
| `dump_regions.lua` | MAME's ROM regions, compared byte-exact with `romtool.py regions` |
| `io_trace.lua` | every access to tilemap regs, inputs, vidregs, sound latch with frame/line/dot and PC; per-frame write counts and line windows for tile RAM, line RAM, palette, sprite RAM; watchdog writes and latch-2 reads counted; ROM page coverage |

## Established behaviours (measured)

### Boot

* **Cold boot needs the watchdog.** Reset vector PC = 0x104: if work RAM 0x10001C does not hold
  `'nost'` (0x6E6F7374) the program writes it there and spins (`bra *` at 0x11E) without touching
  any I/O, waiting for the watchdog to reset the CPU. Work RAM survives the watchdog reset. In MAME
  this costs 3.0 s (180 frames) - the watchdog guess. The real watchdog period is unknown.
* After the reset (frame 180): ROM checksum over 0x000000-0x0FFFFF with a watchdog write per byte
  pair (frames 180-305), then the sound handshake at 0x17C: writes 0x0001 to the sound latch,
  **waits for P1 bit 11 (0x0800) to read 0** (MAME: `IP_ACTIVE_HIGH` unknown bit, reads 0), waits
  for latch 2 = 0x01, then up to 0xB0000 polls for latch 2 bit 7 (Z80 self-test result, frames
  305-482), then RAM tests of 0x400000/0x500000/0x700000/0x600000/0x100000 (frames 490-980).
  Attract mode starts at frame 982.
* Unmapped 0x900000 (Magical Cat coin counter) is written once (0x0000) at init.

### Per-frame write timing in attract (frames 1000-4000)

| Target | When (beam line) | Notes |
| --- | --- | --- |
| tilemap regs 0x200000/2, 0x300000/2 | 224-244 (IRQ1 handler) | every frame; L0 0x8195 / 0xC1xx (row scroll on), 0xE1DF / 0xA1DF; L1 0x8194, 0xA1DF |
| tilemap reg 2 (0x200004 / 0x300004) | init only | L0 = 0x0001, L1 = 0x0003 (colour banks 1 and 3) |
| line RAM layer 0 | 243-253 | 224 entries per update |
| tile RAM | in vblank (columns of 28 writes at 252/253) | |
| palette | 224-244 | |
| sprite RAM 0x700000-0x707FFF | **all lines (0-250)** | the game double-buffers with 0xB00004 (0 / 1, toggled lines 11-46) |
| 0xB00008 / 0xB0000A | 0x0000 every frame | purpose unknown (no MAME handler beyond RAM) |
| 0xB00000 / 0xB00002 | init only: 0x0184 / 0x01F1 | sprite global X / Y (MAME subtracts exactly these) |
| watchdog 0xB00018 | once per frame in attract | thousands per frame during the boot checksum |
| inputs 0x800000/2, DSW 0xA00000/2 | main loop | P1 reads 0xF7FF (bit 11 low) |
| sound latch 0xC00000 | 224-253 | latch 2 read back (polled) |

So in steady state everything the tilemaps use is written during vblank; a renderer reading tile
RAM / line RAM / registers live during lines 0-223 sees the same values MAME uses at its render
instant (vblank start, line 224).
