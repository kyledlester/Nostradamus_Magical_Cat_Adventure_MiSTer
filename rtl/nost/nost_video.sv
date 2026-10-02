// Nostradamus MiSTer core -- video: line renderers, line buffers, priority mixer, palette.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// docs/VIDEO.md. During raster line v the tilemap and sprite engines render line v+1 (0..223) into
// the line-buffer half (v+1)[0]; the output side reads half v[0] (and clears the sprite entries).
// Mixer = MAME mcatadv screen_update: background pen 0x3F0; the two 038 layers are drawn by
// category 0..3, layer 0 then layer 1 within a category, so the visible tile pixel is the opaque one
// with the highest (category, layer); the priority bitmap is the OR of 8|category of every opaque
// layer pixel; the sprite pixel (highest opaque entry, nost_sprites) is shown if that OR < 8|pri.
// Palette xGRB_555 (MAME palette_device::xGRB_555) read live from the 68000 board's palette RAM;
// 5-bit channels expanded as MAME's pal5bit (x << 3 | x >> 2).
// The output is one dot late relative to the raster counters; blank/sync are delayed with it.
module nost_video (
    input  logic         clk,
    input  logic         rst,
    input  logic         ce_pix,
    input  logic   [8:0] hcount,
    input  logic   [7:0] vcount,
    input  logic         line_start,
    input  logic         hblank_in,
    input  logic         vblank_in,
    input  logic         hsync_in,
    input  logic         vsync_in,
    input  logic         flip180,           // OSD "Flip screen": whole picture rotated 180 degrees

    input  logic  [47:0] tm0_regs,
    input  logic  [47:0] tm1_regs,
    input  logic  [15:0] spr_gx,
    input  logic  [15:0] spr_gy,

    // 68000 board read ports (registered, 1 clk)
    output logic  [11:0] vram_addr,
    input  logic  [15:0] vram0_q,
    input  logic  [15:0] vram1_q,
    output logic  [10:0] sbuf_addr,
    input  logic  [63:0] sbuf_q,
    output logic  [11:0] pal_addr,
    input  logic  [15:0] pal_q,

    // SDRAM clients
    output logic         tm_req,
    output logic  [25:1] tm_addr,
    input  logic         tm_ack,
    output logic         sp_req,
    output logic  [25:1] sp_addr,
    input  logic         sp_ack,
    input  logic  [63:0] mem_data,

    output logic  [23:0] rgb,
    output logic         hblank,
    output logic         vblank,
    output logic         hsync,
    output logic         vsync,

    output logic  [15:0] dbg_overruns,      // lines whose render had not finished in time
    output logic  [15:0] dbg_max_busy       // longest render (clocks) since reset
);
    // ------------------------------------------------------------------ render start
    wire  [7:0] next_line = vcount + 8'd1;  // vcount is already the new line at line_start
    logic       render_start, render_pend, abort;
    logic [7:0] render_y;
    logic       render_half;          // line-buffer half = parity of the DISPLAY line
    logic       flip_f = 1'b0;        // flip180, changed only between frames
    logic       tm_busy, sp_busy;
    logic [15:0] busy_cnt;

    always_ff @(posedge clk) begin
        render_start <= 1'b0;
        abort        <= 1'b0;
        render_pend  <= 1'b0;
        if (rst) begin
            flip_f       <= flip180;
            dbg_overruns <= '0;
            dbg_max_busy <= '0;
            busy_cnt     <= '0;
        end else begin
            if (tm_busy || sp_busy) busy_cnt <= busy_cnt + 16'd1;
            else if (busy_cnt != 0) begin
                if (busy_cnt > dbg_max_busy) dbg_max_busy <= busy_cnt;
                busy_cnt <= '0;
            end
            if (line_start && next_line < 8'd224) begin
                if (tm_busy || sp_busy) begin
                    dbg_overruns <= dbg_overruns + 16'd1;
                    abort <= 1'b1;
                end
                render_pend <= 1'b1;
                // flip: display line y shows rendered line 223 - y (and x mirrored at read-out)
                render_y    <= flip_f ? 8'd223 - next_line : next_line;
                render_half <= next_line[0];
            end
            render_start <= render_pend;
            if (line_start && vcount == 8'd224) flip_f <= flip180;
        end
    end
    wire wr_half = render_half;
    wire rd_half = vcount[0];

    // ------------------------------------------------------------------ engines
    logic        tlb_we, tlb_layer, ten_we, ten_data;
    logic [8:0]  tlb_x;
    logic [14:0] tlb_data;
    nost_tilemap tilemap (
        .clk(clk), .rst(rst || abort), .start(render_start), .y(render_y), .busy(tm_busy),
        .regs0(tm0_regs), .regs1(tm1_regs),
        .vram_addr(vram_addr), .vram0_q(vram0_q), .vram1_q(vram1_q),
        .mem_req(tm_req), .mem_addr(tm_addr), .mem_ack(tm_ack), .mem_data(mem_data),
        .lb_we(tlb_we), .lb_layer(tlb_layer), .lb_x(tlb_x), .lb_data(tlb_data),
        .en_we(ten_we), .en_data(ten_data));

    logic [1:0]  slb_we;
    logic [7:0]  slb_addr [2];
    logic [11:0] slb_data [2];
    nost_sprites sprites (
        .clk(clk), .rst(rst || abort), .start(render_start), .y(render_y), .busy(sp_busy),
        .gx(spr_gx), .gy(spr_gy), .sbuf_addr(sbuf_addr), .sbuf_q(sbuf_q),
        .mem_req(sp_req), .mem_addr(sp_addr), .mem_ack(sp_ack), .mem_data(mem_data),
        .lb_we(slb_we), .lb_addr(slb_addr), .lb_data(slb_data));

    // ------------------------------------------------------------------ line buffers
    logic [8:0]  rd_x;
    logic [14:0] t0q, t1q;
    logic [12:0] sq [2];          // {valid, pri[1:0], pen[5:0], pixel[3:0]}
    logic        clr;                   // clear the sprite entry read one clock earlier
    logic [1:0]  en [2];                // [half][layer] layer enabled for the line

    nost_sdpram #(.AW(10), .DW(15)) tlb0 (
        .clk(clk), .w_addr({wr_half, tlb_x}), .we(tlb_we && !tlb_layer), .din(tlb_data),
        .r_addr({rd_half, rd_x}), .dout(t0q));
    nost_sdpram #(.AW(10), .DW(15)) tlb1 (
        .clk(clk), .w_addr({wr_half, tlb_x}), .we(tlb_we && tlb_layer), .din(tlb_data),
        .r_addr({rd_half, rd_x}), .dout(t1q));
    always_ff @(posedge clk) if (ten_we) en[wr_half][tlb_layer] <= ten_data;

    genvar b;
    generate
    for (b = 0; b < 2; b = b + 1) begin : slb_banks
        nost_tdpram #(.AW(9), .DW(13)) slb (
            .clk(clk),
            .a_addr({rd_half, rd_x[8:1]}), .a_we(clr && rd_x[0] == 1'(b)), .a_din(13'd0), .a_dout(sq[b]),
            .b_addr({wr_half, slb_addr[b]}), .b_we(slb_we[b]), .b_din({1'b1, slb_data[b]}));
    end
    endgenerate

    // ------------------------------------------------------------------ output pipeline
    // ce_pix: address = hcount; +1: line-buffer read; +2: mix -> palette address; +3: palette
    // read; +4: colour.
    logic [3:0]  ph;
    logic        vis_d1, vis_d2;
    logic [23:0] rgb_next;
    logic        hb_d, vb_d, hs_d, vs_d;
    logic [1:0]  en_r;

    function automatic [7:0] c5(input [4:0] x); c5 = {x, x[4:2]}; endfunction

    always_ff @(posedge clk) begin
        clr <= 1'b0;
        if (ce_pix) begin
            rd_x   <= (flip_f && hcount < 9'd320) ? 9'd319 - hcount : hcount;
            en_r   <= en[rd_half];
            ph     <= 4'd1;
            vis_d1 <= !hblank_in && !vblank_in;
            rgb    <= rgb_next;
            {hblank, vblank, hsync, vsync} <= {hb_d, vb_d, hs_d, vs_d};
            {hb_d, vb_d, hs_d, vs_d} <= {hblank_in, vblank_in, hsync_in, vsync_in};
        end else if (ph != 0) begin
            ph <= ph + 4'd1;
            case (ph)
                4'd2: begin                          // line-buffer data valid for rd_x
                    logic        o0, o1, sv;
                    logic [1:0]  c0, c1;
                    logic [3:0]  pmap;
                    logic [11:0] tidx;
                    logic [12:0] s;
                    o0 = en_r[0] && t0q[14];
                    o1 = en_r[1] && t1q[14];
                    c0 = t0q[13:12];
                    c1 = t1q[13:12];
                    tidx = (o1 && (!o0 || c1 >= c0)) ? t1q[11:0] : o0 ? t0q[11:0] : 12'h3F0;
                    pmap = (o0 ? {2'b10, c0} : 4'd0) | (o1 ? {2'b10, c1} : 4'd0);
                    s  = sq[rd_x[0]];
                    sv = s[12] && pmap < {2'b10, s[11:10]};
                    pal_addr <= sv ? {2'b00, s[9:0]} : tidx;
                    vis_d2   <= vis_d1;
                    clr      <= vis_d1;
                end
                4'd4: begin                          // palette data valid
                    rgb_next <= !vis_d2 ? 24'h000000 :
                                {c5(pal_q[9:5]), c5(pal_q[14:10]), c5(pal_q[4:0])};
                    ph <= 4'd0;
                end
                default: ;
            endcase
        end
    end
endmodule
