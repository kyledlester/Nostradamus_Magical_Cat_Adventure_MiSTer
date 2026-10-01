// Nostradamus MiSTer core -- main-board clock enables.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// clk_sys = 98.058240 MHz (nost_pll.sv).
//   ce_pix : clk_sys / 14 = 7.004160 MHz, exact and jitter-free (MiSTer CE_PIXEL contract).
//   tick32 : 32 MHz average (NUM/DEN = 3125/9576 of clk_sys), spacing 3 or 4 clk_sys.
//   phi1/phi2: FX68K phase enables, alternating on tick32 -> 68000 at 16 MHz (MAME XTAL 16 MHz).
// pause freezes the emulated time base (the raster keeps running).
module nost_clocks #(
    parameter int NUM = 3125,
    parameter int DEN = 9576
) (
    input  logic clk,
    input  logic rst,          // emulated time base reset
    input  logic rst_video,    // raster divider reset (PLL loss only)
    input  logic pause,
    output logic ce_pix,
    output logic tick32,
    output logic phi1,
    output logic phi2
);
    logic [3:0]  pdiv;
    logic [13:0] acc;
    logic        ph;

    always_ff @(posedge clk) begin
        ce_pix <= 1'b0;
        if (rst_video) pdiv <= '0;
        else begin
            pdiv <= (pdiv == 4'd13) ? 4'd0 : pdiv + 4'd1;
            if (pdiv == 4'd13) ce_pix <= 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        tick32 <= 1'b0;
        phi1   <= 1'b0;
        phi2   <= 1'b0;
        if (rst) begin
            acc <= '0;
            ph  <= 1'b0;
        end else if (!pause) begin
            if (acc + 14'(NUM) >= 14'(DEN)) begin
                acc    <= acc + 14'(NUM) - 14'(DEN);
                tick32 <= 1'b1;
                ph     <= !ph;
                phi1   <= !ph;
                phi2   <=  ph;
            end else begin
                acc <= acc + 14'(NUM);
            end
        end
    end
endmodule
