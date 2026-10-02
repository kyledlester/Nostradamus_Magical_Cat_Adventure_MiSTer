// LINDA board MiSTer core -- 038 tilemap line renderer using the Cave core's 038 layer processor.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Alternative to nost_tilemap (OSD "Tilemap engine: Cave 038"), same interface. The 038 itself is
// rtl/vendor/cave/CaveLayerProcessor.sv from MiSTer-devel/Arcade-Cave_MiSTer (Josh Bassett /
// nullobject, GPL-3.0), UNMODIFIED. That module is a raster-synchronous pixel pipeline: per pixel
// clock enable it latches tile RAM, line RAM and tile-ROM data addressed by its own combinational
// outputs. This adapter "plays the raster" for one render line at a time inside the line renderer:
// for x = -32 .. 319 it presents the position, waits until the module's addresses are stable, reads
// tile RAM / line RAM (16-bit board RAM, two words per 32-bit read) and the tile-ROM word (SDRAM,
// MAME byte order copy of the region, 8 bytes = two 8-pixel rows), records the pen the module
// outputs for x, and then gives it one clock enable. 32 lead-in pixels prime its one-tile-ahead
// fetch pipeline.
// Board adaptation (inputs only, nothing inside the Cave module changed):
//   * scroll origin: the module computes x + scroll - spriteOffset - layerOffset (0x12 for 16x16);
//     spriteOffset_x = 0x194 - 0x12 and spriteOffset_y = 0x1DF - 0x1EE give MAME's nost origin
//     (scroll - 0x194, scroll - 0x1DF); video size 0x101 / 0x1C1 reproduce MAME's flipped origin;
//   * nost maps only the 16x16 tile RAM (tile size forced to 16x16), 4 bpp, pen 0 transparent;
//   * colour bank (reg 2 bits 3-0, mcatadv get_banked_color) and the region's code wrap
//     (code_wrap) are applied outside the module, as in nost_tilemap.
// Row scroll / row select are computed by the module (row select replaces the line, row scroll adds
// to x); the adapter supplies the line-RAM words at this board's indices (CAVE_LINE_INDEX below).
module nost_tilemap_cave #(
    // 0: line RAM entries indexed as on this board (MAME mcatadv): row select at the scrolled line,
    //    row scroll at the selected line. 1: the Cave module's own lookup (both words at its
    //    scrolled line - 1); on nost that shows the background one line lower and reads an entry the
    //    game never writes on line 0, so it is kept only for comparison.
    parameter bit CAVE_LINE_INDEX = 1'b0
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        start,
    input  logic  [7:0] y,
    output logic        busy,

    input  logic [47:0] regs0,          // {reg2, reg1, reg0} chip 0
    input  logic [47:0] regs1,
    input  logic        mcat,           // game select (tile ROM sizes)

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
    output logic        en_we,
    output logic        en_data
);
    typedef enum logic [4:0] {S_IDLE, S_LAYER, S_LR0, S_LR1, S_LR2, S_LR3, S_LR4, S_LR5, S_LR6, S_POS, S_VR0, S_VR1,
                              S_VR2, S_VR3, S_ROM, S_FETCH, S_STEP, S_NEXT} st_t;
    st_t st;

    logic        layer;
    logic [15:0] r0, r1, r2;
    logic  [9:0] vx;                    // signed position -32..319
    wire         ce;                    // the module's pixel clock enable (one per S_STEP)
    logic [31:0] lineram_q32, vram_q32;
    logic [10:0] vram_cached;           // {valid, tile index}
    logic [26:0] rom_cached;            // {valid, byte address [25:0]}
    logic [63:0] rom_q;                 // module's big-endian view of the ROM word
    logic [15:0] lo_word, hi_word;

    wire [15:0] vq = layer ? vram1_q : vram0_q;
    wire  [8:0] mame_line = {1'b0, y} + r1[8:0] - 9'h1DF;   // MAME drawline + scrolly

    // ------------------------------------------------------------------ the Cave 038
    wire [9:0]  m_vram_addr;
    wire [8:0]  m_line_addr;
    wire [31:0] m_rom_addr;
    wire [1:0]  pen_pri;
    wire [5:0]  pen_pal;
    wire [7:0]  pen_col;
    CaveLayerProcessor #(.LAYER_OFFSET_LARGE(5'h12), .LAYER_OFFSET_SMALL(5'h0A)) l038 (
        .clock(clk),
        .io_ctrl_enable(1'b1), .io_ctrl_format(2'h1), .io_ctrl_zero4bppPenF(1'b0), .io_ctrl_pwrinst2(1'b0),
        .io_ctrl_regs_tileSize(1'b1), .io_ctrl_regs_enable(!r2[4]),
        .io_ctrl_regs_flipX(!r0[15]), .io_ctrl_regs_flipY(!r1[15]),
        .io_ctrl_regs_rowScrollEnable(r0[14]), .io_ctrl_regs_rowSelectEnable(r1[14]),
        .io_ctrl_regs_scroll_x(r0[8:0]), .io_ctrl_regs_scroll_y(r1[8:0]),
        .io_ctrl_vram8x8_addr(), .io_ctrl_vram8x8_dout(32'd0),
        .io_ctrl_vram16x16_addr(m_vram_addr), .io_ctrl_vram16x16_dout(vram_q32),
        .io_ctrl_lineRam_addr(m_line_addr), .io_ctrl_lineRam_dout(lineram_q32),
        .io_ctrl_tileRom_rd(), .io_ctrl_tileRom_addr(m_rom_addr), .io_ctrl_tileRom_dout(rom_q),
        .io_video_clockEnable(ce), .io_video_pos_x(vx[8:0]), .io_video_pos_y({1'b0, y}),
        .io_video_vBlank(1'b0),
        .io_video_regs_size_x(9'h101), .io_video_regs_size_y(9'h1C1),
        .io_spriteOffset_x(9'h182), .io_spriteOffset_y(9'h1F1),
        .io_pen_priority(pen_pri), .io_pen_palette(pen_pal), .io_pen_color(pen_col));

    // MAME draws 8x8 element code * 4 + q modulo the region's element count (gfx_element
    // get_data): 16x16 code % (region bytes / 128). nost: bg0 / bg1 0x180000 -> % 0x3000;
    // mcatadv: bg0 0x80000 -> % 0x1000, bg1 0x280000 -> % 0x5000.
    function automatic [15:0] code_wrap(input [15:0] c, input mc, input lyr);
        logic [3:0] n, q;
        n = c[15:12];
        if (!mc)
            q = (n >= 4'd15) ? 4'd15 : (n >= 4'd12) ? 4'd12 : (n >= 4'd9) ? 4'd9 :
                (n >= 4'd6)  ? 4'd6  : (n >= 4'd3)  ? 4'd3  : 4'd0;
        else if (lyr)
            q = (n >= 4'd15) ? 4'd15 : (n >= 4'd10) ? 4'd10 : (n >= 4'd5) ? 4'd5 : 4'd0;
        else
            q = n;
        code_wrap = {n - q, c[11:0]};
    endfunction
    // ROM byte address: {code[15:0], y3, half, pair, 3'b000} (= MAME's 8x8 element code*4+q, row
    // pair); code wrapped as MAME
    wire [15:0] rom_code = code_wrap(m_rom_addr[22:7], mcat, layer);
    wire [25:0] rom_byte = {3'b000, rom_code, m_rom_addr[6:0]};

    assign busy = st != S_IDLE;
    assign ce = st == S_STEP;

    always_ff @(posedge clk) begin
        lb_we <= 1'b0;
        en_we <= 1'b0;
        if (rst) begin
            st <= S_IDLE;
            mem_req <= 1'b0;
            rom_cached <= '0;
        end else case (st)
            S_IDLE: if (start) begin
                layer <= 1'b0;
                st    <= S_LAYER;
            end
            S_LAYER: begin
                r0 <= layer ? regs1[15:0]  : regs0[15:0];
                r1 <= layer ? regs1[31:16] : regs0[31:16];
                r2 <= layer ? regs1[47:32] : regs0[47:32];
                en_we    <= 1'b1;
                lb_layer <= layer;
                en_data  <= !(layer ? regs1[36] : regs0[36]);
                vx <= -10'sd32;
                vram_cached <= '0;
                rom_cached  <= '0;
                st <= (layer ? regs1[36] : regs0[36]) ? S_NEXT : S_POS;
            end
            // the module's line-RAM address depends on y and the registers only: once per layer
            S_POS: begin
                if (CAVE_LINE_INDEX) begin
                    vram_addr <= {2'b10, m_line_addr, 1'b0};         // line RAM word 0 (row scroll)
                    st <= S_LR0;
                end else begin
                    vram_addr <= {2'b10, mame_line, 1'b1};           // row select of the scrolled line
                    st <= S_LR3;
                end
            end
            S_LR0: begin vram_addr[0] <= 1'b1; st <= S_LR1; end      // word 1 (row select)
            S_LR1: begin lo_word <= vq; st <= S_LR2; end
            S_LR2: begin lineram_q32 <= {vq, lo_word}; st <= S_VR0; end
            S_LR3: st <= S_LR4;
            S_LR4: begin
                hi_word   <= vq;                                     // row scroll of the selected line
                vram_addr <= {2'b10, r1[14] ? vq[8:0] : mame_line, 1'b0};
                st <= S_LR5;
            end
            S_LR5: st <= S_LR6;
            S_LR6: begin
                // MAME applies the flip after row select (scrolly = rowselect - line, then flipped:
                // source row 223 + scrolly - 0x141 - line); the module uses the row-select value as
                // the tile row directly, so flipped it gets rowselect - 2*line + 0x19E.
                lineram_q32 <= {r1[15] ? hi_word : 16'(hi_word[8:0] - {y, 1'b0} + 9'h19E), vq};
                st <= S_VR0;
            end
            // tile RAM entry for the module's (row-effect dependent) address
            S_VR0: begin
                if (vram_cached == {1'b1, m_vram_addr}) st <= S_ROM;
                else begin
                    vram_addr <= {1'b0, m_vram_addr, 1'b0};
                    st <= S_VR1;
                end
            end
            S_VR1: begin vram_addr[0] <= 1'b1; st <= S_VR2; end
            S_VR2: begin lo_word <= vq; st <= S_VR3; end
            S_VR3: begin
                vram_q32    <= {vq, lo_word};                         // {code, attributes}
                vram_cached <= {1'b1, m_vram_addr};
                st <= S_ROM;
            end
            S_ROM: begin
                if (rom_cached == {1'b1, rom_byte}) st <= S_STEP;
                else begin
                    // SDRAM byte (layer ? 0x1200000 : 0x1000000) + rom_byte (MAME byte order copy)
                    mem_addr <= (layer ? 25'h900000 : 25'h800000) + {1'b0, rom_byte[25:1]};
                    mem_req  <= 1'b1;
                    st       <= S_FETCH;
                end
            end
            S_FETCH: if (mem_ack) begin
                mem_req <= 1'b0;
                for (int j = 0; j < 8; j++) rom_q[(7 - j) * 8 +: 8] <= mem_data[j * 8 +: 8];
                rom_cached <= {1'b1, rom_byte};
                st <= S_STEP;
            end
            S_STEP: begin
                // the pen output belongs to vx; record it, then clock the module once
                if (!vx[9] && vx < 10'd320) begin
                    logic [7:0] csum;
                    csum    = {2'b00, pen_pal} + {r2[1:0], 6'd0};    // (colour + bank*0x40) % 0x100
                    lb_we   <= 1'b1;
                    lb_x    <= vx[8:0];
                    lb_data <= {pen_col[3:0] != 4'd0, pen_pri, csum, pen_col[3:0]};
                end
                if (vx == 10'd319) st <= S_NEXT;
                else begin
                    vx <= vx + 10'd1;
                    st <= S_VR0;                     // line RAM is per line: read once per layer
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
