// Nostradamus MiSTer core -- ROM loader (ioctl index 0, hps_io WIDE=1).
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Stream layout and SDRAM image: docs/ROM_LAYOUT.md (scripts/romtool.py is the executable form;
// its SDRAM image is what this module writes, word for word). Every stream word goes to SDRAM:
//   000000-0FFFFF maincpu  -> 0x0000000 + a   (68000 words as delivered)
//   100000-13FFFF soundcpu -> 0x0100000 + a'  ({byte 2k+1, byte 2k}); 100000-107FFF also to the
//                            Z80's block-RAM copy of 0000-7FFF (nost_sound)
//   140000-23FFFF adpcma   -> 0x0200000 + a'
//   240000-3BFFFF bg0      -> 0x0400000 + row reorder (romtool gfx_row_perm)
//   3C0000-53FFFF bg1      -> 0x0D00000 + row reorder
//   540000-A3FFFF sprdata  -> 0x0800000 + a'
//   A40000-B3FFFF bg1 0x180000-0x27FFFF (Magical Cat only) -> 0x0E80000 + row reorder
// and a second copy of bg0 / bg1 in MAME byte order (no row reorder) at 0x1000000 / 0x1200000 for
// the Cave 038 engine (nost_tilemap_cave).
// ioctl_wait is held from ioctl_wr until the SDRAM write of that word is done.
module nost_loader (
    input  logic        clk,
    input  logic        rst,

    input  logic        ioctl_download,
    input  logic [15:0] ioctl_index,
    input  logic        ioctl_wr,
    input  logic [26:0] ioctl_addr,
    input  logic [15:0] ioctl_dout,
    output logic        ioctl_wait,

    output logic        mem_req,
    output logic [25:1] mem_addr,
    output logic [15:0] mem_wdata,
    input  logic        mem_ack,

    output logic        zfix_we,         // Z80 ROM 0000-7FFF copy (block RAM in nost_sound)
    output logic [14:1] zfix_waddr,
    output logic [15:0] zfix_wdata,

    output logic        loaded           // a stream download has completed
);
    typedef enum logic [1:0] {IDLE, W1, W2, W3} st_t;
    st_t st;
    logic [26:0] a;
    logic [15:0] d;

    wire sel = ioctl_download && ioctl_index == 16'd0;
    logic sel_d;

    // 16x16 tile row reorder inside a 128-byte tile (byte offset o, even)
    function automatic [20:0] perm(input [20:0] o);
        logic [1:0] q;
        logic [2:0] row8;
        q    = o[6:5];
        row8 = o[4:2];
        perm = {o[20:7], q[1], row8, q[0], o[1:0]};
    endfunction

    assign ioctl_wait = st != IDLE;

    always_ff @(posedge clk) begin
        zfix_we <= 1'b0;
        sel_d   <= sel;
        if (sel_d && !sel) loaded <= 1'b1;
        if (rst) begin
            st <= IDLE;
            mem_req <= 1'b0;
            loaded <= 1'b0;
        end else case (st)
            IDLE: if (sel && ioctl_wr) begin
                a  <= ioctl_addr;
                d  <= ioctl_dout;
                st <= W1;
            end
            W1: begin
                logic [25:0] b;                       // SDRAM byte address
                if (a < 27'h100000)      b = {6'd0, a[19:0]};
                else if (a < 27'h140000) b = 26'h0100000 + 26'(a - 27'h100000);
                else if (a < 27'h240000) b = 26'h0200000 + 26'(a - 27'h140000);
                else if (a < 27'h3C0000) b = 26'h0400000 + {5'd0, perm(21'(a - 27'h240000))};
                else if (a < 27'h540000) b = 26'h0D00000 + {5'd0, perm(21'(a - 27'h3C0000))};
                else if (a < 27'hA40000) b = 26'h0800000 + 26'(a - 27'h540000);
                else                     b = 26'h0E80000 + {5'd0, perm(21'(a - 27'hA40000))};
                if (a >= 27'h100000 && a < 27'h108000) begin
                    zfix_we    <= 1'b1;
                    zfix_waddr <= a[14:1];
                    zfix_wdata <= d;
                end
                if (a < 27'hB40000) begin
                    mem_addr  <= b[25:1];
                    mem_wdata <= d;
                    mem_req   <= 1'b1;
                    st        <= W2;
                end else
                    st <= IDLE;
            end
            W2: if (mem_ack) begin
                mem_req <= 1'b0;
                st      <= IDLE;
                if (a >= 27'h240000 && a < 27'h540000 || a >= 27'hA40000) begin  // bg copy, Cave 038
                    mem_addr <= (a < 27'h3C0000) ? 25'h800000 + 25'(a[24:1] - 24'h120000) :
                                (a < 27'h540000) ? 25'h900000 + 25'(a[24:1] - 24'h1E0000) :
                                                   25'h9C0000 + 25'(a[24:1] - 24'h520000);
                    st <= W3;
                end
            end
            W3: begin
                if (!mem_req) mem_req <= 1'b1;
                else if (mem_ack) begin
                    mem_req <= 1'b0;
                    st      <= IDLE;
                end
            end
            default: st <= IDLE;
        endcase
    end
endmodule
