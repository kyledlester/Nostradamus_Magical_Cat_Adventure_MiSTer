// Nostradamus MiSTer core -- 68000 main board.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// MAME 0.289 mcatadv_state::main_map (docs/MEMORY_MAP.md): FX68K at 16 MHz (phi1/phi2 enables).
//   000000-0FFFFF program ROM: SDRAM through a direct-mapped cache (nost_rom_cache)
//   100000-10FFFF work RAM            200000-200005 / 300000-300005 038 #0 / #1 registers
//   400000-401FFF / 500000-501FFF 038 #0 / #1 RAM (tile map 000-FFF, line RAM 1000-17FF, scratch)
//   600000-601FFF palette (xGRB_555)  602000-602FFF RAM
//   700000-707FFF sprite RAM (two halves) 708000-70FFFF RAM
//   800000 P1, 800002 P2, A00000 DSW1, A00002 DSW2 (MAME port values, active low)
//   B00000-B0000F vidregs (buffered at vblank: word 2 = sprite half; words 0/1 live = sprite offsets)
//   B00018 W watchdog reset, B0001E R watchdog reset (returns 0x0C00)
//   C00000 W sound latch (low byte), C00001 R latch 2 (from the Z80)
// IRQ1 at vblank start (MAME irq1_line_hold: pending until the 68000 acknowledges level 1,
// autovectored). Unmapped reads return 0 (MAME unmap value); unmapped writes are ignored.
//
// Watchdog (MAME: 3 s, "a guess, and certainly wrong"): 96,000,000 ticks of the 32 MHz time base
// without a write to B00018 (or read of B0001E) soft-resets the 68000 and the sound board
// (MAME schedule_soft_reset: CPUs and devices reset, RAM kept). The game depends on it: on a cold
// boot it writes 'nost' to 10001C and spins until the watchdog resets it (docs/MAME_REFERENCE.md).
//
// Sprite buffer: at vblank start the half selected by vidregs word 2 (MAME: == 1 -> second half)
// is copied (2048 clocks, 4 words per clock) to the display buffer read by the sprite engine,
// which is MAME's buffered_spriteram16 copy + buffered vidregs restricted to what draw_sprites
// uses. CPU writes to entries of that half not copied yet wait, so the copy is an atomic snapshot.
module nost_main #(
    parameter int WD_TICKS = 96_000_000   // watchdog period in 32 MHz ticks (3.0 s, MAME's guess)
) (
    input  logic        clk,
    input  logic        reset,          // board reset (OSD, download, PLL)
    input  logic        phi1,
    input  logic        phi2,
    input  logic        tick32,         // 32 MHz emulated time base (frozen by pause)

    // program ROM cache line fill (SDRAM, 4 words = 8 bytes, first word = lowest address)
    output logic        rom_req,
    output logic [19:3] rom_line,
    input  logic        rom_ack,
    input  logic [63:0] rom_data,

    input  logic        vblank_evt,     // line 224 start: IRQ1, sprite copy

    input  logic [15:0] p1,
    input  logic [15:0] p2,
    input  logic [15:0] dsw1,
    input  logic [15:0] dsw2,

    output logic  [7:0] snd_latch,
    output logic        snd_latch_wr,
    input  logic  [7:0] latch2,
    output logic        soft_reset,     // watchdog: resets the sound board too

    // video read ports (registered, 1 clk)
    input  logic [11:0] vram0_addr,
    output logic [15:0] vram0_q,
    input  logic [11:0] vram1_addr,
    output logic [15:0] vram1_q,
    input  logic [11:0] pal_addr,
    output logic [15:0] pal_q,
    input  logic [10:0] sbuf_addr,
    output logic [63:0] sbuf_q,         // {word3, word2, word1, word0}
    output logic [47:0] tm0_regs,       // {reg2, reg1, reg0} live
    output logic [47:0] tm1_regs,
    output logic [15:0] spr_gx,         // vidregs word 0 (live)
    output logic [15:0] spr_gy,         // vidregs word 1 (live)
    output logic        spr_copy_busy,

    // debug
    output logic [23:0] dbg_pc,
    output logic [15:0] dbg_irq1,
    output logic [15:0] dbg_frames,
    output logic [15:0] dbg_latch_writes,
    output logic [15:0] dbg_wd_resets,
    output logic [15:0] dbg_rom_misses
);
    // ------------------------------------------------------------------ watchdog / CPU reset
    logic [26:0] wd_cnt;
    logic  [5:0] wd_pulse;
    logic        wd_kick;
    always_ff @(posedge clk) begin
        if (reset) begin
            wd_cnt <= '0;
            wd_pulse <= '0;
            dbg_wd_resets <= '0;
        end else begin
            if (wd_pulse != 0) wd_pulse <= wd_pulse - 6'd1;
            if (wd_kick || wd_pulse != 0) wd_cnt <= '0;
            else if (tick32) begin
                if (wd_cnt == 27'(WD_TICKS - 1)) begin
                    wd_cnt   <= '0;
                    wd_pulse <= 6'd63;
                    dbg_wd_resets <= dbg_wd_resets + 16'd1;
                end else
                    wd_cnt <= wd_cnt + 27'd1;
            end
        end
    end
    assign soft_reset = wd_pulse != 0;
    wire cpu_reset = reset || soft_reset;

    // ------------------------------------------------------------------ CPU
    logic [2:0]  irq_level;
    logic        iack_service, iack_active, vpa_n;
    logic [2:0]  iack_level;
    logic        cpu_req, cpu_write;
    logic [23:0] a;
    logic [15:0] cpu_wdata, cpu_rdata;
    logic [1:0]  cpu_be;
    logic        cpu_ack;
    logic [71:0] dbg_native;

    nost_cpu68k cpu (
        .clk_sys(clk), .reset(cpu_reset), .en_phi1(phi1), .en_phi2(phi2),
        .irq_level(irq_level), .iack_service(iack_service), .iack_level(iack_level),
        .iack_active(iack_active), .vpa_n(vpa_n),
        .cpu_req(cpu_req), .cpu_write(cpu_write), .cpu_addr(a),
        .cpu_wdata(cpu_wdata), .cpu_byte_en(cpu_be), .cpu_rdata(cpu_rdata), .cpu_ack(cpu_ack),
        .debug_native(dbg_native)
    );

    // program fetches (FC = 010 user program / 110 supervisor program) for the debug PC
    wire [2:0] fc = dbg_native[65:63];
    always_ff @(posedge clk)
        if (!dbg_native[57] && fc[1:0] == 2'b10) dbg_pc <= dbg_native[23:0];

    // ------------------------------------------------------------------ decode
    wire sel_rom  = a[23:20] == 4'h0;
    wire sel_ram  = a[23:16] == 8'h10;
    wire sel_tm0  = a[23:3]  == 21'h040000 && a[2:1] != 2'd3;   // 200000-200005
    wire sel_tm1  = a[23:3]  == 21'h060000 && a[2:1] != 2'd3;   // 300000-300005
    wire sel_vr0  = a[23:13] == 11'h200;                        // 400000-401FFF
    wire sel_vr1  = a[23:13] == 11'h280;                        // 500000-501FFF
    wire sel_pal  = a[23:13] == 11'h300;                        // 600000-601FFF
    wire sel_palx = a[23:12] == 12'h602;                        // 602000-602FFF
    wire sel_spr  = a[23:15] == 9'h0E0;                         // 700000-707FFF
    wire sel_sprx = a[23:15] == 9'h0E1;                         // 708000-70FFFF
    wire sel_in   = a[23:2]  == 22'h200000;                     // 800000-800003
    wire sel_dsw  = a[23:2]  == 22'h280000;                     // A00000-A00003
    wire sel_vid  = a[23:4]  == 20'hB0000;                      // B00000-B0000F
    wire sel_wdw  = a[23:1]  == 23'h58000C;                     // B00018
    wire sel_wdr  = a[23:1]  == 23'h58000F;                     // B0001E
    wire sel_snd  = a[23:1]  == 23'h600000;                     // C00000-C00001

    // ------------------------------------------------------------------ memories
    logic        acc_we;                         // one-clock strobe of an accepted write
    wire  [1:0]  we_be = {2{acc_we}} & cpu_be;
    logic [15:0] ram_q, vr0_q, vr1_q, pal_cq, palx_q, sprx_q;

    nost_spram16 #(.AW(15)) ram (
        .clk(clk), .addr(a[15:1]), .we(sel_ram ? we_be : 2'b00), .din(cpu_wdata), .dout(ram_q));
    nost_dpram16 #(.AW(12)) vram0 (
        .clk(clk), .a_addr(a[12:1]), .a_we(sel_vr0 ? we_be : 2'b00), .a_din(cpu_wdata), .a_dout(vr0_q),
        .b_addr(vram0_addr), .b_dout(vram0_q));
    nost_dpram16 #(.AW(12)) vram1 (
        .clk(clk), .a_addr(a[12:1]), .a_we(sel_vr1 ? we_be : 2'b00), .a_din(cpu_wdata), .a_dout(vr1_q),
        .b_addr(vram1_addr), .b_dout(vram1_q));
    nost_dpram16 #(.AW(12)) pal (
        .clk(clk), .a_addr(a[12:1]), .a_we(sel_pal ? we_be : 2'b00), .a_din(cpu_wdata), .a_dout(pal_cq),
        .b_addr(pal_addr), .b_dout(pal_q));
    nost_spram16 #(.AW(11)) palx (
        .clk(clk), .addr(a[11:1]), .we(sel_palx ? we_be : 2'b00), .din(cpu_wdata), .dout(palx_q));
    nost_spram16 #(.AW(14)) sprx (
        .clk(clk), .addr(a[14:1]), .we(sel_sprx ? we_be : 2'b00), .din(cpu_wdata), .dout(sprx_q));

    // sprite RAM: 4 word banks (word index a[2:1]) x 4096 entries {half, entry}; port B = copy
    logic        copying;
    logic        copy_half;
    logic [10:0] copy_entry;
    logic [15:0] spr_w [4];
    logic [15:0] copy_w [4];
    genvar w;
    generate
    for (w = 0; w < 4; w = w + 1) begin : spr_words
        nost_dpram16 #(.AW(12)) bank (
            .clk(clk), .a_addr(a[14:3]), .a_we((sel_spr && a[2:1] == w) ? we_be : 2'b00),
            .a_din(cpu_wdata), .a_dout(spr_w[w]),
            .b_addr({copy_half, copy_entry}), .b_dout(copy_w[w]));
    end
    endgenerate

    // ------------------------------------------------------------------ program ROM cache
    logic        rc_lookup, rc_hit, rc_busy;
    logic [15:0] rc_q;
    nost_rom_cache rcache (
        .clk(clk), .reset(reset),
        .addr(a[19:1]), .lookup(rc_lookup), .hit(rc_hit), .q(rc_q), .busy(rc_busy),
        .mem_req(rom_req), .mem_line(rom_line), .mem_ack(rom_ack), .mem_data(rom_data),
        .misses(dbg_rom_misses));

    // ------------------------------------------------------------------ registers
    logic [15:0] tm0 [3];
    logic [15:0] tm1 [3];
    logic [15:0] vid [8];
    assign tm0_regs = {tm0[2], tm0[1], tm0[0]};
    assign tm1_regs = {tm1[2], tm1[1], tm1[0]};
    assign spr_gx = vid[0];
    assign spr_gy = vid[1];

    function automatic [15:0] merge(input [15:0] old, input [15:0] d, input [1:0] be);
        merge = {be[1] ? d[15:8] : old[15:8], be[0] ? d[7:0] : old[7:0]};
    endfunction

    // ------------------------------------------------------------------ bus backend
    typedef enum logic [2:0] {B_IDLE, B_READ1, B_READ2, B_ROM, B_END} bstate_t;
    bstate_t bst;
    wire  spr_hold = sel_spr && cpu_write &&
                     (vblank_evt || (copying && a[14] == copy_half && a[13:3] >= copy_entry));
    wire  accept = bst == B_IDLE && cpu_req && !spr_hold;
    assign acc_we = accept && cpu_write;
    assign rc_lookup = sel_rom && (bst == B_READ2 || bst == B_ROM);
    assign wd_kick = (acc_we && sel_wdw) || (bst == B_READ2 && sel_wdr);

    always_ff @(posedge clk) begin
        cpu_ack      <= 1'b0;
        snd_latch_wr <= 1'b0;
        if (cpu_reset) bst <= B_IDLE;
        if (reset) begin
            snd_latch <= 8'h00;
            dbg_latch_writes <= '0;
            for (int i = 0; i < 3; i++) begin tm0[i] <= 16'h0000; tm1[i] <= 16'h0000; end
            for (int i = 0; i < 8; i++) vid[i] <= 16'h0000;
        end else if (!cpu_reset) begin
            case (bst)
                B_IDLE: if (accept) begin
                    if (cpu_write) begin
                        if (sel_snd && cpu_be[0]) begin
                            snd_latch    <= cpu_wdata[7:0];
                            snd_latch_wr <= 1'b1;
                            dbg_latch_writes <= dbg_latch_writes + 16'd1;
                        end
                        if (sel_tm0) tm0[a[2:1]] <= merge(tm0[a[2:1]], cpu_wdata, cpu_be);
                        if (sel_tm1) tm1[a[2:1]] <= merge(tm1[a[2:1]], cpu_wdata, cpu_be);
                        if (sel_vid) vid[a[3:1]] <= merge(vid[a[3:1]], cpu_wdata, cpu_be);
                        cpu_ack <= 1'b1;
                        bst <= B_END;
                    end else
                        bst <= B_READ1;
                end
                B_READ1: bst <= B_READ2;
                B_READ2: begin
                    if (sel_rom) begin
                        if (rc_hit) begin                       // hit: same latency as RAM
                            cpu_rdata <= rc_q;
                            cpu_ack   <= 1'b1;
                            bst       <= B_END;
                        end else
                            bst <= B_ROM;
                    end else begin
                        cpu_rdata <= sel_ram  ? ram_q :
                                     sel_vr0  ? vr0_q :
                                     sel_vr1  ? vr1_q :
                                     sel_pal  ? pal_cq :
                                     sel_palx ? palx_q :
                                     sel_spr  ? spr_w[a[2:1]] :
                                     sel_sprx ? sprx_q :
                                     sel_tm0  ? tm0[a[2:1]] :
                                     sel_tm1  ? tm1[a[2:1]] :
                                     (sel_in  && !a[1]) ? p1 :
                                     (sel_in  &&  a[1]) ? p2 :
                                     (sel_dsw && !a[1]) ? dsw1 :
                                     (sel_dsw &&  a[1]) ? dsw2 :
                                     sel_vid  ? vid[a[3:1]] :
                                     sel_wdr  ? 16'h0C00 :
                                     sel_snd  ? {8'h00, latch2} :
                                     16'h0000;                  // unmapped: MAME unmap value 0
                        cpu_ack <= 1'b1;
                        bst <= B_END;
                    end
                end
                B_ROM: if (rc_hit) begin                       // cache lookup result / fill done
                    cpu_rdata <= rc_q;
                    cpu_ack   <= 1'b1;
                    bst       <= B_END;
                end
                B_END: if (!cpu_req) bst <= B_IDLE;
                default: bst <= B_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------ interrupts
    logic pend1;
    always_ff @(posedge clk) begin
        if (cpu_reset) begin
            pend1 <= 1'b0;
        end else begin
            if (iack_service && iack_level == 3'd1) pend1 <= 1'b0;
            if (vblank_evt) pend1 <= 1'b1;
        end
        if (reset) dbg_irq1 <= '0;
        else if (iack_service && iack_level == 3'd1) dbg_irq1 <= dbg_irq1 + 16'd1;
    end
    assign irq_level = pend1 ? 3'd1 : 3'd0;

    // ------------------------------------------------------------------ vblank sprite copy
    logic        rd_valid;
    logic [10:0] rd_entry;
    logic        sbuf_we;
    logic [10:0] sbuf_waddr;
    logic [63:0] sbuf_wdata;

    assign spr_copy_busy = copying || vblank_evt;

    always_ff @(posedge clk) begin
        sbuf_we <= 1'b0;
        if (reset) begin
            copying <= 1'b0; copy_entry <= '0; copy_half <= 1'b0; rd_valid <= 1'b0;
            dbg_frames <= '0;
        end else begin
            if (vblank_evt && !copying) begin
                copying    <= 1'b1;
                copy_entry <= '0;
                copy_half  <= vid[2] == 16'h0001;
                rd_valid   <= 1'b0;
                dbg_frames <= dbg_frames + 16'd1;
            end else if (copying) begin
                // entry copy_entry is read this clock; its words arrive next clock
                rd_valid <= 1'b1;
                rd_entry <= copy_entry;
                if (copy_entry != 11'd2047) copy_entry <= copy_entry + 11'd1;
                if (rd_valid) begin
                    sbuf_we    <= 1'b1;
                    sbuf_waddr <= rd_entry;
                    sbuf_wdata <= {copy_w[3], copy_w[2], copy_w[1], copy_w[0]};
                    if (rd_entry == 11'd2047) begin
                        copying  <= 1'b0;
                        rd_valid <= 1'b0;
                    end
                end
            end
        end
    end

    nost_sdpram #(.AW(11), .DW(64)) sbuf (
        .clk(clk), .w_addr(sbuf_waddr), .we(sbuf_we), .din(sbuf_wdata), .r_addr(sbuf_addr), .dout(sbuf_q));
endmodule
