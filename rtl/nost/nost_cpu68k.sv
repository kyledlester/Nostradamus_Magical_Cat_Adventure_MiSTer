// Nostradamus MiSTer core (via the owner's R-Shark core). Copied from the owner's Namco NA-1/NA-2 core (rtl/na1/na1_cpu.sv, GPL-3.0-or-later).
// FX68K wrapper with standard IPL/autovector transport; no CPU internals changed.
module nost_cpu68k(
`ifdef NOST_PERF_DEBUG
    output wire perf_s4_wait, output wire perf_uadvance,
`endif
`ifdef NOST_SYNC_DEBUG
    output wire [2:0] sync_cpu_ipl,
`endif
    input wire clk_sys, input wire reset,
    input wire en_phi1, input wire en_phi2,
    input wire [2:0] irq_level,
    output wire iack_service, output wire [2:0] iack_level,
    output wire iack_active, output wire vpa_n,
    output wire cpu_req, output wire cpu_write, output wire [23:0] cpu_addr,
    output wire [15:0] cpu_wdata, output wire [1:0] cpu_byte_en,
    input wire [15:0] cpu_rdata, input wire cpu_ack,
    output wire [71:0] debug_native
);
    wire [23:1] address;
    wire [15:0] data_out,data_in;
    wire as_n,uds_n,lds_n,rw,dtack_n,bus_active,pending;
    wire [2:0] fc;
    wire halted_n,reset_out_n;
    wire [2:0] ipl_n=reset ? 3'b111 : ~irq_level;
    fx68k cpu(.clk(clk_sys), .extReset(reset), .pwrUp(reset),
`ifdef NOST_PERF_DEBUG
        .perf_s4_wait(perf_s4_wait),.perf_uadvance(perf_uadvance),
`endif
`ifdef NOST_SYNC_DEBUG
        .sync_cpu_ipl(sync_cpu_ipl),
`endif
        .enPhi1(en_phi1),.enPhi2(en_phi2),.HALTn(1'b1),
        .eRWn(rw),.ASn(as_n),.UDSn(uds_n),.LDSn(lds_n),
        .iEdb(data_in),.oEdb(data_out),.eab(address),.DTACKn(dtack_n),
        .VPAn(vpa_n),.BERRn(1'b1),.BRn(1'b1),.BGACKn(1'b1),
        .IPL0n(ipl_n[0]),.IPL1n(ipl_n[1]),.IPL2n(ipl_n[2]),
        .FC0(fc[0]),.FC1(fc[1]),.FC2(fc[2]),
        .oHALTEDn(halted_n),.oRESETn(reset_out_n),.BGn(),.E(),.VMAn());
    nost_cpu_bus bus(.clk_sys(clk_sys),.reset(reset),.address(address),
        .data_out(data_out),.data_in(data_in),.fc(fc),.vpa_n(vpa_n),
        .iack_active(iack_active),.iack_service(iack_service),.iack_level(iack_level),.as_n(as_n),.uds_n(uds_n),
        .lds_n(lds_n),.rw(rw),.dtack_n(dtack_n),.bus_active(bus_active),
        .pending(pending),.cpu_req(cpu_req),.cpu_write(cpu_write),
        .cpu_addr(cpu_addr),.cpu_wdata(cpu_wdata),.cpu_byte_en(cpu_byte_en),
        .cpu_rdata(cpu_rdata),.cpu_ack(cpu_ack));
    // [23:0] native address (A0=0); [39:24] output; [55:40] input;
    // [56] R/W; [57] ASn; [58] UDSn; [59] LDSn; [60] DTACKn;
    // [61] active; [62] pending; [65:63] FC; [66] halted_n;
    // [67] RESET instruction output; [68] reset; [69/70] phi1/phi2; [71] IACK.
    assign debug_native={iack_active,en_phi2,en_phi1,reset,reset_out_n,halted_n,
        fc,pending,bus_active,dtack_n,lds_n,uds_n,as_n,rw,
        data_in,data_out,address,1'b0};
endmodule
