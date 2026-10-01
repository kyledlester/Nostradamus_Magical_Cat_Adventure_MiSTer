// Nostradamus MiSTer core -- sprite line renderer.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Hardware form of MAME 0.289 mcatadv_state::draw_sprites (docs/VIDEO.md, scripts/refrender.py).
// Entry (4 words, buffered half chosen at vblank): w0 = {pri[1:0], pen[5:0], flipx, flipy, -},
// w1 = tile, w2 = {width/16[3:0], -, x[9:0]}, w3 = {height/16[3:0], -, y[9:0]} (x, y signed 10 bit).
// Entries with w3 == w0 are skipped ("don't draw sprites while it's testing the RAM").
// Pixels: nibble address tile*256 + row*width + column (low nibble of a byte first) in the 8 MB
// sprite region; the populated 5 MB are in SDRAM, the erased rest reads 0xF (MAME ROMREGION_ERASEFF).
// Screen position: x + column - (vidreg0 - 0x184), y + row - (vidreg1 - 0x1F1); flips mirror the
// width x height block.
// MAME draws the last entry first and a sprite pixel masks every later one (priority bitmap bit 4),
// whatever its priority against the tiles; so the visible sprite pixel is the opaque pixel of the
// highest-numbered entry. Here entries are scanned 0..2047 and later opaque pixels overwrite earlier
// ones in the line buffer {valid, pri[1:0], pen[5:0], pixel[3:0]}; the tile priority test is applied
// at output (nost_video).
// For render line y every entry is tested (one per clock); hits queue in a small FIFO; each queued
// sprite row is fetched as 16-pixel chunks (one 4-word SDRAM burst each, chunks off screen skipped)
// and written two pixels per clock (even/odd x banks).
module nost_sprites (
    input  logic        clk,
    input  logic        rst,
    input  logic        start,
    input  logic  [7:0] y,
    output logic        busy,

    input  logic [15:0] gx,             // vidregs word 0 (live)
    input  logic [15:0] gy,             // vidregs word 1 (live)

    output logic [10:0] sbuf_addr,      // sprite buffer (registered read, 1 clk)
    input  logic [63:0] sbuf_q,         // {w3, w2, w1, w0}

    output logic        mem_req,
    output logic [25:1] mem_addr,
    input  logic        mem_ack,
    input  logic [63:0] mem_data,

    output logic  [1:0] lb_we,          // [0] even-x bank, [1] odd-x bank
    output logic  [7:0] lb_addr [2],    // x >> 1 per bank
    output logic [11:0] lb_data [2]     // {pri[1:0], pen[5:0], pixel[3:0]} (written = valid)
);
    // ------------------------------------------------------------------ scanner
    logic [11:0] scan;                  // next entry to present (2048 = done)
    logic        pv;                    // sbuf_q holds the entry presented last clock
    logic        scan_done;

    // global offsets as MAME ints: global = vidreg - 0x184 / 0x1F1 (17-bit signed is plenty)
    wire signed [16:0] glx = $signed({1'b0, gx}) - 17'sh0184;
    wire signed [16:0] gly = $signed({1'b0, gy}) - 17'sh01F1;

    // stage 1 (registered after the buffer RAM): raw entry and the screen offsets of its first row /
    // column; stage 2: range tests, duplicate filter, FIFO write. (Two stages keep the RAM output
    // and the comparisons in separate clocks for timing.)
    wire [15:0] e0 = sbuf_q[15:0];
    wire [15:0] e2 = sbuf_q[47:32];
    wire [15:0] e3 = sbuf_q[63:48];
    logic [63:0] q1;
    logic        v1;
    logic signed [16:0] dy1, ex1;       // row within the sprite, screen x of column 0
    always_ff @(posedge clk) begin
        q1  <= sbuf_q;
        v1  <= pv && !rst && !start;
        dy1 <= $signed({9'd0, y}) + gly - $signed({{7{e3[9]}}, e3[9:0]});
        ex1 <= $signed({{7{e2[9]}}, e2[9:0]}) - glx;
    end
    wire [15:0] q1w0 = q1[15:0];
    wire [15:0] q1w2 = q1[47:32];
    wire [15:0] q1w3 = q1[63:48];
    wire        [7:0]  eh  = {q1w3[15:12], 4'd0};
    wire        [7:0]  ew  = {q1w2[15:12], 4'd0};
    wire hit = v1 && q1w3 != q1w0 && q1w2[15:12] != 0 && q1w3[15:12] != 0 &&
               dy1 >= 0 && dy1 < $signed({9'd0, eh}) &&
               ex1 < 17'sd320 && ex1 + $signed({9'd0, ew}) > 0;

    // data row: MAME consumes rows in drawing order, so with flipy row k of the data is drawn at
    // screen row height - 1 - k
    wire [7:0] krow = q1w0[6] ? eh - 8'd1 - dy1[7:0] : dy1[7:0];

    // FIFO of hits: {w0, w1, w2, data row}
    localparam int FD = 16;
    logic [55:0] fifo [FD];
    logic  [4:0] f_wr, f_rd;
    wire  [4:0]  f_cnt = f_wr - f_rd;
    wire         f_full = f_cnt >= 5'(FD - 4);   // room for the entries still in the pipeline
    wire         f_empty = f_cnt == 0;
    logic        f_pop;

    assign sbuf_addr = scan[10:0];

    // An entry identical to the previous hit adds nothing (same pixels, same place, same attributes,
    // nothing drawn in between), so it is dropped: the game parks its unused entries as hundreds of
    // identical transparent sprites at (0,0), which would otherwise cost one fetch each.
    logic [63:0] last_hit;
    logic        last_v;
    always_ff @(posedge clk) begin
        if (rst) begin
            scan <= 12'd2048;
            pv   <= 1'b0;
            f_wr <= '0;
            scan_done <= 1'b1;
            last_v <= 1'b0;
        end else begin
            if (start) begin
                scan <= 12'd0;
                pv   <= 1'b0;
                scan_done <= 1'b0;
                last_v <= 1'b0;
            end else begin
                if (hit) begin
                    last_hit <= q1;
                    last_v   <= 1'b1;
                end
                if (hit && !(last_v && last_hit == q1)) begin
                    fifo[f_wr[3:0]] <= {q1[15:0], q1[31:16], q1[47:32], krow};
                    f_wr <= f_wr + 5'd1;
                end
                if (!scan_done) begin
                    if (!f_full) begin
                        pv <= !scan[11];
                        if (scan[11]) scan_done <= 1'b1;
                        else scan <= scan + 12'd1;
                    end else
                        pv <= 1'b0;
                end else
                    pv <= 1'b0;
            end
        end
    end

    // ------------------------------------------------------------------ chunk fetcher
    typedef enum logic [2:0] {D_IDLE, D_SETUP, D_CHUNK, D_FETCH, D_PUSH} dst_t;
    dst_t dst;
    logic [15:0] d0;
    logic [23:0] nib;                   // nibble address of chunk 0 of the row
    logic  [3:0] nchunk;                // width/16 - 1
    logic  [3:0] j;                     // chunk
    logic signed [16:0] x0;
    logic [63:0] pix_q;
    logic        w_busy;
    wire         w_load = dst == D_PUSH && !w_busy;

    always_ff @(posedge clk) begin
        f_pop <= 1'b0;
        if (rst) begin
            dst <= D_IDLE;
            mem_req <= 1'b0;
            f_rd <= '0;
        end else case (dst)
            D_IDLE: if (!f_empty && !f_pop) dst <= D_SETUP;
            D_SETUP: begin
                logic [55:0] f;
                logic [15:0] w1, w2;
                logic  [7:0] k;
                f   = fifo[f_rd[3:0]];
                d0  <= f[55:40];
                w1  = f[39:24];
                w2  = f[23:8];
                k   = f[7:0];
                f_rd  <= f_rd + 5'd1;
                f_pop <= 1'b1;
                nchunk <= w2[15:12] - 4'd1;
                x0  <= {{7{w2[9]}}, w2[9:0]} - glx;
                j   <= 4'd0;
                nib <= {w1, 8'd0} + 24'(k) * 24'({w2[15:12], 4'd0});   // tile*256 + k*width
                dst <= D_CHUNK;
            end
            D_CHUNK: begin
                // chunk j covers data columns 16j..16j+15 -> screen x0 + 16j + p, or with flipx
                // x0 + w - 1 - (16j + p) = x0 + 16(nchunk - j) + (15 - p)
                logic signed [16:0] cx;
                logic [23:0] n;
                logic [22:0] byte_a;
                cx = x0 + $signed({9'd0, (d0[7] ? nchunk - j : j), 4'd0});
                n  = nib + {16'd0, j, 4'd0};
                byte_a = n[23:1];
                if (cx >= 17'sd320 || cx + 17'sd16 <= 0) begin   // off screen: skip
                    if (j == nchunk) dst <= D_IDLE;
                    else j <= j + 4'd1;
                end else if (byte_a >= 23'h500000) begin          // unpopulated: 0xFF
                    pix_q <= '1;
                    dst   <= D_PUSH;
                end else begin
                    mem_req  <= 1'b1;
                    mem_addr <= 25'h400000 + {3'd0, byte_a[22:1]};   // SDRAM byte 0x800000 + byte_a
                    dst      <= D_FETCH;
                end
            end
            D_FETCH: if (mem_ack) begin
                mem_req <= 1'b0;
                pix_q   <= mem_data;
                dst     <= D_PUSH;
            end
            D_PUSH: if (!w_busy) begin
                if (j == nchunk) dst <= D_IDLE;
                else begin
                    j   <= j + 4'd1;
                    dst <= D_CHUNK;
                end
            end
            default: dst <= D_IDLE;
        endcase
    end

    // ------------------------------------------------------------------ line-buffer writer
    logic  [2:0] w_cnt;
    logic [63:0] w_pix;
    logic signed [16:0] w_x;            // screen x of data pixel 0 of the chunk (flip: of pixel 15)
    logic        w_flip;
    logic  [7:0] w_attr;                // {pri, pen}

    always_ff @(posedge clk) begin
        lb_we <= 2'b00;
        if (rst) begin
            w_busy <= 1'b0;
        end else if (w_load) begin
            w_busy <= 1'b1;
            w_cnt  <= 3'd0;
            w_pix  <= pix_q;
            w_flip <= d0[7];
            w_attr <= {d0[15:14], d0[13:8]};
            w_x    <= x0 + $signed({9'd0, (d0[7] ? nchunk - j : j), 4'd0});
        end else if (w_busy) begin
            // data pixels 2c and 2c+1 (c = w_cnt): nibbles of the little-endian burst
            logic [3:0] pa, pb;
            logic signed [16:0] xa, xb;
            pa = w_pix[w_cnt*8 +: 4];
            pb = w_pix[w_cnt*8 + 4 +: 4];
            xa = w_flip ? w_x + 17'sd15 - $signed({13'd0, w_cnt, 1'b0}) : w_x + $signed({13'd0, w_cnt, 1'b0});
            xb = w_flip ? xa - 17'sd1 : xa + 17'sd1;
            lb_addr[xa[0]] <= xa[8:1];
            lb_data[xa[0]] <= {w_attr, pa};
            lb_addr[xb[0]] <= xb[8:1];
            lb_data[xb[0]] <= {w_attr, pb};
            lb_we[xa[0]]   <= xa >= 0 && xa < 17'sd320 && pa != 4'd0;
            lb_we[xb[0]]   <= xb >= 0 && xb < 17'sd320 && pb != 4'd0;
            w_cnt <= w_cnt + 3'd1;
            if (w_cnt == 3'd7) w_busy <= 1'b0;
        end
    end

    assign busy = !scan_done || pv || v1 || !f_empty || dst != D_IDLE || w_busy || f_pop;
endmodule
