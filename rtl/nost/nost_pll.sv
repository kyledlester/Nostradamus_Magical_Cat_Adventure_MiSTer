// Nostradamus MiSTer core -- system PLL.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// One fractional-N PLL: 50 MHz board clock -> clk_sys = 98.058240 MHz, clk_snd = clk_sys / 2.
//
// 98.058240 MHz = 14 x 7.004160 MHz, and 7.004160 MHz = 456 x 256 x 60 Hz: a dot clock that
// reproduces MAME's logical raster rate (screen.set_size(320,256), set_refresh_hz(60): 15.360 kHz
// lines, 60.000 Hz frames) with an integer /14 pixel enable and a 456-dot line (320 visible).
// The PCB dot clock / line length is NOT known (28 MHz and 16 MHz oscillators on the board; docs/
// VIDEO.md). The 68000 (16 MHz) runs from an average-exact fractional 32 MHz phase tick; the sound
// board (Z80 4 MHz, YM2610 8 MHz) from average-exact enables in the clk_snd domain.
//
// HIERARCHY IS LOAD-BEARING: sys/sys_top.sdc places the core clock in its own clock group only if
// it matches *|pll|pll_inst|altera_pll_i|*[*].*|divclk, so emu instantiates this module as "pll"
// (pattern from the owner's R-Shark / NB-1 cores).
module nost_pll (
    input  wire refclk,   // CLK_50M
    input  wire rst,
    output wire clk_sys,  // 98.058240 MHz
    output wire clk_snd,  // 49.029120 MHz = clk_sys / 2, phase aligned (sound board domain)
    output wire locked
);
    nost_pll_core pll_inst (
        .refclk(refclk),
        .rst(rst),
        .clk_sys(clk_sys),
        .clk_snd(clk_snd),
        .locked(locked)
    );
endmodule

module nost_pll_core (
    input  wire refclk,
    input  wire rst,
    output wire clk_sys,
    output wire clk_snd,
    output wire locked
);
    wire [1:0] clocks;

    altera_pll #(
        .fractional_vco_multiplier("true"),
        .reference_clock_frequency("50.0 MHz"),
        .operation_mode("direct"),
        .number_of_clocks(2),
        .output_clock_frequency0("98.058240 MHz"),
        .phase_shift0("0 ps"),
        .duty_cycle0(50),
        .output_clock_frequency1("49.029120 MHz"),
        .phase_shift1("0 ps"),
        .duty_cycle1(50),
        .pll_type("General"),
        .pll_subtype("General")
    ) altera_pll_i (
        .refclk(refclk),
        .rst(rst),
        .outclk(clocks),
        .locked(locked),
        .fboutclk(),
        .fbclk(1'b0)
    );

    assign clk_sys = clocks[0];
    assign clk_snd = clocks[1];
endmodule
