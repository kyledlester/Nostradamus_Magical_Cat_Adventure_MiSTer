# Reused components and licences

The Nostradamus core is distributed under GPL-3.0-or-later (`LICENSE`); the MiSTer framework under its own
terms (`LICENSE.MiSTer`, GPL-2.0-or-later). All reused components are GPL-compatible.

| Component | Path | Source | Revision | Author(s) | Licence | Modifications |
| --- | --- | --- | --- | --- | --- | --- |
| MiSTer framework | `sys/` | MiSTer-devel/Template_MiSTer via the owner's Neratte Chu and R-Shark cores | `3ea1134` | Sorgelig et al. | GPL-2.0+ (see headers) | none |
| FX68K 68000 | `rtl/vendor/fx68k/` | github.com/ijor/fx68k via the owner's NA-1/NA-2 core | `0602ee4627b10f301298f2673d826cdd6baa9327` | Jorge Cwik | GPL-3.0-or-later | none (`microrom.mem`/`nanorom.mem` at repo root because the CPU `$readmemb`s them by name) |
| T80 Z80 | `rtl/vendor/t80/` | MiSTer-devel/ZX-Spectrum_MISTer `rtl/T80` via Neratte Chu | `d41751d0afc8abf75f31ff1094bf9731e7a1695c` | Daniel Wallner, MikeJ, TobiFlex, Sorgelig, brNX | BSD-style (file headers) | none; `T80s.vhd` instantiated |
| jt10 YM2610 (jt12 family) | `rtl/vendor/jt10/` | github.com/jotego/jt12 `hdl/` + `hdl/adpcm/`, submodule jt49 `hdl/` | jt12 `dc9be7c1ff75d5b9a7f9d89da1b7fba212af1257`, jt49 `7f6abfd08a2af9a92dbd5b32c71ea773248a77e2` | Jose Tejada Gomez | GPL-3.0-or-later | `jt12_top.v`: the `op_result`/`op_result_hd` wire declarations moved above their first use (ModelSim otherwise makes the jt10_acc connection an implicit 1-bit net; Quartus resolved it, so synthesis was unaffected). Only files needed by `jt10.v`; simulation needs `sim/tb/zero_regs.do` for FPGA power-up state |
| SDRAM controller | `rtl/vendor/sdram.sv` | GBA_MiSTer lineage via the owner's NA-1 -> NB-1 -> Neratte Chu cores | SHA-1 `a5c1f349e1dc9f23ddb600b59d95427c9f6b0500` | Sorgelig (hamsterworks parts) + owner's byte enables / refresh parameter | GPL-3.0-or-later | none here |
| CRT Adjust | `rtl/vendor/crt_adjust.sv` | MiSTer-CRT-Adjust (rmonic79) | SHA-1 `ddc1b6d311f26d50cc30ce1a83df9fc539830fbc` | Umberto Parisi | GPL-3.0-or-later | none |
| Pause | `rtl/vendor/pause.v` | JimmyStones/Pause_MiSTer via Arcade-Pacman_MiSTer | SHA-1 `d5a5effd1bf91ae788436639bae3c63b8fe40347` | Jim Gregory | GPL-3.0-or-later | none |
| 68000 bus glue | `rtl/nost/nost_cpu68k.sv`, `nost_cpu_bus.sv` | owner's NA-1/NA-2 core via R-Shark | - | owner | GPL-3.0-or-later | module names |
| CRT Adjust glue, RAM primitives, SDRAM arbiter, overlay, loader/clock patterns | `rtl/nost/nost_crt_adjust.sv`, `nost_ram.sv`, `nost_sdram_arb.sv`, `nost_overlay.sv` | owner's R-Shark core | `207ae0e` | owner | GPL-3.0-or-later | renamed; arbiter generalized to 6 clients; overlay for 320x224 |
| Cave 038 layer processor | `rtl/vendor/cave/CaveLayerProcessor.sv` (+ `LICENSE`) | MiSTer-devel/Arcade-Cave_MiSTer `rtl/cave/` | `ee191eab9f92c8946258c606363f1980ce138925` | Josh Bassett (nullobject) | GPL-3.0-or-later | none; adapted to this board by `rtl/nost/nost_tilemap_cave.sv` (OSD option) |
| SDRAM chip model (sim) | `sim/models/sdr_sdram_model.sv` | owner's Neratte Chu core | - | owner | GPL-3.0-or-later | `preload` task added |

Everything under `rtl/nost/` not listed above, the testbenches, the MAME Lua scripts and the
Python tools were written for this project. Of the Cave core's chips only the 038 is shared with this
board (68000 = FX68K and Z80 = T80 already; the Cave sound chips and sprite hardware differ). The default 038 tilemap engine, the FX1037-style sprite engine and the board logic follow MAME's
behaviour; no existing FPGA implementation of this board was used.

MAME (BSD-3-Clause / GPL-2.0+) is used only as a reference: no MAME code is included.
