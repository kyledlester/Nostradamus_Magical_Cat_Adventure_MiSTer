// M6: whole board (nost_core: 68000 board, video, Z80 sound board, SDRAM arbiter) running the real
// program, with the production clocks, the vendored SDRAM controller and a preloaded chip model
// (the loader is checked by tb_loader).
// +SKIPWD starts at MAME's watchdog reset: work RAM holds the 'nost' signature, so the program boots
// at once instead of spinning 3 s (tb_boot +WDTEST covers that path).
// +SNAP=<dir> starts from a MAME snapshot (scripts/mame/snapshot.lua: the 68000 board at the entry of
// the IRQ1 handler of frame F) - simulation only, to reach attract mode / gameplay in hours instead
// of days. The board RAMs and registers are preloaded; a stub (written into an unused ROM page of the
// SDRAM model, reset vector patched) loads USP, D0-D7, A0-A6 and SP + 6, then STOPs with MAME's
// condition codes; the FPGA's own vblank IRQ1 (line 224) enters the handler as in MAME, and the
// bench then writes MAME's exception frame (SR, PC) over the one the stub's STOP produced. The Z80
// board starts from reset (its state is not part of the snapshot). FPGA vblank n = MAME frame F + n.
// Plusargs:
//   +FRAMES=<n>   run until the n-th vblank (default 40)
//   +DUMP=<list>  "a-b/s,..." vblank numbers whose following displayed frame is written to
//                 build/sim/frames/cNNNNN.rgb (320x224 RGB24)
//   +INPUTS=<file> lines "<vblank> <joy0 hex> <joy1 hex>" (MiSTer joystick bits) applied at that vblank
//   +DSW=<hex>    DIP word as the MRA sends it (index 254), default FFFF
//   +AUDIO=<file> signed 16-bit mono at 48 kHz
// Writes <FRAMEDIR>/latch.txt ("frame line value" per 68000 sound-latch write) and prints counters.
`timescale 1ns/1ps
module tb_system;
    logic clk = 0, clk_snd = 0;
    always #5.099 clk = ~clk;
`ifdef NOST_SIM_SND16
    // simulation speed: the sound board on a 16 MHz bench clock with ce_8m every 2nd clock (exact
    // 8 MHz / 4 MHz enables, 1/3 of the clock edges of the production clk_sys / 2)
    always #31.25 clk_snd = ~clk_snd;
    localparam int SND_NUM = 1, SND_DEN = 2;
