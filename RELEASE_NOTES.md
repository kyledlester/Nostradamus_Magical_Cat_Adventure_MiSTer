# Nostradamus / Magical Cat Adventure for MiSTer — beta 1 (2026-10-03)

First public beta of a MiSTer core for Face's "LINDA" arcade board. One core file runs six MAME
sets; pick the game with its MRA.

| Game | MAME set | ROM zips needed |
| --- | --- | --- |
| Nostradamus (Face, 1993) | `nost` | `nost.zip` |
| Nostradamus (Japan) | `nostj` | `nostj.zip` + `nost.zip` |
| Nostradamus Yeeon (Korea) | `nostk` | `nostk.zip` + `nost.zip` |
| Magical Cat Adventure (Wintechno, 1993) | `mcatadv` | `mcatadv.zip` |
| Magical Cat Adventure (Japan) | `mcatadvj` | `mcatadvj.zip` + `mcatadv.zip` |
| Catt (Japan) | `catt` | `catt.zip` + `mcatadv.zip` |

ROMs are not included. Use MAME 0.289 sets; clone sets are split, so keep the parent zip next to
the clone zip.

## Download

* Core: `Nostradamus_20261003.rbf` (SHA-1 `796c134bb176edd54870086d2e6a1145e05287b5`)
* MRAs: `MRA/Nostradamus.mra`, `MRA/Magical Cat Adventure.mra` and the clones in
  `MRA/_alternatives/_Nostradamus/` and `MRA/_alternatives/_Magical Cat Adventure/`

## Installation

1. Copy `Nostradamus_20261003.rbf` to `/media/fat/_Arcade/cores/` and remove any older
   `Nostradamus_*.rbf`.
2. Copy the contents of `MRA/` (including `_alternatives/`) to `/media/fat/_Arcade/`. If you tried an earlier test build, replace
   `Nostradamus.mra` too: each MRA now tells the core which game it is.
3. Copy the ROM zips to `/media/fat/games/mame/`.
4. Load a game from the Arcade menu.

Requires a DE10-Nano with an SDRAM module (32 MB or larger).

## What's in this beta

* **Complete board:** 68000 (FX68K), Z80 (T80), YM2610 FM / SSG / ADPCM-A (jotego's jt10), both 038
  tilemap chips with row scroll and row select, the FX1037 sprite hardware, watchdog and DIP
  switches.
* **Two tilemap engines** (OSD *Tilemap engine*): *Cave 038* (default) uses the 038 layer processor
  from the Arcade-Cave core, adapted to this board; *MAME-matched* is this project's own renderer.
  Both give pixel-identical pictures.
* **One Orientation item for every screen setup** (Horizontal / Vertical CCW / Vertical CW /
  Flipped, as in the Namco NA-1/NA-2 core): both games can be played on landscape screens, TATE
  monitors (HDMI scaler rotation) and rotated or inverted CRTs (*Flipped* turns the picture 180°
  on 15 kHz and HDMI). Each game defaults to its natural orientation.
* **CRT Adjust** (H-size, H-position, V-shift) for 15 kHz CRTs, with the OSD staying visible.
* **Pause** (L button, or automatically when the OSD is open) and a debug overlay.

## How it was checked

Every set was compared with MAME 0.289 in simulation:

* ROM data loaded into the core is byte-identical to MAME's, for every set.
* 68000 bus traffic after start-up is identical to MAME's for every set.
* Video frames are pixel-identical to MAME's on every captured frame, with both tilemap engines.
  This covers attract mode, gameplay with inputs and DIP-flipped screens. Whole-board runs were
  also identical frame for frame: 59 for Nostradamus, and 60 attract plus 90 gameplay for
  Magical Cat.
* Sound chip writes are identical to MAME's in order (5.3 s of Nostradamus, 11 s of Magical Cat),
  and recorded music closely matches MAME's audio.

The core has also been played on a DE10-Nano.

## Things to know

* **About 3 seconds of black screen at power-on is normal.** Both games write a signature to RAM on
  a cold start and wait for the board's watchdog to reset them, as on the arcade board and in
  MAME. Nostradamus then runs its self tests before the title. A MiSTer reset keeps work RAM, so
  later resets start at once.
* **Magical Cat Adventure / Catt attract mode is silent**, as in MAME. Sound starts with a game.
* **Use the OSD *Orientation: Flipped*, not the games' own *Flip Screen* DIP.** The DIP behaves as in
  MAME, which flips only the backgrounds; MAME marks both games "no cocktail".
* **Magical Cat coin DIPs:** their meaning depends on the *Coin Mode* switch, so each choice is
  labelled with both readings ("Mode 1 / Mode 2").
* **Board details MAME also guesses at:** the watchdog period (3 s), the exact video timing
  (15.36 kHz / 60.00 Hz) and sprite/tile priority edge cases follow MAME.
* **Sound chip:** jotego's jt10 replaces MAME's ymfm, so fine audio details can differ slightly.

Full list: [docs/KNOWN_ISSUES.md](docs/KNOWN_ISSUES.md).

## Reporting problems

Please open an issue with:

* the game and set;
* where it happened (boot, attract, a particular stage);
* whether an OSD reset or reloading the MRA changes it;
* for graphics or hang problems, a photo with the OSD *Debug overlay* turned on.

## Credits

This core was created with the assistance of AI tooling. It builds on:

* MAME's `mcatadv` driver (Paul Priest, David Haywood) as the behavioural reference;
* FX68K (Jorge Cwik), T80 (Daniel Wallner and contributors), jt10 (Jose Tejada / jotego);
* the Cave 038 layer processor (Josh Bassett / nullobject, Arcade-Cave_MiSTer);
* the MiSTer framework (Sorgelig and contributors), CRT Adjust (Umberto Parisi / rmonic79) and
  Pause (Jim Gregory / JimmyStones).

GPL-3.0-or-later. Licences and revisions: [docs/REUSE_AND_LICENSES.md](docs/REUSE_AND_LICENSES.md).
