// M4: controls and DIP switches. Each MiSTer joystick bit (CONF_STR J1 order: right, left, down, up,
// Shot, Button 2, Button 3, Start, Coin, Service) must reach exactly MAME's port bit (INPUT_PORTS_START
// ( nost ), active low) on the 68000's 0x800000 / 0x800002 reads, P1 bit 11 must read 0, and the DIP
// word sent by the MRA (ioctl index 254) must appear as MAME's DSW1/DSW2 values at 0xA00000/2.
`timescale 1ns/1ps
module tb_inputs;
    logic clk = 0, clk_snd = 0;
    always #5.099 clk = ~clk;
    always @(posedge clk) clk_snd <= ~clk_snd;
    logic [31:0] joy0 = 0, joy1 = 0;
    logic ioctl_download = 0, ioctl_wr = 0;
    logic [15:0] ioctl_index = 0, ioctl_dout = 0;
    logic [63:0] sd_dout = 0;
    logic ce_pix, hb, vb, hs, vs, iow;
    logic [23:0] rgb;
    logic signed [15:0] snd;
    logic [26:1] sd_addr; logic [15:0] sd_din; logic [1:0] sd_be; logic sd_req, sd_rnw;

    nost_core dut (
        .clk(clk), .clk_snd(clk_snd), .init(1'b1), .reset(1'b1), .pause(1'b0),
        .ioctl_download(ioctl_download), .ioctl_index(ioctl_index), .ioctl_wr(ioctl_wr), .ioctl_addr('0),
        .ioctl_dout(ioctl_dout), .ioctl_wait(iow),
        .sd_addr(sd_addr), .sd_din(sd_din), .sd_be(sd_be), .sd_req(sd_req), .sd_rnw(sd_rnw),
        .sd_dout(sd_dout), .sd_ready(1'b0),
        .joy0(joy0), .joy1(joy1), .test_pattern(1'b0), .dbg_overlay(1'b0), .flip180(1'b0), .cave038(1'b0),
        .ce_pix(ce_pix), .rgb(rgb), .hblank(hb), .vblank(vb), .hsync(hs), .vsync(vs), .snd(snd));

    int errors = 0, checks = 0;
    task automatic expect16(input string what, input logic [15:0] got, input logic [15:0] want);
        checks++;
        if (got !== want) begin errors++; $display("MISMATCH %s: %04x, expected %04x", what, got, want); end
    endtask

    // MAME bit for MiSTer joystick bit j (P1 / P2); -1 = not wired
    int p1map [10] = '{3, 2, 1, 0, 4, 5, 6, 7, 8, -1};   // service goes to P2 bit 9
    initial begin
        #100;
        expect16("P1 idle", dut.p1, 16'hF7FF);
        expect16("P2 idle", dut.p2, 16'hFFFF);
        for (int j = 0; j < 10; j++) begin
            joy0 = 32'(1) << j; #20;
            if (p1map[j] >= 0) expect16($sformatf("P1 joy bit %0d", j), dut.p1, 16'hF7FF & ~(16'(1) << p1map[j]));
            else begin
                expect16($sformatf("P1 joy bit %0d (service)", j), dut.p1, 16'hF7FF);
                expect16("P2 service from player 1", dut.p2, 16'hFDFF);
            end
            joy0 = 0;
            joy1 = 32'(1) << j; #20;
            if (p1map[j] >= 0) expect16($sformatf("P2 joy bit %0d", j), dut.p2, 16'hFFFF & ~(16'(1) << p1map[j]));
            else expect16("P2 service", dut.p2, 16'hFDFF);
            expect16("P1 unaffected by joy1", dut.p1, 16'hF7FF);
            joy1 = 0;
        end
        // DIPs: power-up value FFFF = MAME defaults; then Lives 5 (SW1:1,2 = 0) + Coin A free play
        expect16("DSW1 default", dut.dsw1, 16'hFF00);
        expect16("DSW2 default", dut.dsw2, 16'hFF00);
        @(posedge clk); ioctl_download <= 1; ioctl_index <= 16'd254; ioctl_dout <= 16'hF8FC; ioctl_wr <= 1;
        @(posedge clk); ioctl_wr <= 0;
        @(posedge clk); ioctl_download <= 0;
        #20;
        expect16("DSW1 lives 5", dut.dsw1, 16'hFC00);
        expect16("DSW2 coin A free play", dut.dsw2, 16'hF800);
        if (errors == 0) $display("PASS M4_INPUTS: %0d checks (joystick/button/coin/start/service bits, P1 bit 11, DIP download)", checks);
        else $display("FAIL M4_INPUTS: %0d of %0d checks failed", errors, checks);
        $finish;
    end
endmodule
