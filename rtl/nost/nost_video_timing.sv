// Nostradamus MiSTer core -- raster timing.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// MAME logical raster (mcatadv.cpp): set_size(320, 256), visarea 0..319 x 0..223, 60 Hz,
// set_vblank_time(0): vblank = lines 224..255. MAME's raster has no horizontal blanking; this core
// uses a 456-dot line at 7.004160 MHz (dots 0..319 visible) so that lines run at MAME's 15.360 kHz
// and frames at 60.000 Hz. hcount/vcount: vcount is MAME's vpos; hcount 0..319 is MAME's hpos.
//
// Sync placement is a MiSTer/CRT choice, not PCB-verified (docs/VIDEO.md):
//   H: active 0..319, front porch 320..343, HSync 344..376 (33 dots = 4.7 us), back porch 377..455.
//   V: active 0..223, front porch 224..231, VSync 232..234, back porch 235..255.
// Reset phase: MAME starts its screen at vblank begin (screen.cpp m_vblank_start_time = 0), i.e.
// the beam is at line 224, dot 0 at time 0 (measured: the 3.0 s watchdog reset lands on line 224
// dot 0). The raster leaves reset at the same position so CPU time and the vblank interrupt keep
// MAME's phase.
module nost_video_timing (
    input  logic       clk,
    input  logic       rst,
    input  logic       ce_pix,
    output logic [8:0] hcount,     // 0..455
    output logic [7:0] vcount,     // 0..255
    output logic       hblank,
    output logic       vblank,
    output logic       hsync,
    output logic       vsync,
    output logic       line_start  // one clk, with the new vcount valid (dot 0 of the line)
);
    always_ff @(posedge clk) begin
        line_start <= 1'b0;
        if (rst) begin
            hcount <= '0;
            vcount <= 8'd224;
        end else if (ce_pix) begin
            if (hcount == 9'd455) begin
                hcount     <= '0;
                vcount     <= vcount + 8'd1;
                line_start <= 1'b1;
            end else
                hcount <= hcount + 9'd1;
        end
    end

    always_comb begin
        hblank = hcount >= 9'd320;
        vblank = vcount >= 8'd224;
        hsync  = (hcount >= 9'd344) && (hcount <= 9'd376);
        vsync  = (vcount >= 8'd232) && (vcount <= 8'd234);
    end
endmodule