`else
    always @(posedge clk) clk_snd <= ~clk_snd;
    localparam int SND_NUM = 3125, SND_DEN = 19152;
`endif
    logic init = 1, reset = 1;

    logic [26:1] sd_addr; logic [15:0] sd_din; logic [1:0] sd_be; logic sd_req, sd_rnw, sd_ready;
    logic [63:0] sd_dout;
    logic ce_pix; logic [23:0] rgb; logic hb, vb, hs, vs;
    logic signed [15:0] snd;
    logic ioctl_wait;
    logic [31:0] joy0 = 0, joy1 = 0;
    logic ioctl_download = 0, ioctl_wr = 0;
    logic [15:0] ioctl_index = 0, ioctl_dout = 0;
    string sdram_img;

    nost_core #(.SND_CE_NUM(SND_NUM), .SND_CE_DEN(SND_DEN)) dut (
        .clk(clk), .clk_snd(clk_snd), .init(init), .reset(reset), .pause(1'b0),
        .ioctl_download(ioctl_download), .ioctl_index(ioctl_index), .ioctl_wr(ioctl_wr), .ioctl_addr('0),
        .ioctl_dout(ioctl_dout), .ioctl_wait(ioctl_wait),
        .sd_addr(sd_addr), .sd_din(sd_din), .sd_be(sd_be), .sd_req(sd_req), .sd_rnw(sd_rnw),
        .sd_dout(sd_dout), .sd_ready(sd_ready),
        .joy0(joy0), .joy1(joy1), .test_pattern(1'b0), .dbg_overlay(1'b0),
        .ce_pix(ce_pix), .rgb(rgb), .hblank(hb), .vblank(vb), .hsync(hs), .vsync(vs), .snd(snd));

    wire [15:0] SDRAM_DQ; wire [12:0] SDRAM_A; wire [1:0] SDRAM_BA;
    wire SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS, SDRAM_CKE, SDRAM_CLK;
    sdram #(.CYCLES_PER_REFRESH(14'd760)) sdc (
        .init(init), .clk(clk), .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML),
        .SDRAM_DQMH(SDRAM_DQMH), .SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
        .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CKE(SDRAM_CKE), .SDRAM_CLK(SDRAM_CLK),
        .ch1_addr(sd_addr), .ch1_dout(sd_dout), .ch1_din(sd_din), .ch1_be(sd_be), .ch1_req(sd_req),
        .ch1_rnw(sd_rnw), .ch1_ready(sd_ready),
        .ch2_addr('0), .ch2_dout(), .ch2_din('0), .ch2_req(1'b0), .ch2_rnw(1'b1), .ch2_ready(),
        .ch3_addr('0), .ch3_dout(), .ch3_din('0), .ch3_req(1'b0), .ch3_rnw(1'b1), .ch3_ready());
    sdr_sdram_model #(.TCK_NS(10.198), .UNWRITTEN(16'h0000)) chip (
        .clk(SDRAM_CLK), .cke(SDRAM_CKE), .csn(SDRAM_nCS), .rasn(SDRAM_nRAS), .casn(SDRAM_nCAS),
        .wen(SDRAM_nWE), .ba(SDRAM_BA), .a(SDRAM_A), .dqml(SDRAM_DQML), .dqmh(SDRAM_DQMH), .dq(SDRAM_DQ));

    int max_frames = 40;
    bit dump_want [int];
    // inputs
    int in_frame [$]; logic [31:0] in_joy0 [$], in_joy1 [$];
    string inputs_file, dump_list, audio_file, frame_dir = "build/sim/frames";
    initial if ($value$plusargs("INPUTS=%s", inputs_file)) begin
        int ifd, f; logic [31:0] j0, j1;
        ifd = $fopen(inputs_file, "r");
        while ($fscanf(ifd, "%d %h %h\n", f, j0, j1) == 3) begin
            in_frame.push_back(f); in_joy0.push_back(j0); in_joy1.push_back(j1);
        end
        $fclose(ifd);
        $display("inputs: %0d events from %s", in_frame.size(), inputs_file);
    end
    wire [15:0] frames = dut.dbg_frames;
    int in_i = 0;
    always @(posedge clk) if (in_i < in_frame.size() && frames >= in_frame[in_i]) begin
        joy0 <= in_joy0[in_i]; joy1 <= in_joy1[in_i]; in_i++;
    end

    int lfd, afd = 0;
    string snap_dir;
    logic [31:0] snap_sp, snap_sr;
    logic [15:0] snap_tm [$], snap_vid [$], snap_ram [$];
    bit snap_frame_pending = 0;

    task automatic load_words(input string f, input int n, ref logic [15:0] q [$]);
        int fd; logic [7:0] hi, lo;
        fd = $fopen(f, "rb");
        if (fd == 0) begin $display("FAIL M6_SYSTEM: cannot open %s", f); $finish; end
        for (int i = 0; i < n; i++) begin void'($fread(hi, fd)); void'($fread(lo, fd)); q.push_back({hi, lo}); end
        $fclose(fd);
    endtask

    task automatic restore_snapshot();
        logic [15:0] q [$];
        int fd, r; string name; logic [31:0] v;
        logic [31:0] regs [string];
        fd = $fopen({snap_dir, "/regs.txt"}, "r");
        while ($fscanf(fd, "%s %h
", name, v) == 2) regs[name] = v;
        $fclose(fd);
        // work RAM
        q.delete(); load_words({snap_dir, "/ram.bin"}, 32768, q);
        foreach (q[i]) begin dut.main.ram.hi[i] = q[i][15:8]; dut.main.ram.lo[i] = q[i][7:0]; end
        // 038 RAMs
        q.delete(); load_words({snap_dir, "/vram0.bin"}, 4096, q);
        foreach (q[i]) begin dut.main.vram0.hi.mem[i] = q[i][15:8]; dut.main.vram0.lo.mem[i] = q[i][7:0]; end
        q.delete(); load_words({snap_dir, "/vram1.bin"}, 4096, q);
        foreach (q[i]) begin dut.main.vram1.hi.mem[i] = q[i][15:8]; dut.main.vram1.lo.mem[i] = q[i][7:0]; end
        // palette 600000-601FFF + 602000-602FFF
        q.delete(); load_words({snap_dir, "/pal.bin"}, 6144, q);
        foreach (q[i]) if (i < 4096) begin dut.main.pal.hi.mem[i] = q[i][15:8]; dut.main.pal.lo.mem[i] = q[i][7:0]; end
                       else begin dut.main.palx.hi[i - 4096] = q[i][15:8]; dut.main.palx.lo[i - 4096] = q[i][7:0]; end
        // sprite RAM 700000-707FFF (4 word banks) + 708000-70FFFF
        q.delete(); load_words({snap_dir, "/spr.bin"}, 32768, q);
        foreach (q[i]) if (i < 16384) begin
            case (i % 4)
                0: begin dut.main.spr_words[0].bank.hi.mem[i / 4] = q[i][15:8]; dut.main.spr_words[0].bank.lo.mem[i / 4] = q[i][7:0]; end
                1: begin dut.main.spr_words[1].bank.hi.mem[i / 4] = q[i][15:8]; dut.main.spr_words[1].bank.lo.mem[i / 4] = q[i][7:0]; end
                2: begin dut.main.spr_words[2].bank.hi.mem[i / 4] = q[i][15:8]; dut.main.spr_words[2].bank.lo.mem[i / 4] = q[i][7:0]; end
                3: begin dut.main.spr_words[3].bank.hi.mem[i / 4] = q[i][15:8]; dut.main.spr_words[3].bank.lo.mem[i / 4] = q[i][7:0]; end
            endcase
        end else begin dut.main.sprx.hi[i - 16384] = q[i][15:8]; dut.main.sprx.lo[i - 16384] = q[i][7:0]; end
        // registers (forced after reset release below: the board reset clears them)
        q.delete(); load_words({snap_dir, "/tmregs.bin"}, 6, q); snap_tm = q;
        q.delete(); load_words({snap_dir, "/vidregs.bin"}, 8, q); snap_vid = q;
        // stub at 0x0F0000, register table at 0x0F0100 (SDRAM model word addresses)
        begin
            logic [15:0] stub [$];
            logic [31:0] tab [$];
            snap_sp = regs["SP"];
            snap_sr = regs["SR"];
            stub = '{16'h2E7C, 16'h000F, 16'h0100,     // movea.l #$F0100, a7
                     16'h205F,                        // movea.l (a7)+, a0
                     16'h4E60,                        // move.l a0, usp
                     16'h4CDF, 16'h7FFF,              // movem.l (a7)+, d0-d7/a0-a6
                     16'h2E57,                        // movea.l (a7), a7
                     16'h4E72, 16'h2000 | (snap_sr[15:0] & 16'h001F),   // stop #($2000 | CCR)
                     16'h60FE};                       // bra * (not reached)
            foreach (stub[i]) chip.mem[24'h078000 + i] = stub[i];
            tab = '{regs["USP"], regs["D0"], regs["D1"], regs["D2"], regs["D3"], regs["D4"], regs["D5"],
                    regs["D6"], regs["D7"], regs["A0"], regs["A1"], regs["A2"], regs["A3"], regs["A4"],
                    regs["A5"], regs["A6"], regs["SP"] + 32'd6};
            foreach (tab[i]) begin chip.mem[24'h078080 + 2 * i] = tab[i][31:16]; chip.mem[24'h078081 + 2 * i] = tab[i][15:0]; end
            chip.mem[24'h000000] = 16'h0011; chip.mem[24'h000001] = 16'h0000;   // SSP (overwritten)
            chip.mem[24'h000002] = 16'h000F; chip.mem[24'h000003] = 16'h0000;   // PC = stub
            snap_frame_pending = 1;
            $display("snapshot %s: SP %08x SR %04x PC %08x (handler entry)", snap_dir, regs["SP"], regs["SR"], regs["PC"]);
        end
    endtask
    // registers after the reset release; MAME's exception frame once the handler has been entered
    always @(posedge clk) begin
        if (snap_tm.size() == 6 && !reset && dut.main.tm0[0] == 16'h0000 && dut.dbg_frames == 0) begin
            for (int i = 0; i < 3; i++) begin dut.main.tm0[i] = snap_tm[i]; dut.main.tm1[i] = snap_tm[i + 3]; end
            for (int i = 0; i < 8; i++) dut.main.vid[i] = snap_vid[i];
        end
        if (snap_frame_pending && dut.main.cpu_ack && !dut.main.cpu_write && dut.main.a == 24'h000898) begin
            // the CPU pushed its own frame at SP; restore MAME's (captured with the RAM)
            automatic int w = (snap_sp - 32'h100000) >> 1;
            snap_frame_pending = 0;
            $display("snapshot: IRQ1 handler entered at line %0d dot %0d; MAME exception frame restored at %06x", dut.vcount, dut.hcount, snap_sp);
            restore_frame(w);
        end
    end
    task automatic restore_frame(input int w);
        if (snap_ram.size() == 0) load_words({snap_dir, "/ram.bin"}, 32768, snap_ram);
        for (int i = 0; i < 3; i++) begin
            dut.main.ram.hi[w + i] = snap_ram[w + i][15:8];
            dut.main.ram.lo[w + i] = snap_ram[w + i][7:0];
        end
    endtask
    initial begin
        logic [15:0] dsw = 16'hFFFF;
        void'($value$plusargs("FRAMES=%d", max_frames));
        void'($value$plusargs("FRAMEDIR=%s", frame_dir));
        void'($value$plusargs("DSW=%h", dsw));
        if ($value$plusargs("DUMP=%s", dump_list)) begin
            // "a-b/s,c,..."
            int p = 0;
            while (p < dump_list.len()) begin
                int a, b, s, q; string item;
                q = p;
                while (q < dump_list.len() && dump_list[q] != ",") q++;
                item = dump_list.substr(p, q - 1);
                if ($sscanf(item, "%d-%d/%d", a, b, s) == 3) for (int f = a; f <= b; f += s) dump_want[f] = 1;
                else if ($sscanf(item, "%d", a) == 1) dump_want[a] = 1;
                p = q + 1;
            end
        end
        if ($value$plusargs("AUDIO=%s", audio_file)) afd = $fopen(audio_file, "wb");
        if (!$value$plusargs("SDRAM=%s", sdram_img)) sdram_img = "local/sim/sdram_be.bin";
        chip.preload(sdram_img);
        lfd = $fopen({frame_dir, "/latch.txt"}, "w");
        if ($value$plusargs("SNAP=%s", snap_dir)) restore_snapshot();
        if ($test$plusargs("BOOTPATCH")) begin
            // scripts/mame/bootpatch.lua, applied to the SDRAM image (word addresses)
            chip.mem[24'h0000B1] = $test$plusargs("BOOTPATCH2") ? 16'h0001 : 16'h0004;   // 0x162: cmpa.l #$010000 / #$040000
            chip.mem[24'h0000B5] = 16'h6000;                        // 68000 0x16A: bra
            chip.mem[24'h0000BA] = 16'h6000;                        // 68000 0x174: bra
            chip.mem[24'h000135] = 16'h6000; chip.mem[24'h000136] = 16'h01B6;   // 0x26A: bra $422
            chip.mem[24'h0802FC] = {8'hC3, chip.mem[24'h0802FC][7:0]};          // Z80 0x5F9: jp $0604
            chip.mem[24'h0802FD] = 16'h0604;
`ifndef NOST_SIM_NO_SOUND
            dut.sound.zfix_hi.mem[14'h2FC] = 8'hC3; dut.sound.zfix_lo.mem[14'h2FD] = 8'h04; dut.sound.zfix_hi.mem[14'h2FD] = 8'h06;
`endif
            $display("boot patches applied (scripts/mame/bootpatch.lua)");
        end
        if ($test$plusargs("SKIPWD")) begin
            dut.main.ram.hi[15'h0E] = 8'h6E; dut.main.ram.lo[15'h0E] = 8'h6F;
            dut.main.ram.hi[15'h0F] = 8'h73; dut.main.ram.lo[15'h0F] = 8'h74;
        end
        repeat (8) @(posedge clk);
        // DIP switches exactly as the MRA sends them: ioctl index 254, one word
        @(posedge clk); ioctl_download <= 1; ioctl_index <= 16'd254; ioctl_dout <= dsw; ioctl_wr <= 1;
        @(posedge clk); ioctl_wr <= 0;
        @(posedge clk); ioctl_download <= 0;
        init <= 0;
        // the SDRAM controller needs ~12100 clocks after init; the CPU waits for its first ROM line
        reset <= 0;
    end

    always @(posedge clk) if (dut.main.snd_latch_wr)
        $fdisplay(lfd, "%0d %0d %02x", frames, dut.vcount, dut.main.cpu_wdata[7:0]);

    // audio at 48 kHz (fractional: 48000 / 98058240)
    longint aacc = 0;
    always @(posedge clk) if (afd && !reset) begin
        aacc += 48000;
        if (aacc >= 98058240) begin aacc -= 98058240; $fwrite(afd, "%c%c", snd[7:0], snd[15:8]); end
    end

    // frame dumps (output timing: rgb/hblank/vblank are aligned)
    int fd = 0;
    logic vb_d = 1;
    always @(posedge clk) if (ce_pix && !init) begin
        vb_d <= vb;
        if (vb_d && !vb) begin
            if (fd) begin $fclose(fd); fd = 0; end
            if (dump_want.exists(frames)) fd = $fopen($sformatf("%s/c%0d%0d%0d%0d%0d.rgb", frame_dir, frames / 10000, frames / 1000 % 10, frames / 100 % 10, frames / 10 % 10, frames % 10), "wb");
        end
        if (fd && !hb && !vb) $fwrite(fd, "%c%c%c", rgb[23:16], rgb[15:8], rgb[7:0]);
    end

    logic [15:0] last_frames = 0;
    always @(posedge clk) begin
        if (frames != last_frames) begin
            last_frames <= frames;
            if (frames % 10 == 0)
                $display("frame %0d: pc %06x irq1 %0d latch %0d wd %0d romm %0d | z80 latch rd %0d nmi %0d ym %0d zmiss %0d | overruns %0d maxbusy %0d",
                    frames, dut.dbg_pc, dut.dbg_irq1, dut.dbg_latch, dut.dbg_wd, dut.dbg_romm, dut.dbg_lat_rd,
                    dut.dbg_nmi, dut.dbg_ym, dut.dbg_zmiss, dut.dbg_overruns, dut.dbg_maxbusy);
            if (frames >= max_frames) begin
                $display("PASS M6_SYSTEM: ran %0d frames: pc %06x irq1 %0d latch writes %0d watchdog resets %0d; z80 latch reads %0d nmis %0d ym writes %0d; render overruns %0d (longest line %0d clocks)",
                    frames, dut.dbg_pc, dut.dbg_irq1, dut.dbg_latch, dut.dbg_wd, dut.dbg_lat_rd, dut.dbg_nmi,
                    dut.dbg_ym, dut.dbg_overruns, dut.dbg_maxbusy);
                $fclose(lfd);
                if (afd) $fclose(afd);
                $finish;
            end
        end
    end
endmodule
