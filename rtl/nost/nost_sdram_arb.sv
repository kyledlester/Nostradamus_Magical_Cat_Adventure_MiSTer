// Nostradamus MiSTer core -- SDRAM channel-1 arbiter (from the owner's R-Shark core, N clients).
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Clients hold req (and their address) until they receive a one-clock ack; read data (64 bits,
// first word in [15:0]) is valid with the ack. Fixed priority, lowest index first:
//   0 loader (writes, download only), 1 68000 ROM cache, 2 ADPCM-A, 3 Z80 ROM, 4 tilemaps, 5 sprites.
// Chaining: when the controller signals completion of one access, the next client's request is
// issued in the same clock (sdram.sv latches ch1_req and accepts it on its next idle state), so a
// different client's access overlaps the capture/acknowledge of the previous one.
// A client is not eligible again until it has seen its ack and dropped req (block mask).
// sdram.sv raises ch1_ready one clock before the last burst word reaches ch1_dout, so read data is
// captured one clock after ready.
module nost_sdram_arb #(
    parameter int N = 6
) (
    input  logic          clk,
    input  logic          rst,

    input  logic  [N-1:0] req,
    input  logic   [25:1] addr [N],
    input  logic  [N-1:0] we,
    input  logic   [15:0] wdata,          // client 0 only
    input  logic    [1:0] wbe,            // client 0 only
    output logic  [N-1:0] ack,
    output logic   [63:0] rdata,

    output logic   [26:1] sd_addr,
    output logic   [15:0] sd_din,
    output logic    [1:0] sd_be,
    output logic          sd_req,
    output logic          sd_rnw,
    input  logic   [63:0] sd_dout,
    input  logic          sd_ready
);
    localparam int IW = $clog2(N);
    logic          busy;
    logic [IW-1:0] owner;
    logic          owner_we;
    logic          cap;
    logic [IW-1:0] cap_owner;
    logic  [N-1:0] block;

    wire  [N-1:0] avail = req & ~block & ~(busy ? (N'(1) << owner) : '0);
    logic [IW-1:0] pick;
    always_comb begin
        pick = '0;
        for (int i = N - 1; i >= 0; i--) if (avail[i]) pick = IW'(i);
    end
    wire done  = busy && sd_ready;
    wire issue = (avail != 0) && (!busy || done);

    always_ff @(posedge clk) begin
        ack    <= '0;
        sd_req <= 1'b0;
        if (rst) begin
            busy  <= 1'b0;
            cap   <= 1'b0;
            block <= '0;
        end else begin
            block <= block & req;
            cap <= 1'b0;
            if (done) begin
                block[owner] <= 1'b1;
                if (owner_we) ack[owner] <= 1'b1;
                else begin
                    cap       <= 1'b1;
                    cap_owner <= owner;
                end
            end
            if (cap) begin
                rdata          <= sd_dout;
                ack[cap_owner] <= 1'b1;
            end
            if (issue) begin
                owner    <= pick;
                owner_we <= we[pick];
                sd_addr  <= {1'b0, addr[pick]};
                sd_rnw   <= !we[pick];
                sd_din   <= wdata;
                sd_be    <= wbe;
                sd_req   <= 1'b1;
                busy     <= 1'b1;
            end else if (done)
                busy <= 1'b0;
        end
    end
endmodule
