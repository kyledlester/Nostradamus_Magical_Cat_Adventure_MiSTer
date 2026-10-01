// Nostradamus MiSTer core (from the owner's R-Shark core) -- debug overlay (OSD "Debug overlay"):
// seven 32-bit hex values.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Drawn so that it reads left-to-right on the ROT270 (counter-clockwise rotated) display:
// display (X, Y) = (raster y, 319 - raster x) over the 320 x 224 visible area. Text origin display
// (8, 8), 8 x 8 glyphs, 16-pixel line pitch; black box behind the text. hcount/vcount are the raster
// counters; the overlay's pixel decision is aligned with rgb_in, which is 2 dots behind hcount.
module nost_overlay (
    input  logic        clk,
    input  logic        ce_pix,
    input  logic  [8:0] hcount,
    input  logic  [7:0] vcount,
    input  logic        enable,
    input  logic [223:0] values,     // value k at [223-32k -: 32] (k = 0 is the top line)
    input  logic [23:0] rgb_in,
    output logic [23:0] rgb_out
);
    function automatic [7:0] glyph(input [3:0] d, input [2:0] row);
        logic [63:0] g;
        case (d)
            4'h0: g = 64'h3C_66_6E_76_66_66_3C_00;
            4'h1: g = 64'h18_38_18_18_18_18_7E_00;
            4'h2: g = 64'h3C_66_06_0C_30_60_7E_00;
            4'h3: g = 64'h3C_66_06_1C_06_66_3C_00;
            4'h4: g = 64'h0C_1C_3C_6C_7E_0C_0C_00;
            4'h5: g = 64'h7E_60_7C_06_06_66_3C_00;
            4'h6: g = 64'h3C_60_7C_66_66_66_3C_00;
            4'h7: g = 64'h7E_06_0C_18_30_30_30_00;
            4'h8: g = 64'h3C_66_66_3C_66_66_3C_00;
            4'h9: g = 64'h3C_66_66_3E_06_0C_38_00;
            4'hA: g = 64'h18_3C_66_66_7E_66_66_00;
            4'hB: g = 64'h7C_66_66_7C_66_66_7C_00;
            4'hC: g = 64'h3C_66_60_60_60_66_3C_00;
            4'hD: g = 64'h78_6C_66_66_66_6C_78_00;
            4'hE: g = 64'h7E_60_60_7C_60_60_7E_00;
            default: g = 64'h7E_60_60_7C_60_60_60_00;
        endcase
        glyph = g[63 - row*8 -: 8];
    endfunction

    // dot whose colour is on rgb_in
    wire [8:0] hx = hcount - 9'd2;
    wire [8:0] xv = hx;                         // raster visible x (valid when hx < 320)
    wire [7:0] yv = vcount;
    wire [8:0] dy = 9'd319 - xv;                // display Y
    wire [7:0] dx = yv;                         // display X

    logic       in_box, pix;          // registered; used on the next ce_pix (14 clocks later)
    always_ff @(posedge clk) begin
        logic [8:0] ly; logic [7:0] lx; logic [7:0] g;
        in_box <= 1'b0; pix <= 1'b0;
        ly = dy - 9'd8;                          // text-relative display Y / X
        lx = dx - 8'd8;
        if (hx < 9'd320 && vcount < 8'd224 &&
            dy >= 9'd6 && dy < 9'd8 + 9'd112 && dx >= 8'd6 && dx < 8'd8 + 8'd66) begin
            in_box <= 1'b1;
            if (dy >= 9'd8 && dx >= 8'd8 && ly[3] == 1'b0 && ly[8:4] < 5'd7 && lx < 8'd64) begin
                g = glyph(values[223 - ly[6:4]*32 - lx[5:3]*4 -: 4], ly[2:0]);
                pix <= g[7 - lx[2:0]];
            end
        end
    end

    always_comb rgb_out = (enable && in_box) ? (pix ? 24'hFFFFFF : 24'h000040) : rgb_in;
endmodule
