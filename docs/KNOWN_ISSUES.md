# Known issues and deviations

Deviations from MAME that are deliberate or understood, and PCB facts that are unknown.

1. **Watchdog period.** The core resets the 68000 and the sound board after 3.0 s without a write to
   0xB00018, as MAME (whose value is "a guess, and certainly wrong"). The cold-boot delay (black
   screen) equals this period. PCB value unknown.
2. **Raster timing.** 456 x 256 at 7.004 MHz reproduces MAME's 60.00 Hz / 15.36 kHz; the PCB dot
   clock, line length and sync positions are unmeasured (docs/VIDEO.md).
3. **Palette timing.** The FPGA reads the palette live during scan-out (as a board would). MAME
   converts each frame with the palette of the following frame, so on frames where the game changes
   the palette MAME's output differs by those pixels; with the render-time palette the FPGA output
   equals MAME's render (scripts/syscheck.py reports this case separately).
4. **CPU wait states.** The 68000 program ROM is in SDRAM behind a cache; a miss adds 1-2 wait
   states (MAME has none); game logic is vblank-locked and frames still match. The Z80's code area
   (0000-7FFF) is in block RAM (no waits); its bank window (8000-BFFF) is cached with next-line
   prefetch, so it practically never waits (1 miss in 5.3 s; before this change the Z80 fell 28 ms
   behind MAME during its ROM self-test, which reordered later YM2610 writes).
5. **Flip screen.** The game's Flip Screen DIP behaves exactly as in MAME: tilemaps flip, sprites and
   row scroll/select do not, and gameplay is black (MAME's driver TODO, MACHINE_NO_COCKTAIL). The
   real flipped picture is unknown. Use the OSD option *Flip screen (180)* instead: the core renders
   the picture rotated 180 degrees (15 kHz and HDMI), independent of the game.
6. **Sprite/tile priority** uses MAME's OR'ed priority bitmap (docs/VIDEO.md); unverified on a PCB.
7. **Tile palette index** is kept to 12 bits ((colour + bank*0x40) % 0x200 * 16 can exceed the 4096
   palette entries for banks >= 4; the game uses banks 1 and 3; MAME would index past its palette).
8. **Sound reset.** After a reset the sound board starts ~84 us after the 68000 (jt10 needs a long
   reset); MAME starts both together.
9. **YM2610 model.** jt10 (jotego) instead of MAME's ymfm: register-level behaviour is the chip's,
   but timer/busy timing and analog-ish mixing details differ slightly from ymfm.
10. **Unknown inputs.** P1 bits 5/6 and P2 bits 5/6 (buttons 2/3) are wired to MiSTer buttons 2/3
    because the test mode uses them; MAME leaves them unconnected. P1 bit 9 ("test 3 in test mode")
    is not wired (reads 1, as MAME). P1 bit 11 reads 0 (required).
11. **Magical Cat Adventure specifics.** The coin DIPs' meaning depends on *Coin Mode* (MAME
    PORT_CONDITION); the MRA lists both readings per setting ("Mode 1/Mode 2"). The coin counter /
    lockout write at 0x900000 is ignored (MAME leaves it unmapped too). Its game-select byte comes
    from the MRA (ioctl index 1); without it (an old MRA) the core runs as Nostradamus.
12. **Clones.** `nostj`, `nostk`, `mcatadvj` and `catt` use the same hardware in MAME but have no
    MRA yet (`catt` also has a 1 MB `bg0` and ADPCM-A ROM, which fit the slots).
