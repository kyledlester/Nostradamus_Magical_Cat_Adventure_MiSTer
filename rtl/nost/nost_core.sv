// Nostradamus MiSTer core -- board top.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// docs/ARCHITECTURE.md. Everything runs on clk_sys (98.058240 MHz) with clock enables, except the
// sound board (clk_snd = clk_sys / 2):
//   nost_clocks        -> ce_pix 7.004 MHz, FX68K phi1/phi2 (16 MHz), 32 MHz time base
//   nost_video_timing  -> 456 x 256 raster, 320 x 224 visible; vblank (IRQ1, sprite copy) at line 224
//   nost_loader        -> ROM stream to SDRAM           nost_main  -> 68000 board
//   nost_video         -> 038 x2 tilemaps, sprites, mixer  nost_sound -> Z80, YM2610
//   nost_sdram_arb     -> SDRAM channel 1 (loader > 68000 ROM > ADPCM-A > Z80 ROM > tiles > sprites)
module nost_core #(
    parameter int SND_CE_NUM = 3125,     // sound board ce_8m = SND_CE_NUM / SND_CE_DEN of clk_snd
    parameter int SND_CE_DEN = 19152
) (
    input  logic        clk,
    input  logic        clk_snd,        // clk_sys / 2, sound board
    input  logic        init,
    input  logic        reset,
    input  logic        pause,

    input  logic        ioctl_download,
    input  logic [15:0] ioctl_index,
    input  logic        ioctl_wr,
    input  logic [26:0] ioctl_addr,
    input  logic [15:0] ioctl_dout,
    output logic        ioctl_wait,

    output logic [26:1] sd_addr,
    output logic [15:0] sd_din,
    output logic  [1:0] sd_be,
    output logic        sd_req,
    output logic        sd_rnw,
    input  logic [63:0] sd_dout,
    input  logic        sd_ready,

    input  logic [31:0] joy0,
    input  logic [31:0] joy1,
    input  logic        test_pattern,
    input  logic        dbg_overlay,
    input  logic        flip180,        // OSD Flip screen (180 degrees, independent of the game)

    output logic        ce_pix,
    output logic [23:0] rgb,
    output logic        hblank,
    output logic        vblank,
    output logic        hsync,
    output logic        vsync,
    output logic        vb_next,        // vertical blank of the line after the current output line
    output logic signed [15:0] snd
);
    // ------------------------------------------------------------------ clocks / raster
    logic tick32, phi1, phi2;
    nost_clocks clocks (
        .clk(clk), .rst(reset), .rst_video(init), .pause(pause),
        .ce_pix(ce_pix), .tick32(tick32), .phi1(phi1), .phi2(phi2));

    logic [8:0] hcount;
    logic [7:0] vcount;
    logic hb, vb, hs, vs, line_start;
    nost_video_timing timing (
        .clk(clk), .rst(init), .ce_pix(ce_pix),
        .hcount(hcount), .vcount(vcount), .hblank(hb), .vblank(vb), .hsync(hs), .vsync(vs),
        .line_start(line_start));

    // the vblank interrupt and sprite copy are part of emulated time: frozen while paused
    wire vblank_evt = line_start && vcount == 8'd224 && !pause;

    // ------------------------------------------------------------------ DIP switches (index 254)
    // byte 0 = SW1 (MAME DSW1 bits 15-8), byte 1 = SW2 (DSW2 bits 15-8); MAME port values
    logic [15:0] dsw = 16'hFFFF;
    always_ff @(posedge clk)
        if (ioctl_download && ioctl_wr && ioctl_index == 16'd254 && ioctl_addr[26:1] == 0)
            dsw <= ioctl_dout;

    // ------------------------------------------------------------------ inputs (MAME active low)
    // MiSTer joystick: 0 right, 1 left, 2 down, 3 up, 4-6 buttons 1-3, 7 start, 8 coin,
    // 9 service, 10 pause (CONF_STR J1).
    // MAME INPUT_PORTS_START( nost ): P1/P2 bit 0 up, 1 down, 2 left, 3 right, 4 button 1,
    // 5/6 "unknown" (buttons 2/3 in test mode only), 7 start, 8 coin; P2 bit 9 = SERVICE1.
    // P1 bit 11 is active high and must read 0 (MAME: "Must be LOW or startup freezes"; the boot
    // code at 0x184 waits for it). Other bits read 1.
    function automatic [15:0] player(input [31:0] j, input svc);
        player = ~{6'b000000, svc, j[8], j[7], j[6], j[5], j[4], j[0], j[1], j[2], j[3]};
    endfunction
    wire [15:0] p1 = player(joy0, 1'b0) & 16'hF7FF;
    wire [15:0] p2 = player(joy1, joy0[9] | joy1[9]);
    wire [15:0] dsw1 = {dsw[7:0], 8'h00};
    wire [15:0] dsw2 = {dsw[15:8], 8'h00};

    // ------------------------------------------------------------------ loader
    logic        ld_req, ld_ack;
    logic [25:1] ld_addr;
    logic [15:0] ld_wdata;
    logic        loaded;
    logic        zfix_we;
    logic [14:1] zfix_waddr;
    logic [15:0] zfix_wdata;
    nost_loader loader (
        .clk(clk), .rst(init),
        .ioctl_download(ioctl_download), .ioctl_index(ioctl_index), .ioctl_wr(ioctl_wr),
        .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout), .ioctl_wait(ioctl_wait),
        .mem_req(ld_req), .mem_addr(ld_addr), .mem_wdata(ld_wdata), .mem_ack(ld_ack),
        .zfix_we(zfix_we), .zfix_waddr(zfix_waddr), .zfix_wdata(zfix_wdata),
        .loaded(loaded));

    // ------------------------------------------------------------------ 68000 board
    logic        rom_req, rom_ack;
    logic [19:3] rom_line;
    logic [63:0] mem_rdata;
    logic  [7:0] latch, latch2;
    logic        latch_wr, soft_reset;
    logic [11:0] vram_addr, pal_addr;
    logic [15:0] vram0_q, vram1_q, pal_q;
    logic [10:0] sbuf_addr;
    logic [63:0] sbuf_q;
    logic [47:0] tm0_regs, tm1_regs;
    logic [15:0] spr_gx, spr_gy;
    logic        spr_busy;
    logic [23:0] dbg_pc;
    logic [15:0] dbg_irq1, dbg_frames, dbg_latch, dbg_wd, dbg_romm;
    nost_main main (
        .clk(clk), .reset(reset), .phi1(phi1), .phi2(phi2), .tick32(tick32),
        .rom_req(rom_req), .rom_line(rom_line), .rom_ack(rom_ack), .rom_data(mem_rdata),
        .vblank_evt(vblank_evt),
        .p1(p1), .p2(p2), .dsw1(dsw1), .dsw2(dsw2),
        .snd_latch(latch), .snd_latch_wr(latch_wr), .latch2(latch2), .soft_reset(soft_reset),
        .vram0_addr(vram_addr), .vram0_q(vram0_q), .vram1_addr(vram_addr), .vram1_q(vram1_q),
        .pal_addr(pal_addr), .pal_q(pal_q), .sbuf_addr(sbuf_addr), .sbuf_q(sbuf_q),
        .tm0_regs(tm0_regs), .tm1_regs(tm1_regs), .spr_gx(spr_gx), .spr_gy(spr_gy),
        .spr_copy_busy(spr_busy),
        .dbg_pc(dbg_pc), .dbg_irq1(dbg_irq1), .dbg_frames(dbg_frames), .dbg_latch_writes(dbg_latch),
        .dbg_wd_resets(dbg_wd), .dbg_rom_misses(dbg_romm));

    // ------------------------------------------------------------------ video
    logic        tm_req, tm_ack, sp_req, sp_ack;
    logic [25:1] tm_addr, sp_addr;
    logic [23:0] vid_rgb;
    logic        vhb, vvb, vhs, vvs;
    logic [15:0] dbg_overruns, dbg_maxbusy;
    nost_video video (
        .clk(clk), .rst(reset), .ce_pix(ce_pix), .hcount(hcount), .vcount(vcount), .line_start(line_start),
        .hblank_in(hb), .vblank_in(vb), .hsync_in(hs), .vsync_in(vs), .flip180(flip180),
        .tm0_regs(tm0_regs), .tm1_regs(tm1_regs), .spr_gx(spr_gx), .spr_gy(spr_gy),
        .vram_addr(vram_addr), .vram0_q(vram0_q), .vram1_q(vram1_q),
        .sbuf_addr(sbuf_addr), .sbuf_q(sbuf_q), .pal_addr(pal_addr), .pal_q(pal_q),
        .tm_req(tm_req), .tm_addr(tm_addr), .tm_ack(tm_ack),
        .sp_req(sp_req), .sp_addr(sp_addr), .sp_ack(sp_ack), .mem_data(mem_rdata),
        .rgb(vid_rgb), .hblank(vhb), .vblank(vvb), .hsync(vhs), .vsync(vvs),
        .dbg_overruns(dbg_overruns), .dbg_max_busy(dbg_maxbusy));

    // ------------------------------------------------------------------ sound
    logic        zrom_req, zrom_ack, arom_req, arom_ack;
    logic [17:3] zrom_line;
    logic [19:3] arom_line;
    logic [15:0] dbg_lat_rd, dbg_ym, dbg_nmi, dbg_zmiss;
`ifdef NOST_SIM_NO_SOUND
    // simulation-only: video/CPU benches without the Z80 board. Latch 2 echoes each command ~10 us
    // after it is written, as the Z80 program does once running (boot handshake not modelled).
    logic [9:0] echo_cnt = '0;
    logic [7:0] echo_v = 8'h00;
    always_ff @(posedge clk) begin
        if (latch_wr) begin echo_cnt <= 10'd1000; echo_v <= latch; end
        else if (echo_cnt != 0) begin
            echo_cnt <= echo_cnt - 10'd1;
            if (echo_cnt == 10'd1) latch2 <= echo_v;
        end
    end
    assign snd = '0; assign zrom_req = 1'b0; assign arom_req = 1'b0;
    assign zrom_line = '0; assign arom_line = '0;
    assign {dbg_lat_rd, dbg_ym, dbg_nmi, dbg_zmiss} = '0;
`else
    nost_sound #(.CE_NUM(SND_CE_NUM), .CE_DEN(SND_CE_DEN)) sound (
        .clk(clk), .clk_snd(clk_snd), .reset(reset || soft_reset), .pause(pause),
        .latch(latch), .latch_wr(latch_wr), .latch2(latch2),
        .zfix_we(zfix_we), .zfix_waddr(zfix_waddr), .zfix_wdata(zfix_wdata),
        .zrom_req(zrom_req), .zrom_line(zrom_line), .zrom_ack(zrom_ack), .zrom_data(mem_rdata),
        .arom_req(arom_req), .arom_line(arom_line), .arom_ack(arom_ack), .arom_data(mem_rdata),
        .snd(snd),
        .dbg_latch_reads(dbg_lat_rd), .dbg_ym_writes(dbg_ym), .dbg_nmis(dbg_nmi), .dbg_zmisses(dbg_zmiss));
`endif

    // ------------------------------------------------------------------ SDRAM
    logic [5:0]  arb_ack;
    logic [25:1] arb_addr [6];
    assign arb_addr[0] = ld_addr;
    assign arb_addr[1] = 25'h000000 + {5'd0, rom_line, 2'b00};       // 68000 ROM at SDRAM 0x0000000
    assign arb_addr[2] = 25'h100000 + {5'd0, arom_line, 2'b00};      // ADPCM-A at SDRAM 0x0200000
    assign arb_addr[3] = 25'h080000 + {7'd0, zrom_line, 2'b00};      // Z80 ROM at SDRAM 0x0100000
    assign arb_addr[4] = tm_addr;
    assign arb_addr[5] = sp_addr;
    nost_sdram_arb arb (
        .clk(clk), .rst(init),
        .req({sp_req, tm_req, zrom_req, arom_req, rom_req, ld_req}), .addr(arb_addr), .we(6'b000001),
        .wdata(ld_wdata), .wbe(2'b11), .ack(arb_ack), .rdata(mem_rdata),
        .sd_addr(sd_addr), .sd_din(sd_din), .sd_be(sd_be), .sd_req(sd_req), .sd_rnw(sd_rnw),
        .sd_dout(sd_dout), .sd_ready(sd_ready));
    assign ld_ack   = arb_ack[0];
    assign rom_ack  = arb_ack[1];
    assign arom_ack = arb_ack[2];
    assign zrom_ack = arb_ack[3];
    assign tm_ack   = arb_ack[4];
    assign sp_ack   = arb_ack[5];

    // ------------------------------------------------------------------ output (test pattern / debug overlay)
    logic [23:0] ovl_rgb;
    nost_overlay overlay (
        .clk(clk), .ce_pix(ce_pix), .hcount(hcount), .vcount(vcount), .enable(dbg_overlay),
        .values({ {8'h00, dbg_pc}, {dbg_frames, dbg_irq1}, {dbg_latch, dbg_lat_rd},
                  {dbg_ym, dbg_nmi}, {dbg_romm, dbg_zmiss}, {dbg_overruns, dbg_wd},
                  {dbg_maxbusy, 7'd0, loaded, latch2} }),
        .rgb_in(vid_rgb), .rgb_out(ovl_rgb));

    always_ff @(posedge clk) if (ce_pix) begin
        if (test_pattern) begin
            // 8 colour bars across the active width with a white border, raster timing unchanged
            if (hcount == 9'd1 || hcount == 9'd320 || vcount == 8'd0 || vcount == 8'd223)
                rgb <= 24'hFFFFFF;
            else begin
                logic [2:0] bar;
                bar = 3'((hcount - 9'd1) / 9'd40);
                rgb <= {{8{bar[2]}}, {8{bar[1]}}, {8{bar[0]}}};
            end
        end else
            rgb <= ovl_rgb;
        {hblank, vblank, hsync, vsync} <= {vhb, vvb, vhs, vvs};
        // for CRT Adjust: the output stream lags the raster counters by a few dots, so vcount is
        // still the output line when its active area ends (where nost_crt_adjust samples this)
        vb_next <= (vcount + 8'd1) >= 8'd224;
    end
endmodule
