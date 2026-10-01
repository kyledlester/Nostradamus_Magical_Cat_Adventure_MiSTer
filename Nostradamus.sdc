# Nostradamus MiSTer core -- core timing constraints (sys/sys_top.sdc covers the framework).
# Core clocks: clk_sys = 98.058240 MHz and clk_snd = clk_sys / 2 (phase aligned) from
# rtl/nost/nost_pll.sv. Every emulated rate is a clock enable of one of them.
# (Constraint set from the owner's R-Shark core.)
derive_pll_clocks

# ---------------------------------------------------------------------------
# SDRAM pins (rtl/vendor/sdram.sv, clocked by clk_sys). Values as in the owner's hardware-proven
# NA-1 (100 MHz) and NB-1 cores. The controller launches address/command/write data on clk_sys's
# rising edge; altddio_out drives SDRAM_CLK as an inverted copy of clk_sys.
set ns_core_clock_pin [get_pins -compatibility_mode {*|pll|pll_inst|altera_pll_i|*|divclk}]
create_generated_clock -name SDRAM_CLK -source $ns_core_clock_pin \
    -divide_by 1 -invert [get_ports {SDRAM_CLK}]

set_input_delay -max -clock SDRAM_CLK 6.4 [get_ports {SDRAM_DQ[*]}]
set_input_delay -min -clock SDRAM_CLK 3.7 [get_ports {SDRAM_DQ[*]}]

# Read capture on the second clk_sys edge after the launching SDRAM_CLK edge (CL=2 data_ready_delay).
set_multicycle_path -setup 2 -from [get_clocks {SDRAM_CLK}] \
    -to [get_clocks {*|pll|pll_inst|altera_pll_i|*|divclk}]

set ns_sdram_outputs [get_ports {
    SDRAM_A[*] SDRAM_BA[*]
    SDRAM_nCS SDRAM_nWE SDRAM_nRAS SDRAM_nCAS
    SDRAM_DQMH SDRAM_DQML SDRAM_DQ[*]
}]
set_output_delay -max -clock SDRAM_CLK 1.6 $ns_sdram_outputs
set_output_delay -min -clock SDRAM_CLK -0.9 $ns_sdram_outputs

# ---------------------------------------------------------------------------
# Framework HQ2x Blend (sys/hq2x.sv inside arcade_video). Same constraint and reasoning as the owner's
# hardware-proven NA-1 core at 100 MHz: Blend only advances on the scandoubler's 4x pixel enable
# (here 4 x 7.004 MHz = every 3.5 clk_sys cycles, never on consecutive cycles), so its internal
# register-to-register paths have at least two clocks.
set_multicycle_path -setup 2 -from [get_registers {*|Hq2x:Hq2x|Blend:blender|*}]     -to [get_registers {*|Hq2x:Hq2x|Blend:blender|*}]
set_multicycle_path -hold 1 -from [get_registers {*|Hq2x:Hq2x|Blend:blender|*}]     -to [get_registers {*|Hq2x:Hq2x|Blend:blender|*}]

derive_clock_uncertainty
