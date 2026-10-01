#!/usr/bin/env python3
"""Make a ModelSim-10.5b-compatible copy of rtl/vendor/sdram.sv (from the owner's R-Shark core; same edits as the owner's NB-1
scripts/test-m2.ps1): ModelSim rejects `command`/`chip` used before declaration, an initialised
variable inside always, and `inout reg`. The committed file stays byte-identical to the vendored one."""
import re, sys
src = open('rtl/vendor/sdram.sv', newline='').read().replace('\r\n', '\n')
decl = "reg  [2:0] command;\nreg        chip;\n"
n0 = src.count(decl)
src = src.replace(decl, "")
src = src.replace("assign SDRAM_nCS  = chip;", decl + "reg [15:0] SDRAM_DQ_r;\nassign SDRAM_DQ = SDRAM_DQ_r;\nassign SDRAM_nCS  = chip;")
src = src.replace("reg  [3:0] state = STATE_STARTUP;", "static reg  [3:0] state = STATE_STARTUP;")
src = src.replace("inout  reg [15:0] SDRAM_DQ,", "inout  wire [15:0] SDRAM_DQ,")
src = re.sub(r'SDRAM_DQ(\s*)<= ', r'SDRAM_DQ_r\1<= ', src)
if n0 != 1 or 'static reg  [3:0] state' not in src or re.search(r'SDRAM_DQ\s*<= ', src):
    sys.exit('sdram.sv simulation edit did not apply')
open(sys.argv[1], 'w').write(src)
