// M3: video render of a captured MAME frame through the production video path
// (nost_video + nost_sdram_arb + vendored sdram.sv + SDRAM chip model preloaded with the loader's
// image), compared pixel-exactly with MAME's rendered frame.
// Inputs: +FRAME=<dir> from scripts/mame/capture_frames.lua and local/sim/sdram_be.bin
// (scripts/romtool.py images). The board state is presented as MAME used it at its render instant
// (tile RAM, line RAM, registers, live vidregs, sprite buffer of the previous vblank); the palette is
// MAME's readout palette (palette_next.bin, docs/MAME_REFERENCE.md), so the output must equal
// MAME's pixels.bin. +DUMP=<file> writes the FPGA frame (320x224 RGB24).
`timescale 1ns/1ps
module tb_render;
    logic clk = 0;
    always #5.099 clk = ~clk;
    logic init = 1, rst = 1;

    logic ce_pix, tick32, phi1, phi2;
    nost_clocks clocks (.clk(clk), .rst(rst), .rst_video(init), .pause(1'b0),
        .ce_pix(ce_pix), .tick32(tick32), .phi1(phi1), .phi2(phi2));
    logic [8:0] hc; logic [7:0] vc; logic hb, vb, hs, vs, ls;
    nost_video_timing timing (.clk(clk), .rst(init), .ce_pix(ce_pix),
        .hcount(hc), .vcount(vc), .hblank(hb), .vblank(vb), .hsync(hs), .vsync(vs), .line_start(ls));

    // ------------------------------------------------------------------ frame state
    string frame, sdram_img, dump;
    logic [15:0] vram0 [], vram1 [], pal [], spr [], tm [], vid [], vbuf [];
    logic [7:0]  mame_px [320*224*4];

    task automatic read_be16(input string f, ref logic [15:0] m [], input int n);
        int fd; logic [7:0] hi, lo;
        fd = $fopen(f, "rb");
        if (fd == 0) begin $display("FAIL M3_RENDER: cannot open %s", f); $finish; end
        m = new[n];
        for (int i = 0; i < n; i++) begin
            void'($fread(hi, fd)); void'($fread(lo, fd));
            m[i] = {hi, lo};
        end
        $fclose(fd);
    endtask

    // 68000-board read ports (registered, as nost_main)
    logic [11:0] vram_addr, pal_addr;
    logic [10:0] sbuf_addr;
    logic [15:0] vram0_q, vram1_q, pal_q;
    logic [63:0] sbuf_q;
    logic        half;
    always_ff @(posedge clk) begin
        vram0_q <= vram0[vram_addr];
        vram1_q <= vram1[vram_addr];
        pal_q   <= pal[pal_addr];
        sbuf_q  <= {spr[{half, sbuf_addr, 2'd3}], spr[{half, sbuf_addr, 2'd2}],
                    spr[{half, sbuf_addr, 2'd1}], spr[{half, sbuf_addr, 2'd0}]};
    end

    // ------------------------------------------------------------------ DUT
    logic [47:0] tm0r, tm1r;
    logic flip180 = 0;
    initial if ($test$plusargs("FLIP180")) flip180 = 1;   // MAME pixels rotated 180 degrees are the reference
    logic [15:0] gx, gy;
    logic tm_req, sp_req, tm_ack, sp_ack;
    logic [25:1] tm_addr, sp_addr;
    logic [63:0] mem_data;
    logic [23:0] rgb;
    logic ohb, ovb, ohs, ovs;
    logic [15:0] overruns, maxbusy;
    nost_video video (
        .clk(clk), .rst(rst), .ce_pix(ce_pix), .hcount(hc), .vcount(vc), .line_start(ls),
        .hblank_in(hb), .vblank_in(vb), .hsync_in(hs), .vsync_in(vs), .flip180(flip180),
        .tm0_regs(tm0r), .tm1_regs(tm1r), .spr_gx(gx), .spr_gy(gy),
        .vram_addr(vram_addr), .vram0_q(vram0_q), .vram1_q(vram1_q),
        .sbuf_addr(sbuf_addr), .sbuf_q(sbuf_q), .pal_addr(pal_addr), .pal_q(pal_q),
        .tm_req(tm_req), .tm_addr(tm_addr), .tm_ack(tm_ack),
        .sp_req(sp_req), .sp_addr(sp_addr), .sp_ack(sp_ack), .mem_data(mem_data),
        .rgb(rgb), .hblank(ohb), .vblank(ovb), .hsync(ohs), .vsync(ovs),
        .dbg_overruns(overruns), .dbg_max_busy(maxbusy));

    logic [5:0] ack;
    logic [26:1] sd_addr; logic [15:0] sd_din; logic [1:0] sd_be; logic sd_req, sd_rnw, sd_ready;
    logic [63:0] sd_dout;
    logic [25:1] arb_addr [6];
    assign arb_addr[0] = '0; assign arb_addr[1] = '0; assign arb_addr[2] = '0; assign arb_addr[3] = '0;
    assign arb_addr[4] = tm_addr; assign arb_addr[5] = sp_addr;
    nost_sdram_arb arb (
        .clk(clk), .rst(init), .req({sp_req, tm_req, 4'b0000}), .addr(arb_addr), .we(6'b0),
        .wdata(16'd0), .wbe(2'b11), .ack(ack), .rdata(mem_data),
        .sd_addr(sd_addr), .sd_din(sd_din), .sd_be(sd_be), .sd_req(sd_req), .sd_rnw(sd_rnw),
        .sd_dout(sd_dout), .sd_ready(sd_ready));
    assign tm_ack = ack[4];
    assign sp_ack = ack[5];

    wire [15:0] SDRAM_DQ; wire [12:0] SDRAM_A; wire [1:0] SDRAM_BA;
    wire SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS, SDRAM_CKE, SDRAM_CLK;
    sdram #(.CYCLES_PER_REFRESH(14'd760)) sdram (
        .init(init), .clk(clk), .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML),
        .SDRAM_DQMH(SDRAM_DQMH), .SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
        .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CKE(SDRAM_CKE), .SDRAM_CLK(SDRAM_CLK),
        .ch1_addr(sd_addr), .ch1_dout(sd_dout), .ch1_din(sd_din), .ch1_be(sd_be), .ch1_req(sd_req),
        .ch1_rnw(sd_rnw), .ch1_ready(sd_ready),
        .ch2_addr(26'd0), .ch2_dout(), .ch2_din(32'd0), .ch2_req(1'b0), .ch2_rnw(1'b1), .ch2_ready(),
        .ch3_addr(24'd0), .ch3_dout(), .ch3_din(16'd0), .ch3_req(1'b0), .ch3_rnw(1'b1), .ch3_ready());
    sdr_sdram_model #(.TCK_NS(10.198), .UNWRITTEN(16'h0000)) chip (
        .clk(SDRAM_CLK), .cke(SDRAM_CKE), .csn(SDRAM_nCS), .rasn(SDRAM_nRAS), .casn(SDRAM_nCAS),
        .wen(SDRAM_nWE), .ba(SDRAM_BA), .a(SDRAM_A), .dqml(SDRAM_DQML), .dqmh(SDRAM_DQMH), .dq(SDRAM_DQ));

    // ------------------------------------------------------------------ run
    int errors = 0, first_err = -1;
    logic [7:0] fpga_px [320*224*3];
    initial begin
        int fd;
        if (!$value$plusargs("FRAME=%s", frame)) frame = "local/frames/f03000";
        if (!$value$plusargs("SDRAM=%s", sdram_img)) sdram_img = "local/sim/sdram_be.bin";
        read_be16({frame, "/vram0.bin"}, vram0, 4096);
        read_be16({frame, "/vram1.bin"}, vram1, 4096);
        read_be16({frame, "/palette_next.bin"}, pal, 4096);
        read_be16({frame, "/sprbuf.bin"}, spr, 16384);
        read_be16({frame, "/tmregs.bin"}, tm, 6);
        read_be16({frame, "/vidregs.bin"}, vid, 8);
        read_be16({frame, "/vidbuf.bin"}, vbuf, 8);
        half = vbuf[2] == 16'h0001;
        tm0r = {tm[2], tm[1], tm[0]};
        tm1r = {tm[5], tm[4], tm[3]};
        gx = vid[0];
        gy = vid[1];
        fd = $fopen({frame, "/pixels.bin"}, "rb");
        void'($fread(mame_px, fd));
        $fclose(fd);
        chip.preload(sdram_img);
        repeat (4) @(posedge clk);
        init <= 0;
        // let the SDRAM controller initialise (startup ~12100 clocks) before the first render line
        repeat (13000) @(posedge clk);
        rst <= 0;
    end

    // capture the visible pixels of the first full frame after reset (rgb is 1 dot late; ohb/ovb
    // are aligned with rgb)
    always @(posedge clk) if (video.abort)
        $display("overrun at line %0d: tm busy %0d (st %0d) sp busy %0d (scan_done %0d fifo %0d dst %0d wbusy %0d scan %0d)",
            vc, video.tm_busy, video.tilemap.st, video.sp_busy, video.sprites.scan_done,
            video.sprites.f_cnt, video.sprites.dst, video.sprites.w_busy, video.sprites.scan);
    int x = 0, y = 0;
    bit capturing = 0, done = 0;
    always @(posedge clk) if (!rst && ls && vc == 8'd0) capturing <= 1;
    always @(posedge clk) if (!rst && ce_pix && !done) begin
        if (capturing && !ohb && !ovb) begin
            automatic int o = (y * 320 + x);
            fpga_px[o * 3 + 0] = rgb[23:16];
            fpga_px[o * 3 + 1] = rgb[15:8];
            fpga_px[o * 3 + 2] = rgb[7:0];
            if (flip180) o = ((223 - y) * 320 + (319 - x));
            if (rgb != {mame_px[o * 4 + 2], mame_px[o * 4 + 1], mame_px[o * 4 + 0]}) begin
                if (errors < 5) $display("pixel x=%0d y=%0d FPGA %06x MAME %02x%02x%02x", x, y, rgb,
                    mame_px[o * 4 + 2], mame_px[o * 4 + 1], mame_px[o * 4 + 0]);
                errors++;
            end
            x++;
            if (x == 320) begin
                x = 0; y++;
                if (y == 224) begin
                    done = 1;
                    if ($value$plusargs("DUMP=%s", dump)) begin
                        automatic int f = $fopen(dump, "wb");
                        for (int i = 0; i < 320 * 224 * 3; i++) $fwrite(f, "%c", fpga_px[i]);
                        $fclose(f);
                    end
                    if (errors == 0 && overruns == 0)
                        $display("PASS M3_RENDER %s: 320x224 pixel-exact vs MAME (render overruns 0, longest line render %0d clocks of 6384)", frame, maxbusy);
                    else
                        $display("FAIL M3_RENDER %s: %0d pixels differ, render overruns %0d (longest %0d)", frame, errors, overruns, maxbusy);
                    $finish;
                end
            end
        end
    end
    initial begin
        #400ms;
        $display("FAIL M3_RENDER: timeout (line %0d)", vc);
        $finish;
    end
endmodule
