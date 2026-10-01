// Nostradamus MiSTer core (via the owner's R-Shark core). Copied from the owner's Namco NA-1/NA-2 core (rtl/na1/na1_cpu_bus.sv, GPL-3.0-or-later).
// Native 68000 strobes to held-request transport. No address mapping here.
// Backend completion is sampled into registers: no combinational DTACK loop.
module nost_cpu_bus(
    input wire clk_sys, input wire reset,
    input wire [23:1] address, input wire [15:0] data_out,
    input wire as_n, input wire uds_n, input wire lds_n, input wire rw,
    input wire [2:0] fc, output wire vpa_n,
    output reg iack_service, output reg [2:0] iack_level, output wire iack_active,
    output wire dtack_n, output reg [15:0] data_in,
    output wire cpu_req, output reg cpu_write, output reg [23:0] cpu_addr,
    output reg [15:0] cpu_wdata, output reg [1:0] cpu_byte_en,
    input wire [15:0] cpu_rdata, input wire cpu_ack,
    output wire bus_active, output wire pending
);
    localparam IDLE=2'd0, WAIT_ACK=2'd1, WAIT_END=2'd2, GAP=2'd3;
    reg [1:0] state;
    reg request, completion_n;
    wire native_iack = !as_n && fc==3'b111;
    reg serving_iack;
    wire transfer = !as_n && (!uds_n || !lds_n) && !native_iack;
    assign iack_active = !reset && serving_iack && native_iack;
    assign vpa_n = !(iack_active && native_iack);
    // AS/FC qualifies IACK independently of data strobes. VPA, never DTACK,
    // selects FX68K autovector/E-clock completion. One service pulse per AS.
    always @(posedge clk_sys or posedge reset) begin
        if(reset) begin serving_iack<=0;iack_service<=0;iack_level<=0;end
        else begin
            iack_service<=0;
            if(!native_iack) serving_iack<=0;
            else if(!serving_iack) begin
                serving_iack<=1;iack_level<=address[3:1];iack_service<=1;
            end
        end
    end
    assign bus_active = transfer && !reset;
    assign pending = !reset && (state==WAIT_ACK || state==WAIT_END);
    // Setup-timing fix: `request` is only ever raised by a `transfer`, which
    // already excludes interrupt-acknowledge cycles, and it drops as soon as AS
    // rises, before the CPU can start an IACK cycle (FC only changes at the
    // start of a bus cycle). The old `&& !native_iack` term was therefore
    // redundant, and it put the FX68K's AS/FC outputs combinationally in front
    // of every downstream request decoder (rAS -> SDRAM arbiter, DMA, video
    // RAM: the -2.3 ns paths).
    assign cpu_req = request && !reset;
    assign dtack_n = reset || native_iack ? 1'b1 : completion_n;
    always @(posedge clk_sys or posedge reset) begin
        if (reset) begin
            state<=IDLE; request<=0; completion_n<=1; data_in<=0;
            cpu_addr<=0;cpu_write<=0;cpu_wdata<=0;cpu_byte_en<=0;
        end else case (state)
            IDLE: if (transfer) begin
                cpu_addr<={address,1'b0};cpu_write<=!rw;
                cpu_wdata<=data_out;cpu_byte_en<={!uds_n,!lds_n};
                request<=1;state<=WAIT_ACK;
            end
            WAIT_ACK: begin
                if (!transfer) begin
                    request<=0;completion_n<=1;state<=GAP;
                end else if (cpu_ack) begin
                    data_in<=cpu_rdata;completion_n<=0;state<=WAIT_END;
                end
            end
            // End on strobes, not just AS: TAS keeps AS low between phases.
            WAIT_END: if (!transfer) begin
                request<=0;completion_n<=1;state<=GAP;
            end
            // Guarantees >=1 clk_sys edge with request low for backend rearming.
            GAP: state<=IDLE;
            default: begin state<=IDLE;request<=0;completion_n<=1;end
        endcase
    end
endmodule
