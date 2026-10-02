# Nostradamus / Magical Cat Adventure (LINDA board) for MiSTer

MiSTer FPGA core for Face's "LINDA" board games: **Nostradamus** (Face, 1993, vertical shoot 'em
up, LINDA25) and **Magical Cat Adventure** (Wintechno, 1993, horizontal platformer, LINDA5).
68000 @ 16 MHz, Z80 @ 4 MHz, YM2610-compatible YMF286-K @ 8 MHz, two 038 tilemap chips and the
FX1037 sprite custom (MAME driver `misc/mcatadv.cpp`, sets `nost` and `mcatadv`). One core file;
the MRA selects the game.

| Game | MAME set | MRA | Status |
| --- | --- | --- | --- |
| Nostradamus | `nost` | `mra/Nostradamus.mra` | verified in simulation against MAME 0.289; **not yet tested on hardware** |
| Nostradamus (Japan) | `nostj` | `mra/Nostradamus (Japan).mra` | as `nost` (simulation) |
| Nostradamus Yeeon (Korea) | `nostk` | `mra/Nostradamus Yeeon (Korea).mra` | as `nost` (simulation) |
| Magical Cat Adventure | `mcatadv` | `mra/Magical Cat Adventure.mra` | verified in simulation against MAME 0.289; **not yet tested on hardware** |
| Magical Cat Adventure (Japan) | `mcatadvj` | `mra/Magical Cat Adventure (Japan).mra` | as `mcatadv` (simulation) |
| Catt (Japan) | `catt` | `mra/Catt (Japan).mra` | as `mcatadv` (simulation) |

ROMs are not included. Supply your own MAME 0.289 sets (`mame -verifyroms` = good). The clone
MRAs read split sets: the clone zip plus its parent's (`nostj.zip` + `nost.zip`,
`mcatadvj.zip` / `catt.zip` + `mcatadv.zip`), as MAME's split sets are distributed.

## Installation

1. Copy `Releases/Nostradamus_YYYYMMDD.rbf` to `/media/fat/_Arcade/cores/`.
2. Copy the `.mra` files from `mra/` to `/media/fat/_Arcade/`.
3. Copy the zips (`nost.zip`, `mcatadv.zip` and any clone zips) to `/media/fat/games/mame/`.
4. Load a game from the Arcade menu.

Both games start with a black screen for 3 s: on a cold start the program writes a signature to
RAM and waits for a watchdog reset (see below). Nostradamus then runs about 13 s of self tests
before attract mode.

## Controls

| Nostradamus | Magical Cat Adventure | MiSTer (default pad) |
| --- | --- | --- |
| 8-way joystick | 8-way joystick | D-pad / stick |
| Shot | Fire | A |
| Button 2 (test mode only) | Jump | B |
| Button 3 (test mode only) | Button 3 (P1, test mode only) | X |
| Start | Start | Start |
| Coin | Coin | Select |
| Service (cycles the test-mode screens) | Service | R |
| Pause (core) | Pause (core) | L |

Player 2 uses the second controller.

## OSD

* **Orientation** Vert/Horz and **Rotate CCW/CW** (Nostradamus only, HDMI; the game is rotated
  counter-clockwise). Magical Cat Adventure is horizontal and is never rotated.
* **DIP switches** (from the MRA, as MAME defines them for each game).
* **Flip screen (180)**: the core rotates the whole picture (15 kHz and HDMI), independent of the game.
* **Tilemap engine**: *MAME-matched* (default, this project's 038 line renderer) or *Cave 038*
  (the 038 layer processor from MiSTer-devel/Arcade-Cave_MiSTer, adapted to this board). Both are
  pixel-exact against MAME on every captured frame of both games; latched at reset / vblank.
* **CRT Adjust**, **Scandoubler Fx**, **Pause** options, **Debug overlay**, **Video test pattern**.

## Video

Native raster 456 x 256 total, 320 x 224 active, 7.004 MHz dot clock, **15.36 kHz / 60.00 Hz** -
MAME's logical raster for both games (the PCB timing has not been measured; docs/VIDEO.md).

## Watchdog / boot

On a cold start each program writes a signature to RAM ('nost', 'MASICAL CAT ADVENTURE') and
spins until the watchdog resets the CPU. The watchdog period is unknown (MAME: 3 s, "a guess");
the core uses 3 s. A MiSTer reset keeps work RAM, so later resets boot immediately.

## Debug overlay (top-left of the picture)

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
  images from `python scripts/romtool.py [--game mcatadv] regions|stream|images` (written to
  `local/` or `local/mcatadv/`, never committed) and MAME captures from `scripts/mame/*.lua` (run
  them with `scripts/mame/run.sh`, which uses a fresh MAME configuration directory;
  `NOST_SET=mcatadv` selects Magical Cat Adventure).

Documentation: [architecture](docs/ARCHITECTURE.md), [memory map](docs/MEMORY_MAP.md),
[ROM layout](docs/ROM_LAYOUT.md), [video](docs/VIDEO.md), [audio](docs/AUDIO.md),
[MAME reference](docs/MAME_REFERENCE.md), [milestones](docs/MILESTONES.md),
[reuse and licences](docs/REUSE_AND_LICENSES.md), [known issues](docs/KNOWN_ISSUES.md).

## Licence

GPL-3.0-or-later (see `LICENSE`); MiSTer framework under `LICENSE.MiSTer`. Reused components and
their licences: [docs/REUSE_AND_LICENSES.md](docs/REUSE_AND_LICENSES.md).
