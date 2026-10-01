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
4. **CPU wait states.** The 68000 program ROM and the Z80 ROM are in SDRAM behind caches; a miss adds
   1-2 wait states (68000) or ~0.5 us WAIT_n (Z80). MAME has no wait states, so CPU timing drifts
   slightly from MAME; game logic is vblank-locked and frames still match.
5. **Flip screen.** Implemented exactly as MAME: tilemaps flip, sprites and row scroll/select do not
   (MAME's driver TODO, MACHINE_NO_COCKTAIL). The real flipped picture is unknown.
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
