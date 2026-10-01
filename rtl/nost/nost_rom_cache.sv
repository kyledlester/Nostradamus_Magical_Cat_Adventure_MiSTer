// Nostradamus MiSTer core -- 68000 program ROM cache.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The 1 MB program ROM lives in SDRAM (docs/ROM_LAYOUT.md). A direct-mapped cache of 2^IW lines of
// 8 bytes (one 4-word SDRAM burst) answers hits with the same latency as block RAM, so hits cost
// the 68000 no wait states; a miss fetches the line (the CPU waits; MAME has no wait states at all,
// docs/KNOWN_ISSUES.md). The cache only holds ROM, so it never needs write-back; it is cleared by
// the board reset (every ROM download).
//
// Protocol: `addr` is stable while `lookup` is high (the bus backend's ROM state); `hit` rises
// when the word is available on `q` (at once, or after the line fill). RAM reads are registered:
// q/hit are valid from the second clock after `addr` became stable.
module nost_rom_cache #(
    parameter int IW = 12               // index bits: 4096 lines = 32 KB
) (
    input  logic        clk,
    input  logic        reset,

    input  logic [19:1] addr,
    input  logic        lookup,
    output logic        hit,
    output logic [15:0] q,
    output logic        busy,

    output logic        mem_req,
    output logic [19:3] mem_line,
    input  logic        mem_ack,
    input  logic [63:0] mem_data,

    output logic [15:0] misses
);
    localparam int TW = 17 - IW;        // tag bits addr[19:IW+3]

    logic [IW-1:0] clr_idx;
    logic          clearing;
    logic          filling;
    logic [1:0]    settle;              // RAM read-after-write latency after a fill

    logic          tag_we;
    logic [IW-1:0] tag_waddr;
    logic [TW:0]   tag_wdata;           // {valid, tag}
    logic [TW:0]   tag_q;
    logic [63:0]   data_q;

    wire [IW-1:0] idx = addr[IW+2:3];
    wire [TW-1:0] tag = addr[19:IW+3];

    nost_sdpram #(.AW(IW), .DW(TW + 1)) tags (
        .clk(clk), .w_addr(tag_waddr), .we(tag_we), .din(tag_wdata), .r_addr(idx), .dout(tag_q));
    nost_sdpram #(.AW(IW), .DW(64)) data (
        .clk(clk), .w_addr(idx), .we(filling && mem_ack), .din(mem_data), .r_addr(idx), .dout(data_q));

    wire match = tag_q[TW] && tag_q[TW-1:0] == tag;
`ifdef NOST_SIM_ROM
    // simulation only: zero-wait program ROM (MAME timing) for the bus-trace comparison bench
    logic [15:0] simrom [0:524287];
    initial $readmemh("local/sim/maincpu.hex", simrom);
    assign hit  = lookup;
    assign q    = simrom[addr];
`else
    assign hit  = lookup && match && !clearing && !filling && settle == 0;
    assign q    = data_q[addr[2:1]*16 +: 16];
`endif
    assign busy = clearing || filling;

    always_comb begin
        tag_we    = clearing || (filling && mem_ack);
        tag_waddr = clearing ? clr_idx : idx;
        tag_wdata = clearing ? '0 : {1'b1, tag};
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            clearing <= 1'b1;
            clr_idx  <= '0;
            filling  <= 1'b0;
            mem_req  <= 1'b0;
            settle   <= 2'd0;
            misses   <= '0;
        end else begin
            if (settle != 0) settle <= settle - 2'd1;
            if (clearing) begin
                clr_idx <= clr_idx + 1'd1;
                if (&clr_idx) begin
                    clearing <= 1'b0;
                    settle   <= 2'd2;
                end
            end else if (filling) begin
                if (mem_ack) begin
                    mem_req <= 1'b0;
                    filling <= 1'b0;
                    settle  <= 2'd2;
                end
            end else if (lookup && !match && settle == 0) begin
                filling  <= 1'b1;
                mem_req  <= 1'b1;
                mem_line <= addr[19:3];
                misses   <= misses + 16'd1;
            end
        end
    end
endmodule
