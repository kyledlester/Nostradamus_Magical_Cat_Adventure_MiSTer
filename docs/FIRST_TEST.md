# First hardware test

## Package

| Item | Path / value |
| --- | --- |
| RBF | `Releases/Nostradamus_YYYYMMDD.rbf` (see the release commit) -> `/media/fat/_Arcade/cores/` |
| MRA | `MRA/` (parents + `_alternatives/` clones: Nostradamus Japan/Korea; Magical Cat Adventure Japan, Catt) -> `/media/fat/_Arcade/` |
| ROM sets | MAME 0.289 `nost.zip`, `mcatadv.zip` and the clone zips `nostj`, `nostk`, `mcatadvj`, `catt` (split sets; the parent zip must be present too) -> `/media/fat/games/mame/` |
| Platform | DE10-Nano with a 32 MB SDRAM module (required: all graphics, sound and program ROMs are in SDRAM) |

## Procedure (one pass, ~10 minutes)

1. Load *Nostradamus*. Expect ~3 s of black (cold-boot watchdog wait), then ~13 s of black/self-test,
   then the attract mode with music. Note if the picture appears earlier or never.
2. Watch one attract cycle (~60 s): title, demo play with scrolling backgrounds, sprites, the
   "INSERT COIN" text. Listen for music and effects.
3. Press **Coin** (Select): the credit counter should go up with a sound. Press **Start**: player
   select screen, then press Start again (or wait) to begin.
4. Play stage 1 for a few minutes: move in all 8 directions, hold **Shot** (A). Lose a life and
   continue once if possible.
5. Optional: second controller - coin and start player 2.
6. Optional: OSD **DIP switches**: set *Service Mode* On, reset. Test screens appear; **Service** (R)
   cycles them (crosshatch, switch test, DIP display, sound test). Set it back to Off.
7. Optional: OSD *Orientation* (Vertical CCW = upright on HDMI, the default; Horizontal / Flipped for a rotated CRT or TATE monitor).

### Magical Cat Adventure

1. Load *Magical Cat Adventure*. Expect ~3 s of black (cold-boot watchdog wait), then the title.
   The picture is horizontal (OSD *Orientation: Horizontal*, the default; Vertical CCW/CW for a TATE monitor).
2. The attract mode (title, demo play, high scores) is **silent in MAME too** - not a fault.
3. Press **Coin** (Select), then **Start**: music should start with the game. Play stage 1: walk,
   **Jump** (B), **Fire** (A); check the scrolling backgrounds and sprites.
4. Optional: second controller; *Service Mode* DIP On and reset for the test screens (Button 3 = X
   selects the object ROM check there).
5. Optional: switch back to *Nostradamus* afterwards and check it still loads vertically (the game
   select comes from each MRA).

## If something is wrong, please note

* Where it first appears (boot, attract, coin/start, gameplay, a particular stage) and whether an
  OSD reset (keeps RAM) or reloading the MRA changes it.
* For video glitches: which layer (background, middle layer, sprites, text), whether it flickers,
  and a photo if possible. Turn on OSD *Debug overlay* and note line 6 (render overruns) and line 5
  (ROM cache misses).
* For sound: missing music vs missing effects vs distortion; whether it starts and later stops.
* For a hang: the debug overlay's first line (68000 address) and whether it changes.
