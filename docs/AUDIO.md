# Audio

Reference: MAME 0.289 `mcatadv.cpp` (`nost` machine config, `nost_sound_map`, `nost_sound_io_map`;
`mcatadv` machine config, `mcatadv_sound_map`, `mcatadv_sound_io_map` for Magical Cat Adventure),
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

* Z80 0000-7FFF (the program code) is in block RAM: no wait states, like the board's ROM. The bank
  window 8000-BFFF is read through a 4 KB SDRAM cache with next-line prefetch; a demand miss holds
  WAIT_n (~0.5 us); 1 miss in the first 5.3 s.
* After any reset the sound board stays in reset ~84 us longer than the 68000 (jt10 needs a long
  reset); MAME releases both at once.
* jt10's YM2610 busy flag duration and timer phases are the chip's; ymfm's are approximations.

## Verification

`scripts/sim.sh sound` (`sim/tb/tb_sound.sv`): MAME's latch writes replayed at MAME's times from
the watchdog reset on; every Z80 I/O write (YM2610, bank, latch 2) compared in order with MAME's.
`scripts/audiocheck.py` compares the bench's audio with `mame -wavwrite` (RMS ratio, 10 ms envelope
and log-spectrum correlation).

Results so far:

| Check | Result |
| --- | --- |
| `sim.sh sound +MS=60` (from the watchdog reset) | 109/109 Z80 I/O writes identical to MAME in order |
| `sim.sh sound +MS=5300` (through the boot handshake and the Z80 ROM self-test) | 1428/1428 writes identical in order, max time offset 0.43 ms (the bench's longer sound reset; before the block-RAM/prefetch change: 28 ms, and a 17.5 s run had 3071 reordered writes) |
| `sim.sh sound +ZPATCH +PRE01 +SHIFTFROM=13373328 +SHIFTAT=400000` (handshake 0x01, then MAME's latch writes from the attract-music command 0x05 on, moved to 0.4 s) + `audiocheck.py --mame-offset 15.9733 --start 0.45` | attract music 0.45-2.35 s: RMS ratio 0.97, 10 ms envelope correlation 0.972, log-spectrum correlation 0.995 |

Simulation notes: ModelSim needs FPGA power-up zeros for jt10 (`sim/tb/zero_regs.do`); without
them the never-reset accumulators stay X and the output is silent in simulation only.

## Magical Cat Adventure

Same Z80 / YM2610 / latches. Differences (MAME `mcatadv`): 128 KB Z80 ROM with 0000-3FFF fixed and
a 32 KB bank window at 4000-BFFF (bank register = memory write to F000); the YM2610 is memory
mapped at E000-E003 (reads and writes); I/O has only port 80. Mix: SSG x 1.0 (RTL coefficient
2741 instead of 1645), FM/ADPCM x 0.5 each. The attract mode is silent in MAME (one command, 0xEF);
the Z80 idles in a loop rewriting the bank register and latch 2 with unchanged values.

| Check | Result |
| --- | --- |
| `sim.sh sound +MCAT +SIMDIR=local/mcatadv/sim +STRACE=local/mcatadv/sound_play.txt +MS=11000` (MAME trace with coin/start/play inputs, `local/mcatadv/play_inputs.txt`) | 1500/1500 YM2610 / changed bank / changed latch 2 writes identical to MAME in order through the boot and the coin command (11 s after the watchdog reset), max time offset 0.26 ms |
| `... +PRE=ef,1f +SHIFTFROM=12000000 +SHIFTAT=500000 +MS=5500` (boot + coin commands, then MAME's commands from the game start on, moved to 0.5 s) + `audiocheck.py --mame-offset 14.5 --start 0.55` vs `mame -wavwrite` with the same inputs | gameplay music and effects 0.55-5.5 s: RMS ratio 1.00, 10 ms envelope correlation 0.908, log-spectrum correlation 0.957 |
