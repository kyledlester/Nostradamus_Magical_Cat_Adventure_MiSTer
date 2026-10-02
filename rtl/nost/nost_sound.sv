// Nostradamus MiSTer core -- Z80 sound board.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// MAME 0.289 mcatadv_state::nost_sound_map / nost_sound_io_map (docs/AUDIO.md):
//   Z80 (T80s) at 4 MHz: 0000-7FFF ROM, 8000-BFFF ROM bank (16 KB pages of the 256 KB ROM, bank
//   register = port 40, MAME's initial page 1, not changed by a reset), C000-DFFF RAM.
//   I/O (A7-A0): 00-03 W YM2610, 04-07 R YM2610, 40 W bank, 80 R sound latch / W latch 2.
//   NMI = sound latch pending (set by a 68000 write, cleared by the Z80 read: MAME generic_latch_8
//   data_pending -> INPUT_LINE_NMI); INT = YM2610 IRQ (the program runs IM 1 with a bare RETI).
//   YM2610 (jt10) at 8 MHz; ADPCM-A samples from the 1 MB region; no ADPCM-B region (reads 0).
// Mono mix as MAME's nost routes: SSG (ymfm: (a+b+c) * 2/3, channel amplitudes 0..16382) x 0.6 +
// FM/ADPCM left x 0.5 + right x 0.5, saturated to 16 bits.
//
// Clocking: the board runs on clk_snd = clk_sys / 2 (same PLL, phase aligned). ce_8m is an
// exact-average fractional 8 MHz enable of clk_snd (8,000,000 / 49,029,120); ce_4m = every other
// ce_8m. The Z80 program ROM and the ADPCM-A ROM are in SDRAM (clk_sys) behind small caches in this
// domain with a level handshake per line fill; a Z80 cache miss holds WAIT_n (MAME has no waits).
module nost_sound #(
    parameter int CE_NUM = 3125,          // ce_8m = CE_NUM / CE_DEN of clk_snd
    parameter int CE_DEN = 19152
) (
    input  logic        clk,            // clk_sys: SDRAM ports, latch from the 68000, audio output
    input  logic        clk_snd,        // sound board clock
    input  logic        reset,          // clk_sys domain (board reset or watchdog)
    input  logic        pause,          // clk_sys domain

    input  logic  [7:0] latch,          // 68000 -> Z80
    input  logic        latch_wr,       // one clk_sys pulse per 68000 write
    output logic  [7:0] latch2,         // Z80 -> 68000 (clk_sys domain)

    // Z80 ROM 0000-7FFF copy in block RAM, written by the loader (clk_sys): word k = bytes 2k, 2k+1
    input  logic        zfix_we,
    input  logic [14:1] zfix_waddr,
    input  logic [15:0] zfix_wdata,      // {byte 2k+1, byte 2k}

    // Z80 ROM line fill (SDRAM, 8 bytes, byte k = bits 8k+7..8k)
    output logic        zrom_req,
    output logic [17:3] zrom_line,
    input  logic        zrom_ack,
    input  logic [63:0] zrom_data,
    // ADPCM-A line fill
    output logic        arom_req,
    output logic [19:3] arom_line,
    input  logic        arom_ack,
    input  logic [63:0] arom_data,

    output logic signed [15:0] snd,

    output logic [15:0] dbg_latch_reads,
    output logic [15:0] dbg_ym_writes,
    output logic [15:0] dbg_nmis,
    output logic [15:0] dbg_zmisses
);
    // ------------------------------------------------------------------ clk_snd domain basics
    // Reset is synchronised and lasts at least 4096 clk_snd (> 600 ce_8m) counted from its
    // assertion so the jt10 pipelines take their reset values (enables keep running in reset).
    logic [2:0]  rst_s = 3'b111;
    logic [1:0]  pause_s = 2'b00;
    logic [11:0] rst_cnt = '1;
    logic        rst = 1'b1;
    always_ff @(posedge clk_snd) begin
        rst_s   <= {rst_s[1:0], reset};
        pause_s <= {pause_s[0], pause};
        if (rst_s[1] && !rst_s[2]) rst_cnt <= '1;
        else if (rst_cnt != 0) rst_cnt <= rst_cnt - 12'd1;
        rst <= rst_s[1] || rst_cnt != 0;
    end

    logic [15:0] acc8 = '0;
    logic        ce_8m, ce_4m;
    logic        half = 1'b0;
    always_ff @(posedge clk_snd) begin
        ce_8m <= 1'b0;
        ce_4m <= 1'b0;
        if (!pause_s[1] || rst) begin
            if (acc8 + 16'(CE_NUM) >= 16'(CE_DEN)) begin
                acc8  <= acc8 + 16'(CE_NUM) - 16'(CE_DEN);
                ce_8m <= 1'b1;
                half  <= !half;
                ce_4m <= half;
            end else
                acc8 <= acc8 + 16'(CE_NUM);
        end
    end

    // ------------------------------------------------------------------ latches
    // 68000 write: toggle in clk_sys, detected in clk_snd (value is stable by then: it is written
    // in the same clk_sys edge as the toggle and sampled two clk_snd later).
    logic       wr_tog = 1'b0;
    logic [7:0] latch_q;
    always_ff @(posedge clk) if (latch_wr) begin wr_tog <= !wr_tog; latch_q <= latch; end
    logic [2:0] tog_s = '0;
    logic       pending;
    logic [7:0] latch_s;
    logic       lat_rd;                 // Z80 read of port 80 (one clk_snd)
    always_ff @(posedge clk_snd) begin
        tog_s <= {tog_s[1:0], wr_tog};
        if (rst) pending <= 1'b0;
        else begin
            if (lat_rd) pending <= 1'b0;
            if (tog_s[2] != tog_s[1]) begin
                pending <= 1'b1;
                latch_s <= latch_q;
            end
        end
    end
    logic [7:0] latch2_s = 8'h00;
    always_ff @(posedge clk) latch2 <= latch2_s;

    // ------------------------------------------------------------------ Z80
    logic        mreq_n, iorq_n, rd_n, wr_n, m1_n, rfsh_n;
    logic [15:0] A;
    logic  [7:0] cpu_di, cpu_do;
    logic        irq_n, wait_n;

    T80s #(.Mode(0), .T2Write(1), .IOWait(1)) z80 (
        .RESET_n(!rst), .CLK(clk_snd), .CEN(ce_4m), .WAIT_n(wait_n), .INT_n(irq_n), .NMI_n(!pending),
        .BUSRQ_n(1'b1), .M1_n(m1_n), .MREQ_n(mreq_n), .IORQ_n(iorq_n), .RD_n(rd_n), .WR_n(wr_n),
        .RFSH_n(rfsh_n), .HALT_n(), .BUSAK_n(), .OUT0(1'b0), .A(A), .DI(cpu_di), .DO(cpu_do));

    wire mem     = !mreq_n && rfsh_n;
    wire io      = !iorq_n && m1_n;
    wire sel_fix = mem && !A[15];                     // 0000-7FFF: block RAM, no wait states
    wire sel_rom = mem && A[15:14] == 2'b10;          // 8000-BFFF bank window: SDRAM cache
    wire sel_ram = mem && A[15:13] == 3'b110;
    wire sel_ymw = io && A[7:2] == 6'b000000;       // 00-03
    wire sel_ymr = io && A[7:2] == 6'b000001;       // 04-07
    wire sel_bnk = io && A[7:0] == 8'h40;
    wire sel_lat = io && A[7:0] == 8'h80;

    // one strobe per write / read cycle
    logic wr_n_d, rd_n_d;
    always_ff @(posedge clk_snd) begin wr_n_d <= wr_n; rd_n_d <= rd_n; end
    wire wr_edge = wr_n_d && !wr_n;
    assign lat_rd = sel_lat && rd_n_d && !rd_n;

    logic [3:0] bank = 4'd1;            // MAME machine_start: set_entry(1); kept across resets
    always_ff @(posedge clk_snd) begin
        if (sel_bnk && wr_edge) bank <= cpu_do[3:0];
        if (sel_lat && wr_edge) latch2_s <= cpu_do;
    end

    logic [7:0] ram_q;
    nost_dpram #(.AW(13), .DW(8)) ram (
        .clk(clk_snd), .a_addr(A[12:0]), .a_we(sel_ram && wr_edge), .a_din(cpu_do), .a_dout(ram_q),
        .b_addr(13'd0), .b_dout());

    // ------------------------------------------------------------------ Z80 ROM 0000-7FFF
    // The program code lives here; in block RAM it runs without wait states, like the board's ROM.
    logic [7:0] fix_lo_q, fix_hi_q;
    nost_dcram #(.AW(14), .DW(8)
`ifdef NOST_SIM_ZFIX
        , .INIT("local/sim/zfix_lo.hex")
`endif
    ) zfix_lo (.wclk(clk), .w_addr(zfix_waddr), .we(zfix_we), .din(zfix_wdata[7:0]),
               .rclk(clk_snd), .r_addr(A[14:1]), .dout(fix_lo_q));
    nost_dcram #(.AW(14), .DW(8)
`ifdef NOST_SIM_ZFIX
        , .INIT("local/sim/zfix_hi.hex")
`endif
    ) zfix_hi (.wclk(clk), .w_addr(zfix_waddr), .we(zfix_we), .din(zfix_wdata[15:8]),
               .rclk(clk_snd), .r_addr(A[14:1]), .dout(fix_hi_q));
    wire [7:0] fix_q = A[0] ? fix_hi_q : fix_lo_q;

    // ------------------------------------------------------------------ Z80 ROM cache (bank window)
    // direct-mapped, 512 lines of 8 bytes; ROM address = A (0000-7FFF) or bank * 0x4000 + A[13:0].
    // Next-line prefetch: while the Z80 reads a line that hits, the following line is fetched if it
    // is not present, so sequential code and data (e.g. the boot-time ROM checksum) do not stall the
    // Z80 (the board's ROM has no wait states; MAME neither).
    wire [17:0] zaddr = A[15] ? {bank, A[13:0]} : {3'b000, A[14:0]};
    logic [2:0]  zrq_s;
    logic        zack;
    logic [2:0]  zack_s;
    logic [63:0] zfill_buf;
    logic [8:0]  zclr;                  // tag clear after reset (ROM may have been re-downloaded)
    logic        zclearing;
    logic [17:0] zaddr_d1, zaddr_d2;
    logic [7:0]  ztag_q;                // {valid, tag[17:12] (6 bits), unused}
    logic [63:0] zline_q;
    logic        zfill, zfill_done;
    logic [63:0] zfill_data;
    logic [17:3] zfill_line;
    logic [1:0]  zsettle;
    logic [11:3] zsettle_idx;
    logic        zfill_rq;
    logic [7:0]  ptag_q;
    wire  [17:0] znext = zaddr + 18'd8;
    nost_sdpram #(.AW(9), .DW(8)) ztags (
        .clk(clk_snd), .w_addr(zclearing ? zclr : zfill_line[11:3]), .we(zfill_done || zclearing),
        .din(zclearing ? 8'h00 : {1'b1, zfill_line[17:12], 1'b0}),
        .r_addr(zaddr[11:3]), .dout(ztag_q));
    nost_sdpram #(.AW(9), .DW(8)) ptags (             // tag copy, looked up for the next line
        .clk(clk_snd), .w_addr(zclearing ? zclr : zfill_line[11:3]), .we(zfill_done || zclearing),
        .din(zclearing ? 8'h00 : {1'b1, zfill_line[17:12], 1'b0}),
        .r_addr(znext[11:3]), .dout(ptag_q));
    nost_sdpram #(.AW(9), .DW(64)) zdata (
        .clk(clk_snd), .w_addr(zfill_line[11:3]), .we(zfill_done), .din(zfill_data),
        .r_addr(zaddr[11:3]), .dout(zline_q));
    // RAM outputs belong to zaddr once it has been stable for two clocks
    always_ff @(posedge clk_snd) begin zaddr_d1 <= zaddr; zaddr_d2 <= zaddr_d1; end
    wire zstable = zaddr == zaddr_d1 && zaddr_d1 == zaddr_d2;
    wire zmatch = ztag_q[7] && ztag_q[6:1] == zaddr[17:12];
    wire pmatch = ptag_q[7] && ptag_q[6:1] == znext[17:12];
    wire zbusy_line = (zfill && zfill_line[11:3] == zaddr[11:3]) || (zsettle != 0 && zsettle_idx == zaddr[11:3]);
    wire zhit   = zstable && zmatch && !zbusy_line && !zclearing;
    wire [7:0] rom_q = zline_q[zaddr[2:0]*8 +: 8];
    assign wait_n = !(sel_rom && !rd_n && !zhit);

    always_ff @(posedge clk_snd) begin
        zfill_done <= 1'b0;
        if (rst) begin
            zfill    <= 1'b0;
            zfill_rq <= 1'b0;
            zsettle  <= 2'd2;
            dbg_zmisses <= '0;
            zclearing <= 1'b1;
            zclr     <= '0;
        end else if (zclearing) begin
            zclr <= zclr + 9'd1;
            if (&zclr) zclearing <= 1'b0;
        end else begin
            if (zsettle != 0) zsettle <= zsettle - 2'd1;
            if (zfill) begin
                if (zfill_rq && zack_s[2]) begin            // data captured in clk_sys, stable
                    zfill_rq   <= 1'b0;
                    zfill_data <= zfill_buf;
                    zfill_done <= 1'b1;
                end else if (!zfill_rq && !zack_s[2]) begin  // handshake closed
                    zfill       <= 1'b0;
                    zsettle     <= 2'd2;
                    zsettle_idx <= zfill_line[11:3];
                end
            end else if (zsettle == 0 && sel_rom && !rd_n && zstable) begin
                if (!zmatch) begin                           // demand miss: the Z80 waits
                    zfill      <= 1'b1;
                    zfill_rq   <= 1'b1;
                    zfill_line <= zaddr[17:3];
                    dbg_zmisses <= dbg_zmisses + 16'd1;
                end else if (!pmatch) begin                  // prefetch the next line
                    zfill      <= 1'b1;
                    zfill_rq   <= 1'b1;
                    zfill_line <= znext[17:3];
                end
            end
        end
    end
    // clk_sys side of the Z80 line fill
    always_ff @(posedge clk_snd) zack_s <= {zack_s[1:0], zack};
    always_ff @(posedge clk) begin
        zrq_s <= {zrq_s[1:0], zfill_rq};
        if (reset) begin
            zrom_req <= 1'b0;
            zack     <= 1'b0;
        end else if (zrq_s[2] && !zack) begin
            if (!zrom_req) begin
                zrom_req  <= 1'b1;
                zrom_line <= zfill_line;
            end else if (zrom_ack) begin
                zrom_req  <= 1'b0;
                zfill_buf <= zrom_data;
                zack      <= 1'b1;
            end
        end else if (!zrq_s[2])
            zack <= 1'b0;
    end

    // ------------------------------------------------------------------ YM2610
    logic [7:0]  ym_dout;
    logic [19:0] adpcma_addr;
    logic  [4:0] adpcma_bank;
    logic        adpcma_roe_n;
    logic  [7:0] adpcma_data;
    logic  [7:0] psg_a, psg_b, psg_c;
    logic signed [15:0] fm_l, fm_r;

    jt10 ym (
        .rst(rst), .clk(clk_snd), .cen(ce_8m), .din(cpu_do), .addr(A[1:0]),
        .cs_n(!((sel_ymw && wr_edge) || sel_ymr)), .wr_n(!(sel_ymw && wr_edge)),
        .dout(ym_dout), .irq_n(irq_n),
        .adpcma_addr(adpcma_addr), .adpcma_bank(adpcma_bank), .adpcma_roe_n(adpcma_roe_n),
        .adpcma_data(adpcma_data),
        .adpcmb_addr(), .adpcmb_roe_n(), .adpcmb_data(8'd0),
        .psg_A(psg_a), .psg_B(psg_b), .psg_C(psg_c), .fm_left(fm_l), .fm_right(fm_r),
        .psg_snd(), .snd_right(), .snd_left(), .snd_sample(), .ch_enable(6'h3F));

    // ADPCM-A ROM: direct-mapped 32 lines of 8 bytes (registers); the YM2610 address pins see a
    // 1 MB ROM (A19-A0; the bank pins are not wired to the ROM). A miss is filled from SDRAM within
    // about 0.5 us, well inside one ADPCM-A sample slot (the chip latches the byte later).
    logic [63:0] aline [32];
    logic [12:0] atag  [32];            // {valid, addr[19:8]}
    logic        afill, afill_rq;
    logic [19:3] afill_line;
    wire  [4:0]  aidx = adpcma_addr[7:3];
    wire         amatch = atag[aidx][12] && atag[aidx][11:0] == adpcma_addr[19:8];
    assign adpcma_data = amatch ? aline[aidx][adpcma_addr[2:0]*8 +: 8] : 8'h00;

    logic [2:0]  aack_s;
    logic        aack;
    logic [63:0] afill_buf;
    always_ff @(posedge clk_snd) begin
        aack_s <= {aack_s[1:0], aack};
        if (rst) begin
            afill <= 1'b0;
            afill_rq <= 1'b0;
            for (int i = 0; i < 32; i++) atag[i] <= '0;
        end else if (afill) begin
            if (afill_rq && aack_s[2]) begin
                afill_rq <= 1'b0;
                aline[afill_line[7:3]] <= afill_buf;
                atag[afill_line[7:3]]  <= {1'b1, afill_line[19:8]};
            end else if (!afill_rq && !aack_s[2])
                afill <= 1'b0;
        end else if (!adpcma_roe_n && !amatch) begin
            afill      <= 1'b1;
            afill_rq   <= 1'b1;
            afill_line <= adpcma_addr[19:3];
        end
    end
    logic [2:0] arq_s;
    always_ff @(posedge clk) begin
        arq_s <= {arq_s[1:0], afill_rq};
        if (reset) begin
            arom_req <= 1'b0;
            aack     <= 1'b0;
        end else if (arq_s[2] && !aack) begin
            if (!arom_req) begin
                arom_req  <= 1'b1;
                arom_line <= afill_line;
            end else if (arom_ack) begin
                arom_req  <= 1'b0;
                afill_buf <= arom_data;
                aack      <= 1'b1;
            end
        end else if (!arq_s[2])
            aack <= 1'b0;
    end

    // ------------------------------------------------------------------ CPU read mux
    always_comb begin
        cpu_di = 8'h00;                                 // MAME unmapped read value
        if (sel_fix)      cpu_di = fix_q;
        else if (sel_rom) cpu_di = rom_q;
        else if (sel_ram) cpu_di = ram_q;
        else if (sel_ymr) cpu_di = ym_dout;
        else if (sel_lat) cpu_di = latch_s;
        else if (!iorq_n && !m1_n) cpu_di = 8'hFF;      // IM 1 acknowledge (bus floats high)
    end

    // ------------------------------------------------------------------ mix (clk_snd), output (clk)
    // ymfm SSG amplitude ~ jt49 8-bit level * 64.25; MAME: ssg * 2/3 * 0.6 + (l + r) * 0.5
    //   = (A + B + C) * 25.7 + (L + R) / 2   -> integer: ((A+B+C) * 1645 + (L+R) * 32) >> 6
    logic signed [15:0] snd_s;
    always_ff @(posedge clk) snd <= snd_s;
    always_ff @(posedge clk_snd) begin
        logic signed [24:0] acc;
        acc = ($signed({15'd0, psg_a} + {15'd0, psg_b} + {15'd0, psg_c}) * 25'sd1645 +
               ($signed(fm_l) + $signed(fm_r)) * 25'sd32) >>> 6;
        if (acc > 25'sd32767) snd_s <= 16'sd32767;
        else if (acc < -25'sd32768) snd_s <= -16'sd32768;
        else snd_s <= acc[15:0];
    end

    // ------------------------------------------------------------------ debug counters
    logic pend_d;
    always_ff @(posedge clk_snd) begin
        pend_d <= pending;
        if (rst) begin
            dbg_latch_reads <= '0; dbg_ym_writes <= '0; dbg_nmis <= '0;
        end else begin
            if (lat_rd) dbg_latch_reads <= dbg_latch_reads + 16'd1;
            if (sel_ymw && wr_edge) dbg_ym_writes <= dbg_ym_writes + 16'd1;
            if (pending && !pend_d) dbg_nmis <= dbg_nmis + 16'd1;
        end
    end
endmodule
