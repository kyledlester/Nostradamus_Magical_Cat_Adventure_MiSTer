// M2: real Nostradamus program on FX68K inside nost_main, 68000 bus transactions compared one by one
// with MAME's (scripts/mame/bus_trace.lua -> local/bus_trace.txt, logged from the watchdog reset
// that ends MAME's cold-boot wait). Every data-bus cycle (opcode fetches included) must match in
// order: direction, address, data (enabled lanes), byte mask. Production clock ratio (clk_sys =
// 98.06 MHz, 32 MHz phase tick) and production raster events, so interrupt chronology is compared.
//
// The bench starts where MAME's trace starts: the watchdog soft reset at 3.0 s, i.e. work RAM
// already holds the 'nost' signature at 0x10001C (written by the cold-boot code) and the beam is at
// line 224 dot 0. +WDTEST checks the cold boot itself: no signature, the CPU must write it and spin
// without other bus writes until the watchdog resets it (period shortened with vsim -gWD_TICKS=n),
// and from that reset on the transactions must match MAME's trace (interrupt chronology differs
// there because the shortened reset lands on another raster position).
//
// Program ROM: +define+NOST_SIM_ROM (zero-latency ROM model answering the cache's line requests in
// one clock: MAME has no wait states, so the trace keeps MAME's timing) or the default SDRAM-like
// line latency (+ROMLAT=<clocks>, default 14).
// Latch 2 (Z80 -> 68000) is replayed from the trace: when the next MAME transaction is a read of
// 0xC00000, the latch presents MAME's value.
// Plusargs: +TRACE=<file> (default local/bus_trace.txt), +N=<transactions> (default 20000),
// +ROMHEX=<file> (default local/sim/maincpu.hex), +RAMIMG=<file> (work RAM at the reset, 32768 hex
// words from bus_trace.lua NOST_RAM, instead of the 'nost' signature), +MCAT (Magical Cat
// Adventure port values: P1 FFFF, DSW low bytes FF).
`timescale 1ns/1ps
module tb_boot #(parameter int WD_TICKS = 96_000_000);
    logic clk = 0;
    always #5.099 clk = ~clk;                   // 98.058 MHz
    logic reset = 1, init = 1;

    logic ce_pix, tick32, phi1, phi2;
    nost_clocks clocks (.clk(clk), .rst(reset), .rst_video(init), .pause(1'b0),
        .ce_pix(ce_pix), .tick32(tick32), .phi1(phi1), .phi2(phi2));
    logic [8:0] hc; logic [7:0] vc; logic hb, vb, hs, vs, ls;
    nost_video_timing timing (.clk(clk), .rst(init), .ce_pix(ce_pix),
        .hcount(hc), .vcount(vc), .hblank(hb), .vblank(vb), .hsync(hs), .vsync(vs), .line_start(ls));
    wire vblank_evt = ls && vc == 8'd224;

    // ROM line model
    logic [15:0] rom [0:524287];
    string romhex;
    initial begin
        if (!$value$plusargs("ROMHEX=%s", romhex)) romhex = "local/sim/maincpu.hex";
        $readmemh(romhex, rom);
    end
    logic [15:0] p1v = 16'hF7FF, dswv = 16'hFF00;
    initial if ($test$plusargs("MCAT")) begin p1v = 16'hFFFF; dswv = 16'hFFFF; end
    logic        rom_req, rom_ack;
    logic [19:3] rom_line;
    logic [63:0] rom_data;
    int romlat = 14, lat_cnt = 0;
    initial begin
`ifdef NOST_SIM_ROM
        romlat = 0;
