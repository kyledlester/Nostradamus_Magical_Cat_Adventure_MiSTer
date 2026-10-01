# Audio

Reference: MAME 0.289 `mcatadv.cpp` (`nost` machine config, `nost_sound_map`, `nost_sound_io_map`),
`devices/sound/ymopn.cpp` + ymfm (`ymfm_opn.cpp`, `ymfm_ssg.cpp`, `ymfm_adpcm.cpp`),
`devices/machine/gen_latch.cpp`. RTL: `rtl/nost/nost_sound.sv`.

## Board

| Part | MAME | FPGA |
| --- | --- | --- |
| Z80 | 4 MHz (16 MHz / 4, "verified on PCB") | T80s, ce_4m = ce_8m / 2 in clk_snd (49.03 MHz) |
| YM2610 (board: YMF286-K + Y3016-F) | 8 MHz (16 MHz / 2, "verified on PCB"), ymfm | jt10 (jotego jt12), cen 8 MHz |
| ADPCM-A ROM | `nossn-00.u53`, 1 MB | SDRAM 0x0200000 behind a 32-line cache |
| ADPCM-B | no region | data 0 (the game never uses it) |
| sound latch | generic_latch_8, data_pending -> Z80 NMI | latch + pending flag (cleared by the Z80 read) |
| latch 2 | generic_latch_8, Z80 port 80 -> 68000 0xC00001 | register |
| ROM bank | port 40, 16 KB pages, initial page 1 | 4-bit register, not reset (MAME sets it in machine_start only) |

The Z80 program (IM 1, `reti` at 0x38) does all work from the NMI command path and polls the YM2610
timers through port 04 (4.5 million status reads in 40 s of MAME time). It echoes every command to
latch 2; at boot it answers the 68000's command 0x01 with 0x01, checksums ROM banks 2-7 and reports
0x80 (bit 7 = done, bits 0/1 = errors). Attract mode starts the music with command 0x05 at 16.37 s.

Registers used (MAME trace, 40 s): FM channels 1, 2, 5, 6 (the four YM2610 FM channels), SSG
(volumes 8-A, tones 0-5), ADPCM-A (part 1 registers 00-2D), timers (27: 9191 writes). ADPCM-B
(part 0 10-1C) is never written.

## Mix

MAME routes for `nost`: output 0 (SSG) x 0.6, outputs 1 and 2 (FM + ADPCM, left and right) x 0.5
each, into one mono speaker. ymfm's SSG output is (a + b + c) * 2 / 3 with channel amplitudes
0..16382 (positive only). jt10's SSG channels are 8-bit levels (0..255), so one level step is
~64.25 ymfm units:

```
mono = (A + B + C) * 25.7 + (L + R) / 2      (RTL: ((A+B+C) * 1645 + (L+R) * 32) >> 6, saturated)
```

The FM/ADPCM balance inside jt10 follows the chip (jt10's own accumulator); MAME's ymfm sums FM
(13-bit, no intermediate clipping) and ADPCM-A then clamps to 16 bits.

## Timing differences against MAME

* The Z80 program ROM is in SDRAM; a cache miss holds WAIT_n for ~0.5 us (MAME: no waits). The
  4 KB cache keeps misses rare after start-up.
* After any reset the sound board stays in reset ~84 us longer than the 68000 (jt10 needs a long
  reset); MAME releases both at once.
* jt10's YM2610 busy flag duration and timer phases are the chip's; ymfm's are approximations.

## Verification

`scripts/sim.sh sound` (`sim/tb/tb_sound.sv`): MAME's latch writes replayed at MAME's times from
the watchdog reset on; every Z80 I/O write (YM2610, bank, latch 2) compared in order with MAME's.
`scripts/audiocheck.py` compares the bench's audio with `mame -wavwrite` (RMS ratio, 10 ms envelope
and log-spectrum correlation).
