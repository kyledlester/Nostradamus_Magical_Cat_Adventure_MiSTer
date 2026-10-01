# Milestones

Reproduce any check with the command in the Evidence column (ROM-derived inputs: `python
scripts/romtool.py regions stream images`; MAME captures: `scripts/mame/run.sh scripts/mame/<x>.lua`).

| ID | Milestone | Status | Evidence | Discrepancies |
| --- | --- | --- | --- | --- |
| M0 | Reference and project setup | done | MAME 0.289 pinned (docs/MAME_REFERENCE.md); `mame -verifyroms nost` good; boot and write-timing traces (`io_trace.lua`) | MAME's watchdog (3 s) and raster are approximations; captures must use a fresh cfg dir (a persisted Flip Screen DIP once leaked into captures) |
| M1 | ROM and MiSTer loading pipeline | done | `romtool.py verify` 14/14 CRC; `romtool.py regions` == `dump_regions.lua` 6/6 byte-exact (incl. 0xFF-erased sprite space); `romtool.py mracheck` PASS (0xA40000 bytes, crc 33d7ff3f); `sim.sh loader`: 5,373,952 stream words through loader + arbiter + sdram.sv + chip model == romtool SDRAM image | none |
| M2 | Main CPU boot and board map | done (sim) | `sim.sh boot +N=200000`: 200,000 bus transactions identical to MAME from the watchdog reset (zero-wait ROM); `sim.sh bootc`: same with the production ROM cache; `sim.sh boot +WDTEST -gWD_TICKS=64000`: cold boot writes the signature, spins at 0x11E, watchdog resets it, then 30,000 transactions identical; P1 bit 11 reads 0 (`sim.sh inputs`) | ROM cache misses add wait states (KNOWN_ISSUES 4); long full-boot comparison: see below |
| M3 | Graphics and frame behaviour | done (sim) | `refrender.py check`: 101 attract + 25 flipped + 33 gameplay + 60 patched-boot MAME frames pixel-exact; `render_batch.sh`: 8 attract, 3 flipped, 6 gameplay frames pixel-exact through the RTL video path (busiest line 2556 of 6384 clocks); `sim.sh systemns +SNAP=local/snap1490`: whole board from a MAME snapshot, 59/59 consecutive displayed frames == MAME's render, no render overrun | MAME converts frames with the next frame's palette (KNOWN_ISSUES 3); flip as MAME |
| M4 | Controls, DIPs, gameplay | done (sim) | `sim.sh inputs`: 37 checks (every joystick/button/coin/start/service bit to MAME's port bit, DIP download -> DSW1/DSW2); `systemns +SNAP=local/snap1990 +INPUTS`: stage-1 gameplay with fire held and left/up/right moves, frames == MAME; `systemns +SNAP=local/snap1270 +DSW=7FFF`: Service Mode DIP on, Service button at the same frame as MAME, 69/69 frames == MAME (test screens cycle); MAME: coin, start, play, continue | input timing: FPGA vblank n = MAME frame_done(F-1+n) after a snapshot at frame F |
| M5 | Sound | in progress | `sim.sh sound +MS=60`: Z80 I/O writes identical to MAME | |
| M6 | Integrated simulation and release build | in progress | Quartus build fits (63 % ALMs, 377/553 M10K) | first build -0.93 ns (sprite scanner), fixed |