`endif
        void'($value$plusargs("ROMLAT=%d", romlat));
    end
    always @(posedge clk) begin
        rom_ack <= 1'b0;
        if (rom_req && !rom_ack) begin
            if (lat_cnt >= romlat) begin
                rom_ack  <= 1'b1;
                rom_data <= {rom[{rom_line, 2'd3}], rom[{rom_line, 2'd2}], rom[{rom_line, 2'd1}], rom[{rom_line, 2'd0}]};
                lat_cnt  <= 0;
            end else lat_cnt <= lat_cnt + 1;
        end
    end

    logic [7:0] latch, latch2 = 8'h00;
    logic latch_wr, soft_reset, busy;
    logic [15:0] vq0, vq1, pq;
    logic [63:0] sq;
    logic [47:0] r0, r1;
    logic [15:0] gx, gy;
    logic [23:0] pc; logic [15:0] n1, nf, nl, nwd, nmiss;
    nost_main #(.WD_TICKS(WD_TICKS)) dut (
        .clk(clk), .reset(reset), .phi1(phi1), .phi2(phi2), .tick32(tick32),
        .rom_req(rom_req), .rom_line(rom_line), .rom_ack(rom_ack), .rom_data(rom_data),
        .vblank_evt(vblank_evt),
        .p1(p1v), .p2(16'hFFFF), .dsw1(dswv), .dsw2(dswv),
        .snd_latch(latch), .snd_latch_wr(latch_wr), .latch2(latch2), .soft_reset(soft_reset),
        .vram0_addr(12'd0), .vram0_q(vq0), .vram1_addr(12'd0), .vram1_q(vq1),
        .pal_addr(12'd0), .pal_q(pq), .sbuf_addr(11'd0), .sbuf_q(sq),
        .tm0_regs(r0), .tm1_regs(r1), .spr_gx(gx), .spr_gy(gy), .spr_copy_busy(busy),
        .dbg_pc(pc), .dbg_irq1(n1), .dbg_frames(nf), .dbg_latch_writes(nl), .dbg_wd_resets(nwd),
        .dbg_rom_misses(nmiss));

    // bus-cycle length histogram in 32 MHz ticks (half CPU clocks) between AS assertions:
    // a zero-wait 68000 bus cycle is 4 CPU clocks = 8 ticks.
    wire as_n = dut.dbg_native[57];
    logic as_n_d = 1;
    int ticks_since_as = 0;
    int as_hist [0:31];
    initial for (int i = 0; i < 32; i++) as_hist[i] = 0;
    always @(posedge clk) begin
        as_n_d <= as_n;
        if (tick32) ticks_since_as++;
        if (as_n_d && !as_n) begin
            as_hist[ticks_since_as > 31 ? 31 : ticks_since_as]++;
            ticks_since_as = 0;
        end
    end
    final begin
        automatic string h = "";
        for (int i = 0; i < 32; i++) if (as_hist[i] != 0) h = {h, $sformatf(" %0d:%0d", i, as_hist[i])};
        $display("AS-to-AS ticks histogram:%s", h);
        $display("ROM cache misses %0d", nmiss);
    end

    // trace with one record of lookahead
    int fd, n = 0, max_n = 20000;
    bit spun = 0;
    string trace, ramimg;
    string nkind; int naddr, ndata, nmask, nr;
    task automatic next_rec();
        nr = $fscanf(fd, "%s %h %h %h\n", nkind, naddr, ndata, nmask);
        if (nr == 4 && nkind == "R" && naddr == 24'hC00000) latch2 = ndata[7:0];
    endtask

    initial begin
        if (!$value$plusargs("TRACE=%s", trace)) trace = "local/bus_trace.txt";
        void'($value$plusargs("N=%d", max_n));
        fd = $fopen(trace, "r");
        if (fd == 0) begin $display("FAIL M2_BOOT: cannot open %s", trace); $finish; end
        next_rec();
        // post-watchdog state: signature in work RAM (word 0x0E/0x0F of 0x100000)
        if ($value$plusargs("RAMIMG=%s", ramimg)) begin
            logic [15:0] img [0:32767];
            $readmemh(ramimg, img);
            for (int i = 0; i < 32768; i++) begin dut.ram.hi[i] = img[i][15:8]; dut.ram.lo[i] = img[i][7:0]; end
        end else if (!$test$plusargs("WDTEST")) begin
            dut.ram.hi[15'h0E] = 8'h6E; dut.ram.lo[15'h0E] = 8'h6F;
            dut.ram.hi[15'h0F] = 8'h73; dut.ram.lo[15'h0F] = 8'h74;
        end
        repeat (8) @(posedge clk);
        init <= 0;
        reset <= 0;
    end

    always @(posedge clk) if (dut.cpu_ack) begin
        int got_addr, got_data, got_mask;
        got_addr = {dut.a[23:1], 1'b0};
        got_data = dut.cpu_write ? dut.cpu_wdata : dut.cpu_rdata;
        got_mask = {{8{dut.cpu_be[1]}}, {8{dut.cpu_be[0]}}};
        if ($test$plusargs("WDTEST") && nwd == 0) begin
            // cold boot: before the watchdog reset only the signature write may appear
            if (dut.cpu_write && !(got_addr == 24'h10001C || got_addr == 24'h10001E)) begin
                $display("FAIL M2_WDTEST: write %06x before the watchdog reset", got_addr);
                $finish;
            end
            if (n == 0) $display("cold boot: spinning until the watchdog (%0d ticks)", WD_TICKS);
            if (pc == 24'h11E || pc == 24'h120) spun = 1;
        end else        begin
            if (nr != 4) begin
                $display("PASS M2_BOOT: trace exhausted after %0d matching transactions", n);
                $finish;
            end
            if ((nkind == "W") != dut.cpu_write || naddr != got_addr || nmask != got_mask ||
                ((ndata ^ got_data) & got_mask) != 0) begin
                $display("FAIL M2_BOOT: transaction %0d mismatch: MAME %s %06x %04x %04x  FPGA %s %06x %04x %04x  (line %0d dot %0d, irq1 acks %0d, pc=%06x)",
                    n, nkind, naddr, ndata, nmask, dut.cpu_write ? "W" : "R", got_addr, got_data, got_mask,
                    vc, hc, n1, pc);
                $finish;
            end
            if (!dut.cpu_write && got_addr == 24'h64)
                $display("VEC 000064 frame %0d line %0d dot %0d transaction %0d", nf, vc, hc, n);
            n++;
            next_rec();
            if (n % 50000 == 0) $display("progress %0d transactions, line %0d, frames %0d, irq1 %0d, misses %0d", n, vc, nf, n1, nmiss);
            if (n >= max_n) begin
                if ($test$plusargs("WDTEST")) begin
                    $display("%s M2_WDTEST: cold boot spun at 0x11E (%0d), watchdog resets %0d, then %0d transactions identical to MAME",
                             (spun && nwd == 1) ? "PASS" : "FAIL", spun, nwd, n);
                    $finish;
                end
                $display("PASS M2_BOOT: %0d transactions identical to MAME (frames %0d, irq1 acks %0d, sound latch writes %0d, watchdog resets %0d, pc %06x, rom misses %0d)",
                    n, nf, n1, nl, nwd, pc, nmiss);
                $finish;
            end
        end
    end
endmodule
