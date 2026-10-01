// Nostradamus MiSTer core -- 038 tilemap line renderer (both chips, one engine).
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Hardware form of MAME 0.289 tmap038 (16x16 tile RAM only, as mapped for nost) +
// mcatadv_state::draw_tilemap_part, per render line y (0..223), layer 0 then layer 1
// (docs/VIDEO.md, scripts/refrender.py tile_layer()):
//   scrollx = (reg0 & 1FF) - 194, scrolly = (reg1 & 1FF) - 1DF
//   reg1 bit 14 (row select): scrolly = lineram[(y + scrolly) & 1FF].word1 - y
//   reg0 bit 14 (row scroll): scrollx += lineram[(y + scrolly) & 1FF].word0
//   reg0/reg1 bit 15 = 0 (flip X / Y): scrollx -= 19 / scrolly -= 141, and the source pixel is
//     sx = (319 + scrollx - x) & 511 / sy = (223 + scrolly - y) & 511 instead of x + scrollx / y + scrolly
//   tile (sy >> 4) * 32 + (sx >> 4): word0 = {cat[1:0], colour[5:0], -}, word1 = code;
//   8x8 code = code * 4 + quadrant, modulo the region's 0xC000 elements = (code % 0x3000) * 4 + q
//   palette index = ((colour + bank * 0x40) % 0x200) * 16 + pen, kept to 12 bits (4096 entries)
//   reg2 bit 4 = layer disable, reg2 bits 3-0 = colour bank (mcatadv get_banked_color).
// Output per layer and x (0..319): {opaque, cat[1:0], index[11:0]} into a line buffer, plus a
// per-line layer-enable flag. A tile row comes from SDRAM as one 4-word burst (16 pixels, 8 bytes,
// high nibble first; rows re-ordered by the loader, docs/ROM_LAYOUT.md).
// Line RAM, tile RAM and registers are read live while the line is rendered (the game updates them
// in vblank: docs/MAME_REFERENCE.md), which equals MAME's render-at-vblank-start state.
module nost_tilemap (
    input  logic        clk,
    input  logic        rst,
    input  logic        start,
    input  logic  [7:0] y,
    output logic        busy,

    input  logic [47:0] regs0,          // {reg2, reg1, reg0} chip 0
    input  logic [47:0] regs1,

    output logic [11:0] vram_addr,      // word address in the chip's 0x2000-byte RAM (both chips)
    input  logic [15:0] vram0_q,
    input  logic [15:0] vram1_q,

    output logic        mem_req,
    output logic [25:1] mem_addr,
    input  logic        mem_ack,
    input  logic [63:0] mem_data,

    output logic        lb_we,
    output logic        lb_layer,
    output logic  [8:0] lb_x,
    output logic [14:0] lb_data,        // {opaque, cat[1:0], index[11:0]}
    output logic        en_we,          // layer-enable flag for this line (with lb_layer)
    output logic        en_data
);
    typedef enum logic [4:0] {S_IDLE, S_LAYER, S_RSEL, S_RSEL_W, S_RSEL_D, S_RSCR, S_RSCR_W,
                              S_RSCR_D, S_SETUP, S_ENT0, S_ENT1, S_ENT2, S_ENT3, S_FETCH, S_PIX,
                              S_NEXT} st_t;
    st_t st;

    logic        layer;
    logic [15:0] r0, r1, r2;
    logic [15:0] scrollx, scrolly;      // 16-bit two's complement, as MAME's int (9 bits matter)
    logic  [8:0] sy;                    // source line
    logic  [8:0] base_x;                // source x of the first fetched pixel
    logic  [4:0] k;                     // tile 0..20
    logic [15:0] w0;
    logic [63:0] pix_q;
    logic  [3:0] p;                     // pixel within the tile

    wire flipx = !r0[15];
    wire flipy = !r1[15];
    wire [15:0] vq = layer ? vram1_q : vram0_q;

    function automatic [15:0] mod3000(input [15:0] c);      // c % 0x3000
        logic [3:0] n;
        logic [3:0] q3;
        n  = c[15:12];
        q3 = (n >= 4'd15) ? 4'd15 : (n >= 4'd12) ? 4'd12 : (n >= 4'd9) ? 4'd9 :
             (n >= 4'd6)  ? 4'd6  : (n >= 4'd3)  ? 4'd3  : 4'd0;
        mod3000 = {n - q3, c[11:0]};
    endfunction

    assign busy = st != S_IDLE;

    always_ff @(posedge clk) begin
        lb_we <= 1'b0;
        en_we <= 1'b0;
        if (rst) begin
            st <= S_IDLE;
            mem_req <= 1'b0;
        end else case (st)
            S_IDLE: if (start) begin
                layer <= 1'b0;
                st    <= S_LAYER;
            end
            S_LAYER: begin
                logic [15:0] a0, a1, a2;
                a0 = layer ? regs1[15:0]  : regs0[15:0];
                a1 = layer ? regs1[31:16] : regs0[31:16];
                a2 = layer ? regs1[47:32] : regs0[47:32];
                r0 <= a0; r1 <= a1; r2 <= a2;
                scrollx  <= {7'd0, a0[8:0]} - 16'h0194;
                scrolly  <= {7'd0, a1[8:0]} - 16'h01DF;
                en_we    <= 1'b1;
                lb_layer <= layer;
                en_data  <= !a2[4];
                st       <= a2[4] ? S_NEXT : S_RSEL;           // reg2 bit 4: layer disabled
            end
            S_RSEL: begin                                      // row select: lineram word 1
                vram_addr <= {2'b10, 9'(16'(y) + scrolly), 1'b1};    // 0x800 + line*2 + 1
                st <= r1[14] ? S_RSEL_W : S_RSCR;
            end
            S_RSEL_W: st <= S_RSEL_D;
            S_RSEL_D: begin
                scrolly <= vq - 16'(y);
                st <= S_RSCR;
            end
            S_RSCR: begin                                      // row scroll: lineram word 0
                vram_addr <= {2'b10, 9'(16'(y) + scrolly), 1'b0};
                st <= r0[14] ? S_RSCR_W : S_SETUP;
            end
            S_RSCR_W: st <= S_RSCR_D;
            S_RSCR_D: begin
                scrollx <= scrollx + vq;
                st <= S_SETUP;
            end
            S_SETUP: begin
                logic [15:0] sx_a, sy_a;
                sx_a = flipx ? scrollx - 16'h0019 : scrollx;
                sy_a = flipy ? scrolly - 16'h0141 : scrolly;
                // non-flipped: pixel x shows source x + sx_a; flipped: 319 + sx_a - x. In both cases
                // the 320 pixels cover source x sx_a .. sx_a + 319 (mod 512).
                base_x <= sx_a[8:0];
                sy     <= flipy ? 9'(16'd223 + sy_a - 16'(y)) : 9'(16'(y) + sy_a);
                k      <= 5'd0;
                st     <= S_ENT0;
            end
            S_ENT0: begin                                      // tile entry word 0
                logic [4:0] col;
                col = base_x[8:4] + k;
                vram_addr <= {1'b0, sy[8:4], col, 1'b0};
                st <= S_ENT1;
            end
            S_ENT1: begin
                vram_addr[0] <= 1'b1;                          // word 1 (code)
                st <= S_ENT2;
            end
            S_ENT2: begin
                w0 <= vq;
                st <= S_ENT3;
            end
            S_ENT3: begin
                logic [15:0] c;
                c = mod3000(vq);
                // SDRAM byte (layer ? 0x600000 : 0x400000) + code * 128 + row * 8
                mem_addr <= (layer ? 25'h300000 : 25'h200000) + {5'd0, c[13:0], sy[3:0], 2'b00};
                mem_req  <= 1'b1;
                st       <= S_FETCH;
            end
            S_FETCH: if (mem_ack) begin
                mem_req <= 1'b0;
                pix_q   <= mem_data;
                p       <= 4'd0;
                st      <= S_PIX;
            end
            S_PIX: begin
                logic [9:0] sxp;                               // offset from base_x, 0..319 visible
                logic [7:0] b;
                logic [3:0] pen;
                logic [7:0] csum;
                sxp  = {1'b0, k, p} - {6'd0, base_x[3:0]};
                b    = pix_q[p[3:1]*8 +: 8];
                pen  = p[0] ? b[3:0] : b[7:4];
                csum = {2'b00, w0[13:8]} + {r2[1:0], 6'd0};    // (colour + bank*0x40) % 0x100
                if (!sxp[9] && sxp < 10'd320) begin
                    lb_we   <= 1'b1;
                    lb_x    <= flipx ? 9'(10'd319 - sxp) : sxp[8:0];
                    lb_data <= {pen != 4'd0, w0[15:14], csum, pen};
                end
                p <= p + 4'd1;
                if (p == 4'd15) begin
                    if (k == 5'd20) st <= S_NEXT;
                    else begin
                        k  <= k + 5'd1;
                        st <= S_ENT0;
                    end
                end
            end
            S_NEXT: begin
                if (!layer) begin
                    layer <= 1'b1;
                    st    <= S_LAYER;
                end else
                    st <= S_IDLE;
            end
            default: st <= S_IDLE;
        endcase
    end
endmodule
