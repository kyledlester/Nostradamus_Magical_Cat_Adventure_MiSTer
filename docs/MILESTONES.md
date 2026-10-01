# Milestones

| ID | Milestone | Status | Evidence |
| --- | --- | --- | --- |
| M0 | Reference and project setup | done | MAME 0.289 pinned (docs/MAME_REFERENCE.md); `mame -verifyroms nost` good; boot / write-timing traces (`scripts/mame/io_trace.lua`) |
| M1 | ROM and MiSTer loading pipeline | in progress | `romtool.py verify` 14/14 CRC; regions == MAME dump 6/6 byte-exact; `romtool.py mracheck` PASS (stream 0xA40000 bytes, crc 33d7ff3f) |
| M2 | Main CPU boot and board map | pending | |
| M3 | Graphics and frame behaviour | pending | |
| M4 | Controls, DIPs, gameplay | pending | |
| M5 | Sound | pending | |
| M6 | Integrated simulation and release build | pending | |
