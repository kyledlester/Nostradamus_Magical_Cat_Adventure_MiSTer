# Nostradamus / Magical Cat Adventure (LINDA board) for MiSTer — beta

<img width="444" height="636" alt="image" src="https://github.com/user-attachments/assets/ca5c8264-648d-4bbe-945e-440e96b89305" />

MiSTer FPGA core for the two games on Face's "LINDA" arcade board:

* **Nostradamus** (Face, 1993) — vertical shoot 'em up (LINDA25)
* **Magical Cat Adventure** (Wintechno, 1993) — horizontal platformer (LINDA5), and its Japanese
  release **Catt**

Hardware: 68000 @ 16 MHz, Z80 @ 4 MHz, YMF286-K (YM2610 compatible) @ 8 MHz, two 038 tilemap chips
and the FX1037 sprite custom (MAME driver `misc/mcatadv.cpp`). One core file runs every set; the
MRA selects the game.

I created this core because I wanted to play these games on my MiSTer FPGA. I am posting it here and open sourcing it for everyone to enjoy and give feedback/make improvements. This core was created with the assistance of AI tooling.

**Status: beta.** The core has been thoroughly tested on a
DE10-Nano to the extent of my knowledge of these games. Every set was checked in simulation against MAME 0.289 (ROM loading, CPU bus
traffic, video frame by frame, sound chip writes and audio).

## Supported sets

| Game | MAME set | MRA | ROM zips needed |
| --- | --- | --- | --- |
| Nostradamus | `nost` | `Nostradamus.mra` | `nost.zip` |
| Nostradamus (Japan) | `nostj` | `Nostradamus (Japan).mra` | `nostj.zip` + `nost.zip` |
| Nostradamus Yeeon (Korea) | `nostk` | `Nostradamus Yeeon (Korea).mra` | `nostk.zip` + `nost.zip` |
| Magical Cat Adventure | `mcatadv` | `Magical Cat Adventure.mra` | `mcatadv.zip` |
| Magical Cat Adventure (Japan) | `mcatadvj` | `Magical Cat Adventure (Japan).mra` | `mcatadvj.zip` + `mcatadv.zip` |
| Catt (Japan) | `catt` | `Catt (Japan).mra` | `catt.zip` + `mcatadv.zip` |

ROMs are not included. Use MAME 0.289 sets (`mame -verifyroms <set>` = good; `catt` reports "best
available" because MAME lacks two PLD dumps the game does not need). Clone MRAs read split sets:
the clone zip plus its parent zip.

## Installation

1. Copy `Releases/Nostradamus_YYYYMMDD.rbf` to `/media/fat/_Arcade/cores/` (remove older
   `Nostradamus_*.rbf` files).
2. Copy the contents of `MRA/` to `/media/fat/_Arcade/`: the parent MRAs at the top level, the
   clones in `_alternatives/_Nostradamus/` and `_alternatives/_Magical Cat Adventure/`.
3. Copy the ROM zips to `/media/fat/games/mame/`.
4. Load a game from the Arcade menu.

Requires a DE10-Nano with an SDRAM module (32 MB or larger): all program, graphics and sound ROMs
live in SDRAM.

**Expect a black screen for about 3 seconds at power-on.** Both programs write a signature to RAM
on a cold start and wait for the board's watchdog to reset them (as on the arcade board and in
MAME). Nostradamus then runs a brief number of self tests before the title appears. A MiSTer reset
keeps work RAM, so later resets start at once.

The Magical Cat Adventure / Catt attract mode is **silent**; sound and
music start when a game is started.

## Controls

| Nostradamus | Magical Cat Adventure / Catt | MiSTer (default pad) |
| --- | --- | --- |
| 8-way joystick | 8-way joystick | D-pad / stick |
| Shot | Fire | A |
| Button 2 (test mode only) | Jump | B |
| Button 3 (test mode only) | Button 3 (P1, test mode only) | X |
| Start | Start | Start |
| Coin | Coin | Select |
| Service (cycles the test-mode screens) | Service | R |
| Pause (core) | Pause (core) | L |

## OSD options

