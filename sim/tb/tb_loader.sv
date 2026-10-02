// M1: the complete MRA ioctl stream (local/nost.rom from scripts/romtool.py stream; romtool
// mracheck proves it equals what the MRA delivers) through nost_loader + nost_sdram_arb + vendored
// sdram.sv + SDRAM chip model; afterwards every SDRAM word must equal romtool's SDRAM image
// (local/sim/sdram_le.bin). hps_io WIDE=1 timing: one ioctl_wr pulse per 16-bit word, the next word
// only after ioctl_wait has dropped (plus a few clocks).
`timescale 1ns/1ps
module tb_loader;
    logic clk = 0;
    always #5.099 clk = ~clk;
    logic init = 1;

    logic        dl = 0, wr = 0, wt;
    logic [26:0] ad = 0;
    logic [15:0] dout = 0;
    logic        req, ack, loaded;
    logic [25:1] maddr;
    logic [15:0] mdata;
    nost_loader loader (
        .clk(clk), .rst(init), .ioctl_download(dl), .ioctl_index(16'd0), .ioctl_wr(wr),
        .ioctl_addr(ad), .ioctl_dout(dout), .ioctl_wait(wt),
        .mem_req(req), .mem_addr(maddr), .mem_wdata(mdata), .mem_ack(ack),
        .zfix_we(), .zfix_waddr(), .zfix_wdata(), .loaded(loaded));

    logic [5:0] aacks;
    logic [26:1] sd_addr; logic [15:0] sd_din; logic [1:0] sd_be; logic sd_req, sd_rnw, sd_ready;
    logic [63:0] sd_dout, rdata;
    logic [25:1] arb_addr [6];
    assign arb_addr[0] = maddr;
    assign arb_addr[1] = '0; assign arb_addr[2] = '0; assign arb_addr[3] = '0; assign arb_addr[4] = '0; assign arb_addr[5] = '0;
    nost_sdram_arb arb (
        .clk(clk), .rst(init), .req({5'b0, req}), .addr(arb_addr), .we(6'b000001),
        .wdata(mdata), .wbe(2'b11), .ack(aacks), .rdata(rdata),
        .sd_addr(sd_addr), .sd_din(sd_din), .sd_be(sd_be), .sd_req(sd_req), .sd_rnw(sd_rnw),
        .sd_dout(sd_dout), .sd_ready(sd_ready));
    assign ack = aacks[0];

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
    sdr_sdram_model #(.TCK_NS(10.198)) chip (
        .clk(SDRAM_CLK), .cke(SDRAM_CKE), .csn(SDRAM_nCS), .rasn(SDRAM_nRAS), .casn(SDRAM_nCAS),
        .wen(SDRAM_nWE), .ba(SDRAM_BA), .a(SDRAM_A), .dqml(SDRAM_DQML), .dqmh(SDRAM_DQMH), .dq(SDRAM_DQ));

    initial begin
        int fd, n, errors, checked;
        logic [7:0] lo, hi;
        string stream, image;
        if (!$value$plusargs("STREAM=%s", stream)) stream = "local/nost.rom";
        if (!$value$plusargs("IMAGE=%s", image)) image = "local/sim/sdram_le.bin";
        repeat (8) @(posedge clk);
        init <= 0;
        repeat (13000) @(posedge clk);          // SDRAM controller start-up
        fd = $fopen(stream, "rb");
        if (fd == 0) begin $display("FAIL M1_LOADER: cannot open %s", stream); $finish; end
        dl <= 1;
        n = 0;
        while ($fread(lo, fd) == 1) begin
            void'($fread(hi, fd));
            @(posedge clk);
            ad <= 27'(n * 2); dout <= {hi, lo}; wr <= 1;
            @(posedge clk);
            wr <= 0;
            @(posedge clk);
            while (wt) @(posedge clk);
            n++;
            if (n % 1048576 == 0) $display("streamed %0d words", n);
        end
        $fclose(fd);
        repeat (64) @(posedge clk);
        dl <= 0;
        repeat (4) @(posedge clk);              // loaded is set when the download ends
        $display("stream: %0d words, loaded flag %0d", n, loaded);
        // compare every image word with the chip model (word address = SDRAM byte address / 2)
        fd = $fopen(image, "rb");
        errors = 0; checked = 0;
        for (int w = 0; $fread(lo, fd) == 1; w++) begin
            logic [15:0] want, got;
            void'($fread(hi, fd));
            want = {hi, lo};
            got  = chip.mem.exists(w) ? chip.mem[w] : 16'hA5C3;
            if (want != 16'h0000 || chip.mem.exists(w)) begin
                checked++;
                if (got != want) begin
                    if (errors < 8) $display("word %07x: SDRAM %04x image %04x", w, got, want);
                    errors++;
                end
            end
        end
        $fclose(fd);
        if (errors == 0 && loaded && chip.errors == 0)
            $display("PASS M1_LOADER: %0d stream words written; %0d SDRAM words == romtool image (model protocol errors 0)", n, checked);
        else
            $display("FAIL M1_LOADER: %0d differing words of %0d, loaded %0d, model errors %0d", errors, checked, loaded, chip.errors);
        $finish;
    end
endmodule
