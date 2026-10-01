# Nostradamus (Face, 1993) for MiSTer

MiSTer FPGA core for **Nostradamus**, Face's 1993 vertical shoot 'em up on the "LINDA25" board:
68000 @ 16 MHz, Z80 @ 4 MHz, YM2610-compatible YMF286-K @ 8 MHz, two 038 tilemap chips and the
FX1037 sprite custom (MAME driver `misc/mcatadv.cpp`, set `nost`).

| Game | MAME set | MRA | Status |
| --- | --- | --- | --- |
| Nostradamus | `nost` | `mra/Nostradamus.mra` | verified in simulation against MAME 0.289; **not yet tested on hardware** |

ROMs are not included. Supply your own `nost.zip` (MAME 0.289 set; `mame -verifyroms nost` = good).

## Installation

1. Copy `Releases/Nostradamus_YYYYMMDD.rbf` to `/media/fat/_Arcade/cores/`.
2. Copy `mra/Nostradamus.mra` to `/media/fat/_Arcade/`.
3. Copy `nost.zip` to `/media/fat/games/mame/`.
4. Load *Nostradamus* from the Arcade menu.

The game spends about 16 s in its power-on self tests before attract mode (the first 3 s are a
black screen: on a cold start the program waits for a watchdog reset - see below).

## Controls

| Game | MiSTer (default pad) |
| --- | --- |
| 8-way joystick | D-pad / stick |
| Shot | A |
| Button 2, Button 3 | B, X - used only by the test mode (MAME: unknown in normal play) |
| Start | Start |
| Coin | Select |
| Service (cycles the test-mode screens) | R |
| Pause (core) | L |

Player 2 uses the second controller.

## OSD

* **Orientation** Vert/Horz and **Rotate CCW/CW** (HDMI; the game is rotated counter-clockwise).
* **DIP switches** (from the MRA, as MAME defines them): lives, difficulty, flip screen, demo
  sounds, bonus life, coin A/B, SW2:7 (unused), service mode.
* **CRT Adjust**, **Scandoubler Fx**, **Pause** options, **Debug overlay**, **Video test pattern**.

## Video

Native raster 456 x 256 total, 320 x 224 active, 7.004 MHz dot clock, **15.36 kHz / 60.00 Hz** -
MAME's logical raster (the PCB timing has not been measured; docs/VIDEO.md).

## Watchdog / boot

On a cold start the program writes a signature to RAM and spins until the watchdog resets the CPU.
The watchdog period is unknown (MAME: 3 s, "a guess"); the core uses 3 s. A MiSTer reset keeps
work RAM, so later resets boot immediately.

## Debug overlay (top-left of the rotated picture)

| Line | Left 16 bits | Right 16 bits |
| --- | --- | --- |
| 1 | - | 68000 program address |
| 2 | frames (vblanks) | IRQ1 acknowledges |
| 3 | sound-latch writes (68000) | sound-latch reads (Z80) |
| 4 | YM2610 writes | Z80 NMIs |
| 5 | 68000 ROM cache misses | Z80 ROM cache misses |
| 6 | render overruns | watchdog resets |
| 7 | longest line render (clocks of 6384) | `loaded` flag, latch 2 |

## Building

* Quartus Prime Lite 17.0: `powershell -ExecutionPolicy Bypass -File scripts\build.ps1` (writes
  `build/build-summary.txt`, `output_files/Nostradamus.rbf`, `Releases/Nostradamus_YYYYMMDD.rbf`).
* Simulation (ModelSim-Intel Starter 10.5b): `scripts/sim.sh <test>`; tests needing ROM data use
  images from `python scripts/romtool.py regions|stream|images` (written to `local/`, never
  committed) and MAME captures from `scripts/mame/*.lua` (run them with `scripts/mame/run.sh`,
  which uses a fresh MAME configuration directory).

Documentation: [architecture](docs/ARCHITECTURE.md), [memory map](docs/MEMORY_MAP.md),
[ROM layout](docs/ROM_LAYOUT.md), [video](docs/VIDEO.md), [audio](docs/AUDIO.md),
[MAME reference](docs/MAME_REFERENCE.md), [milestones](docs/MILESTONES.md),
[reuse and licences](docs/REUSE_AND_LICENSES.md), [known issues](docs/KNOWN_ISSUES.md).

## Licence

GPL-3.0-or-later (see `LICENSE`); MiSTer framework under `LICENSE.MiSTer`. Reused components and
their licences: [docs/REUSE_AND_LICENSES.md](docs/REUSE_AND_LICENSES.md).