* **Aspect ratio**, **Scandoubler Fx**.
* **Orientation** — one item for every screen setup (same scheme as the Namco NA-1/NA-2 core). The
  labels describe what happens to the board's raster:

  | Setting | Picture | Nostradamus | Magical Cat Adventure / Catt |
  | --- | --- | --- | --- |
  | Horizontal | raster as is | TATE / rotated monitor or CRT | landscape screen (default) |
  | Vertical CCW | HDMI scaler rotates 90° counter-clockwise | landscape screen, upright (default) | TATE monitor |
  | Vertical CW | HDMI scaler rotates 90° clockwise | (upside down on landscape) | TATE monitor turned the other way |
  | Flipped | 180° inside the core, 15 kHz and HDMI | TATE / rotated CRT turned the other way | inverted monitor |

  Each game lists its natural setting first (the default). The 90° rotations are HDMI/scaler
  modes; native 15 kHz output is never rotated 90° (rotate the monitor instead). Use *Flipped*
  rather than the games' own *Flip Screen* DIP: that DIP behaves as in MAME, which only flips the
  backgrounds (the drivers are marked "no cocktail").
* **Tilemap engine** — *Cave 038* (default) uses the 038 layer processor from the
  [Arcade-Cave](https://github.com/MiSTer-devel/Arcade-Cave_MiSTer) core, adapted to this board;
  *MAME-matched* is this project's own 038 renderer. Both produce pixel-identical pictures to MAME
  on every frame tested; the option exists for comparison and as a fallback.
* **DIP switches** — from the MRA, as MAME defines them for each game. Magical Cat's coin settings
  depend on its *Coin Mode* switch, so each choice shows both readings ("Mode 1 / Mode 2").
* **CRT Adjust** — H-size, H-position and V-shift for 15 kHz CRTs (the OSD stays visible).
* **Pause** options — pause when the OSD is open, dim after 10 s.
* **Debug** — overlay with internal counters (see below) and a video test pattern.

## Video and sound

* 320 x 224 visible, 456 x 256 total, 7.004 MHz dot clock: **15.36 kHz / 60.00 Hz**, MAME's raster
  for both games (the PCB's exact timing has not been measured).
* Sound: Z80 + YM2610 (jt10), mono, mixed with MAME's per-game levels.

## Known differences

See [docs/KNOWN_ISSUES.md](docs/KNOWN_ISSUES.md). In short: the watchdog period (3 s), raster
timing and sprite/tile priority follow MAME where the PCB is unmeasured; the YM2610 is jotego's
jt10 rather than MAME's ymfm, so fine audio detail can differ slightly; the games' own flip-screen
DIP gives MAME's (incomplete) result.

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

When reporting a problem, a photo of this overlay at the moment it happens helps.

## Building and verification

* Quartus Prime Lite 17.0: `powershell -ExecutionPolicy Bypass -File scripts\build.ps1` (writes
  `output_files/Nostradamus.rbf` and `Releases/Nostradamus_YYYYMMDD.rbf`).
* MRAs: `python scripts/romtool.py mra --game <set>`; `romtool.py mracheck --game <set>` rebuilds
  the ROM stream from the MRA and the zips and compares it with the documented layout.
* Simulation (ModelSim-Intel Starter 10.5b): `scripts/sim.sh <test>`. ROM-derived images come from
  `python scripts/romtool.py --game <set> regions|stream|images` and MAME captures from
  `scripts/mame/*.lua` (via `scripts/mame/run.sh`, `NOST_SET=<set>`); both are written to `local/`
  and never committed. Evidence per milestone: [docs/MILESTONES.md](docs/MILESTONES.md).

Documentation: [architecture](docs/ARCHITECTURE.md), [memory map](docs/MEMORY_MAP.md),
[ROM layout](docs/ROM_LAYOUT.md), [video](docs/VIDEO.md), [audio](docs/AUDIO.md),
[MAME reference](docs/MAME_REFERENCE.md), [first test](docs/FIRST_TEST.md),
[reuse and licences](docs/REUSE_AND_LICENSES.md), [known issues](docs/KNOWN_ISSUES.md).

## Credits

* MAME driver `mcatadv.cpp` (Paul Priest, David Haywood) and `tmap038` — the behavioural
  reference for this core (no MAME code is included).
* FX68K 68000 core — Jorge Cwik. T80 Z80 core — Daniel Wallner and contributors.
* jt10 / jt12 YM2610 — Jose Tejada (jotego).
* Cave 038 layer processor — Josh Bassett (nullobject), from Arcade-Cave_MiSTer.
* MiSTer framework — Sorgelig and contributors; CRT Adjust — Umberto Parisi (rmonic79); Pause —
  Jim Gregory (JimmyStones).

Full list with revisions and licences: [docs/REUSE_AND_LICENSES.md](docs/REUSE_AND_LICENSES.md).

## Licence

GPL-3.0-or-later (see `LICENSE`); MiSTer framework under `LICENSE.MiSTer`.
