// M5: Z80 sound board (nost_sound: T80, jt10 YM2610, ROM/ADPCM caches) against MAME.
// The 68000's sound-latch writes are replayed at MAME's times (scripts/mame/sound_trace.lua ->
// local/sound_trace.txt "M" lines); every Z80 I/O write (YM2610 ports 00-03, bank 40, latch 2 80)
// is compared in order with MAME's ("Z ... W" lines): port and data must match, and the time
// difference is reported. Status reads are not compared (their count depends on busy timing).
// Bench time 0 = MAME's watchdog reset at 3.0 s, which resets the Z80 and the YM2610 (the trace's
// earlier part is the cold-boot run that the reset discards).
// Simulation clock: 16 MHz (1 clk = 62.5 ns), ce_8m every 2nd and ce_4m every 4th clock - the board
// only sees clock enables, so this keeps the production 8 MHz / 4 MHz rates at 1/3 of the cost.
// clk_sys = clk_snd here; Z80 ROM and ADPCM-A lines are served from local/sim/*.hex with
// +ROMLAT=<clocks> latency (default 6 = 375 ns, about the production SDRAM path).
// Audio: build/sim/sound.raw (signed 16-bit mono, 1 MHz).
// Plusargs: +MS=<milliseconds to run after the reset> (default 400), +N=<writes, 0 = all>,
// +STRACE=<file>, +SOUNDRAW=<file>, +SIMDIR=<dir with soundcpu/adpcma/zfix hex> (default local/sim).
// +MCAT: Magical Cat Adventure (mcatadv map: YM2610 at E000-E003 and bank at F000 are memory
// writes, compared with MAME's "Z t W <4-digit address>" lines). Its Z80 idles in a loop that
// rewrites the bank register and latch 2 with unchanged values; for mcat a bank / latch 2 write is
// compared only when its value differs from the previous write to that address (on both sides).
`timescale 1ns/1ps
module tb_sound;
    logic clk = 0;
    always #31.25 clk = ~clk;
    logic clk_sys = 0;
`ifdef TWOCLK
    always #5.099 clk_sys = ~clk_sys;     // experiment: production-like separate clk_sys
