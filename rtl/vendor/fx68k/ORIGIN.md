# Imported FX68K

Source: https://github.com/ijor/fx68k
Revision: `0602ee4627b10f301298f2673d826cdd6baa9327`
Imported files are unchanged. Copyright Jorge Cwik; GPL-3.0-or-later
as stated in `fx68k.txt`. Full GPLv3 text retained in `LICENSE`.

`microrom.mem` and `nanorom.mem` from this same revision live at the project
root because the unchanged CPU reads those filenames with `$readmemb`.
These are the CPU's microcode, not game ROM images. Simulate from the
project root so `$readmemb` finds them.

ModelSim 10.5b check 7061 is suppressed only for the imported CPU compilation:
upstream combines initial and `always_ff` writes to register arrays.
No CPU internals were changed to accommodate the simulator. Upstream
`unique` case/if diagnostics 8315 and 8360 remain visible in simulation logs.