`else
    always @* clk_sys = clk;
`endif
    logic reset = 1;

    logic [7:0] latch = 8'h00, latch2;
    logic latch_wr = 0;
    logic zrom_req, arom_req, zrom_ack = 0, arom_ack = 0;
    logic [17:3] zrom_line;
    logic [19:3] arom_line;
    logic [63:0] zrom_data, arom_data;
    logic signed [15:0] snd;
    logic [15:0] c_lat, c_ym, c_nmi, c_zmiss;

    logic mcat = 0;
    initial if ($test$plusargs("MCAT")) mcat = 1;
    nost_sound #(.CE_NUM(1), .CE_DEN(2)) dut (
        .clk(clk_sys), .clk_snd(clk), .reset(reset), .pause(1'b0), .mcat(mcat),
        .latch(latch), .latch_wr(latch_wr), .latch2(latch2),
        .zfix_we(1'b0), .zfix_waddr('0), .zfix_wdata('0),
        .zrom_req(zrom_req), .zrom_line(zrom_line), .zrom_ack(zrom_ack), .zrom_data(zrom_data),
        .arom_req(arom_req), .arom_line(arom_line), .arom_ack(arom_ack), .arom_data(arom_data),
        .snd(snd), .dbg_latch_reads(c_lat), .dbg_ym_writes(c_ym), .dbg_nmis(c_nmi), .dbg_zmisses(c_zmiss));

    // ROM line responders
    logic [7:0] zrom [0:262143];
    logic [7:0] arom [0:1048575];
    string simdir;
    initial begin
        if (!$value$plusargs("SIMDIR=%s", simdir)) simdir = "local/sim";
        $readmemh({simdir, "/soundcpu.hex"}, zrom);
        $readmemh({simdir, "/adpcma.hex"}, arom);
        if (simdir != "local/sim") begin              // block-RAM copy of 0000-7FFF (else INIT)
            #1;
            $readmemh({simdir, "/zfix_lo.hex"}, dut.zfix_lo.mem);
            $readmemh({simdir, "/zfix_hi.hex"}, dut.zfix_hi.mem);
        end
        if ($test$plusargs("ZPATCH")) begin   // scripts/mame/bootpatch.lua Z80 part: skip ROM checksum
            zrom[18'h5F9] = 8'hC3; zrom[18'h5FA] = 8'h04; zrom[18'h5FB] = 8'h06;
            dut.zfix_hi.mem[14'h2FC] = 8'hC3; dut.zfix_lo.mem[14'h2FD] = 8'h04; dut.zfix_hi.mem[14'h2FD] = 8'h06;
        end
    end
    int romlat = 6, zc = 0, ac = 0, alate = 0;
    initial void'($value$plusargs("ROMLAT=%d", romlat));
    always_ff @(posedge clk) begin
        zrom_ack <= 1'b0;
        arom_ack <= 1'b0;
        if (zrom_req && !zrom_ack) begin
            if (zc >= romlat) begin
                for (int i = 0; i < 8; i++) zrom_data[i*8 +: 8] <= zrom[{zrom_line, 3'(i)}];
                zrom_ack <= 1'b1; zc <= 0;
            end else zc <= zc + 1;
        end
        if (arom_req && !arom_ack) begin
            if (ac >= romlat) begin
                for (int i = 0; i < 8; i++) arom_data[i*8 +: 8] <= arom[{arom_line, 3'(i)}];
                arom_ack <= 1'b1; ac <= 0;
            end else ac <= ac + 1;
        end
    end

    // mcat: drop bank (F000) / latch 2 (80) writes that repeat the previous value (side 0 = MAME,
    // 1 = FPGA)
    int last_bank [2] = '{-1, -1};
    int last_l2 [2] = '{-1, -1};
    function automatic bit keep_write(int a, int v, int side);
        if (!$test$plusargs("MCAT")) return 1;
        if (a == 'hF000) begin if (v == last_bank[side]) return 0; last_bank[side] = v; end
        if (a == 'h80)   begin if (v == last_l2[side])   return 0; last_l2[side] = v; end
        return 1;
    endfunction

    // MAME trace (times relative to the 3.0 s watchdog reset)
    real   lat_t [$]; int lat_v [$];
    real   w_t [$]; int w_a [$]; int w_d [$];
    int    run_ms = 400, max_n = 0;
    real   shift_from;
    int    afd;
    string strace, sraw;
    initial begin
        int fd, r; string kind, rw; real tt; int a, v; real t0;
        void'($value$plusargs("MS=%d", run_ms));
        void'($value$plusargs("N=%d", max_n));
        if (!$value$plusargs("STRACE=%s", strace)) strace = "local/sound_trace.txt";
        fd = $fopen(strace, "r");
        if (fd == 0) begin $display("FAIL M5_SOUND: no %s", strace); $finish; end
        t0 = -1;
        while (!$feof(fd)) begin
            r = $fscanf(fd, "%s", kind);
            if (r != 1) break;
            if (kind == "X") begin r = $fscanf(fd, "%f %s\n", tt, rw); if (t0 < 0) t0 = tt; end
            else if (kind == "M") begin r = $fscanf(fd, "%f %h\n", tt, v);
                if (t0 >= 0) begin lat_t.push_back(tt - t0); lat_v.push_back(v); end end
            else begin
                r = $fscanf(fd, "%f %s %h %h\n", tt, rw, a, v);
                if (t0 >= 0 && rw == "W" && keep_write(a, v, 0)) begin w_t.push_back(tt - t0); w_a.push_back(a); w_d.push_back(v); end
            end
        end
        $fclose(fd);
        // +SHIFTFROM=<us>: keep only the latch writes from that MAME time (relative to the reset) on,
        // moved to start 200 ms after the reset (skips the boot handshake and the idle wait; the
        // write-by-write comparison is then meaningless, the audio is compared with audiocheck.py)
        if ($value$plusargs("SHIFTFROM=%f", shift_from)) begin
            real nt [$]; int nv [$];
            real at = 200000.0;
            void'($value$plusargs("SHIFTAT=%f", at));
            // +PRE01: the boot handshake command first (the Z80 program answers it and checksums its
            // ROM banks, ~3 s), as the 68000 does at boot
            if ($test$plusargs("PRE01")) begin nt.push_back(100000.0); nv.push_back(8'h01); end
            // +PRE=<hex>[,<hex>]: up to two commands first (100 / 200 ms), e.g. Magical Cat's boot
            // (EF) and coin (1F) commands before its game-start command
            begin
                string pre; int p1, p2, n;
                if ($value$plusargs("PRE=%s", pre)) begin
                    n = $sscanf(pre, "%h,%h", p1, p2);
                    if (n >= 1) begin nt.push_back(100000.0); nv.push_back(p1); end
                    if (n >= 2) begin nt.push_back(200000.0); nv.push_back(p2); end
                end
            end
            foreach (lat_t[i]) if (lat_t[i] >= shift_from) begin nt.push_back(lat_t[i] - shift_from + at); nv.push_back(lat_v[i]); end
            lat_t = nt; lat_v = nv;
            w_t.delete(); w_a.delete(); w_d.delete();
            $display("shifted: %0d latch writes (MAME t >= %.0f us) replayed", lat_t.size(), shift_from);
        end
        if (!$value$plusargs("SOUNDRAW=%s", sraw)) sraw = "build/sim/sound.raw";
        afd = $fopen(sraw, "wb");
        $display("trace: reset at %.0f us; %0d latch writes, %0d Z80 writes after it", t0, lat_t.size(), w_t.size());
        repeat (8) @(posedge clk);
        reset <= 0;
    end

    // time in microseconds since reset release: 16 clocks per us
    longint clks = 0;
    always @(posedge clk) if (!reset) clks++;
    real t_us;
    always @* t_us = clks / 16.0;

    int li = 0;
    always @(posedge clk) begin
        latch_wr <= 1'b0;
        if (!reset && li < lat_t.size() && lat_t[li] <= t_us) begin
            latch <= lat_v[li]; latch_wr <= 1'b1; li++;
        end
    end

    // compare Z80 I/O writes
    int wi = 0, errors = 0; real maxdt = 0;
    logic wr_n_d = 1;
    always @(posedge clk) begin
        int ga;
        wr_n_d <= dut.wr_n;
        ga = !dut.iorq_n ? dut.A[7:0] : dut.A;
        if (!reset && wr_n_d && !dut.wr_n && (!dut.iorq_n || (mcat && !dut.mreq_n &&
            (dut.A[15:2] == 14'h3800 || dut.A == 16'hF000))) && keep_write(ga, dut.cpu_do, 1)) begin
            if (wi < w_t.size()) begin
                real dt;
                dt = t_us - w_t[wi];
                if (dt < 0) dt = -dt;
                if (dt > maxdt) maxdt = dt;
                if (ga != w_a[wi] || dut.cpu_do != w_d[wi]) begin
                    errors++;
                    if (errors <= 5) $display("MISMATCH write %0d at %.1f us: FPGA %02x=%02x MAME %02x=%02x (MAME t=%.1f)",
                        wi, t_us, ga, dut.cpu_do, w_a[wi], w_d[wi], w_t[wi]);
                end
            end
            if ($test$plusargs("SHOWW") && wi < w_t.size()) $display("W %0d FPGA %.2f MAME %.2f %02x=%02x", wi, t_us, w_t[wi], ga, dut.cpu_do);
            wi++;
            if (wi % 2000 == 0) $display("progress: %0d writes, %.0f ms, max offset %.1f us, errors %0d", wi, t_us / 1000.0, maxdt, errors);
            if (max_n != 0 && wi >= max_n) finish_run();
        end
    end

    // ADPCM-A data not yet filled when the chip latches it (the byte would be wrong)
    always @(posedge clk) if (!reset && dut.ce_8m && !dut.adpcma_roe_n && !dut.amatch) alate++;

    always @(posedge clk) if (!reset && clks % 16 == 0) $fwrite(afd, "%c%c", snd[7:0], snd[15:8]);
    // output activity: peaks and X detection every 100 ms
    int pk_l = 0, pk_psg = 0, n_xl = 0, n_xs = 0;
    always @(posedge clk) if (!reset) begin
        if ($isunknown(dut.fm_l)) n_xl++; else if ($signed(dut.fm_l) > pk_l) pk_l = $signed(dut.fm_l);
        if ($isunknown(dut.snd_s)) n_xs++;
        if (!$isunknown(dut.psg_a) && dut.psg_a > pk_psg) pk_psg = dut.psg_a;
        if (clks % 1600000 == 0)
            $display("t=%0d ms: ym writes %0d latch reads %0d nmis %0d | fm_l peak %0d (X %0d) psg_a peak %0d snd_s X %0d snd %0d",
                     clks / 16000, c_ym, c_lat, c_nmi, pk_l, n_xl, pk_psg, n_xs, snd);
    end
    always @(posedge clk) if (t_us >= run_ms * 1000.0) finish_run();

    task automatic finish_run();
        int expected;
        expected = 0;
        while (expected < w_t.size() && w_t[expected] <= t_us) expected++;
        $fclose(afd);
        $display("ADPCM-A cen ticks with the byte not yet filled: %0d; Z80 ROM misses %0d", alate, c_zmiss);
        if (errors == 0 && wi > 0 && (wi >= expected - 2 && wi <= expected + 2))
            $display("PASS M5_SOUND: %.0f ms, %0d Z80 I/O writes identical to MAME in order (MAME %0d by now, max time offset %.1f us); latch reads %0d, NMIs %0d, latch values replayed %0d",
                t_us / 1000.0, wi, expected, maxdt, c_lat, c_nmi, li);
        else
            $display("FAIL M5_SOUND: %0d mismatches, %0d writes (MAME %0d by %.0f ms), max time offset %.1f us",
                errors, wi, expected, t_us / 1000.0, maxdt);
        $finish;
    endtask
endmodule
