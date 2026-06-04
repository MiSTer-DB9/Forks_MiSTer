//Control module for Megadrive DB9 Splitter of Antonio Villena by Aitor Pelaez (NeuroRulez)
//Based on the module written by Victor Trucco and modified by Fernando Mosquera
////////////////////////////////////////////////////////////////////////////////////

module joy_db9md(
    input  clk,
    input  [5:0] joy_in,
    output joy_mdsel,
    output joy_split,
    output [11:0] joystick1,
    output [11:0] joystick2,
    // Protocol-level 6-button pad detect. The internal joy*_6btn regs reset
    // each scan at state 2 and get set at state 5 iff the pad responds with
    // joy_in[3:0]==0 (the documented 6-btn handshake). Sampling them raw
    // from outside catches the ~20 us state-2..5 window where the flag is
    // transiently 0 even when a 6-btn pad is connected. These outputs latch
    // the stable value at state 6 instead so consumers see a clean per-scan
    // (~1.3 ms) flag — no glitch, no sticky bias, automatically clears when
    // a 6-btn pad is unplugged. Default 0 at reset (cold-boot safe).
    output joy1_is_6btn,
    output joy2_is_6btn
);

// Scan length in d7_fall ticks (5.12 us each @ 50 MHz). States 0..6 do the
// active 6-btn probe; the remaining ticks hold joyMDsel high (idle). A real
// 6-button pad only resets its internal cycle counter when SEL/TH is held high
// longer than its internal timeout (~1.624 ms, per MegaDrive SNAC pad_io.sv).
// SCAN_LEN=384 -> ~1.97 ms scan, ~1.93 ms idle, comfortably above that timeout
// so the pad counter resets before every scan and the state-5 handshake read
// (joy_in[3:0]==0) is deterministic. A shorter idle let long-timeout pads drift
// out of phase -> the 6-btn flag flickered scan-to-scan on some controllers.
localparam [8:0] SCAN_LEN = 9'd384;
reg [8:0] state = 9'd0;
reg joy1_6btn = 1'b0, joy2_6btn = 1'b0;
reg joy1_6btn_lat = 1'b0, joy2_6btn_lat = 1'b0;
reg [11:0] joyMDdat1 = 12'hFFF, joyMDdat2 = 12'hFFF;
reg [5:0] joy1_in, joy2_in;
reg joyMDsel, joySEL = 1'b0;
reg joySplit = 1'b1;

// 3-btn MD Start+B -> Mode chord. Synthesizes the missing Mode/Select
// button on a 3-button Megadrive pad. Gated by per-scan classification
// (MD-not-MS AND not 6-button) and debounced; Start and B are consumed
// while active so the game does not see Pause+B alongside Mode.
localparam [7:0] CHORD_DEBOUNCE = 8'd53;  // ~105 ms at ~1.97 ms/scan
reg joy1_md_thisscan = 1'b0, joy2_md_thisscan = 1'b0;
reg [7:0] joy1_chord_cnt = 8'd0, joy2_chord_cnt = 8'd0;
reg joy1_mode_inject = 1'b0, joy2_mode_inject = 1'b0;

// Single-cycle ticks replace the legacy `posedge|negedge delay[N]` derived
// clocks. `delay` free-runs on every clk; the tick conditions fire at the
// same counter values where the original bit-edges occurred:
//   delay[5] 0->1 (was `posedge delay[5]`)  : delay[5:0] == 32
//   delay[5] 1->0 (was `negedge delay[5]`)  : delay[5:0] == 0
//   delay[7] 1->0 (was `negedge delay[7]`)  : delay      == 0
// Bodies execute one clk cycle after the original derived edge — negligible
// vs the /64 (~1.28 us) and /256 (~5.12 us) protocol intervals at 50 MHz.
//
// jotego JTFRAME_SDRAM96 cores clock this module at 96 MHz (clk_sys), not the
// 40-50 MHz baseline. Widening `delay` by one bit there doubles every tick
// period so each d7_fall stays ~5.12 us (512 cyc / 96 MHz = 5.33 us) and the
// SCAN_LEN=384 scan stays ~2 ms > the pad's ~1.624 ms reset timeout. Without
// this the 96 MHz scan collapses to ~0.98 ms and the 6-btn flag flickers.
`ifdef JTFRAME_SDRAM96
reg [8:0] delay = 9'd0;
always @(posedge clk) delay <= delay + 1'd1;
wire d5_rise = (delay[6:0] == 7'd64);
wire d5_fall = (delay[6:0] == 7'd0);
wire d7_fall = (delay      == 9'd0);
`else
reg [7:0] delay = 8'd0;
always @(posedge clk) delay <= delay + 1'd1;
wire d5_rise = (delay[5:0] == 6'd32);
wire d5_fall = (delay[5:0] == 6'd0);
wire d7_fall = (delay      == 8'd0);
`endif

always @(posedge clk) begin
    if (d5_rise) begin
        joySplit <= ~joySplit;
    end

    if (d5_fall) begin
        if (joySplit) begin
            joy2_in <= joy_in;
        end
        else begin
            joy1_in <= joy_in;
        end
    end

    // Joystick Management
    if (d7_fall) begin
        if (state == SCAN_LEN - 1'd1) state <= 9'd0;
        else                          state <= state + 1'd1;
        case (state)        //-- joy_s format MXYZ SACB UDLR
            9'd0: begin
                joyMDsel <= 1'b0;
            end

            9'd1: begin
                joyMDsel <= 1'b1;
            end

            9'd2: begin
                joyMDdat1[5:0] <= joy1_in[5:0]; //-- CBUDLR
                joyMDdat2[5:0] <= joy2_in[5:0]; //-- CBUDLR
                joyMDsel <= 1'b0;
                joy1_6btn <= 1'b0; // -- Assume it's not a six-button controller
                joy2_6btn <= 1'b0; // -- Assume it's not a six-button controller
                joy1_md_thisscan <= 1'b0;
                joy2_md_thisscan <= 1'b0;
            end

            9'd3: begin // Si derecha e Izda es 0 es un mando de megadrive
                if (joy1_in[1:0] == 2'b00) begin
                    joyMDdat1[7:6] <= joy1_in[5:4]; // -- Start, A
                    joy1_md_thisscan <= 1'b1;
                end
                else begin
                    joyMDdat1[7:4] <= { 1'b1, 1'b1, joy1_in[5:4] }; // -- Read A/B as Master System
                end
                if (joy2_in[1:0] == 2'b00) begin
                    joyMDdat2[7:6] <= joy2_in[5:4]; //-- Start, A
                    joy2_md_thisscan <= 1'b1;
                end
                else begin
                    joyMDdat2[7:4] <= { 1'b1, 1'b1, joy2_in[5:4] }; // -- Read A/B as Master System
                end
                joyMDsel <= 1'b1;
            end

            9'd4: begin
                joyMDsel <= 1'b0;
            end

            9'd5: begin
                if (joy1_in[3:0] == 4'b000) begin
                    joy1_6btn <= 1'b1; // -- It's a six button
                end
                if (joy2_in[3:0] == 4'b000) begin
                    joy2_6btn <= 1'b1; // -- It's a six button
                end
                joyMDsel <= 1'b1;
            end

            9'd6: begin
                if (joy1_6btn == 1'b1) begin
                    joyMDdat1[11:8] <= joy1_in[4:0]; // -- Mode, X, Y e Z
                end
                if (joy2_6btn == 1'b1) begin
                    joyMDdat2[11:8] <= joy2_in[4:0]; // -- Mode, X, Y e Z
                end
                // Latch the per-scan 6-btn flag here (after state 5 has set it).
                // Output stays steady from this point until state 6 of the next
                // scan ~1.3 ms later, so external consumers never see the
                // state-2 reset transient.
                joy1_6btn_lat <= joy1_6btn;
                joy2_6btn_lat <= joy2_6btn;
                joyMDsel <= 1'b0;

                // Start (joyMDdat[7]) and B (joyMDdat[4]) are active-low here.
                if (!(joy1_md_thisscan & ~joy1_6btn & ~joyMDdat1[7] & ~joyMDdat1[4])) begin
                    joy1_chord_cnt   <= 8'd0;
                    joy1_mode_inject <= 1'b0;
                end
                else if (joy1_chord_cnt == CHORD_DEBOUNCE) joy1_mode_inject <= 1'b1;
                else                                       joy1_chord_cnt   <= joy1_chord_cnt + 8'd1;

                if (!(joy2_md_thisscan & ~joy2_6btn & ~joyMDdat2[7] & ~joyMDdat2[4])) begin
                    joy2_chord_cnt   <= 8'd0;
                    joy2_mode_inject <= 1'b0;
                end
                else if (joy2_chord_cnt == CHORD_DEBOUNCE) joy2_mode_inject <= 1'b1;
                else                                       joy2_chord_cnt   <= joy2_chord_cnt + 8'd1;
            end

            default: begin
                joyMDsel <= 1'b1;
            end
        endcase
    end
end

//joyMDdat1 and joyMDdat2
//   11 1098 7654 3210
//----Z  YXM SACB UDLR
//SALIDA joystick[11:0]:
//BA9876543210
//MSZYXCBAUDLR
wire [11:0] joy1_raw = ~{ joyMDdat1[8], joyMDdat1[7], joyMDdat1[11:9], joyMDdat1[5:4], joyMDdat1[6], joyMDdat1[3:0] };
wire [11:0] joy2_raw = ~{ joyMDdat2[8], joyMDdat2[7], joyMDdat2[11:9], joyMDdat2[5:4], joyMDdat2[6], joyMDdat2[3:0] };

assign joystick1 = joy1_mode_inject
    ? { 1'b1, 1'b0, joy1_raw[9:6], 1'b0, joy1_raw[4:0] }
    : joy1_raw;
assign joystick2 = joy2_mode_inject
    ? { 1'b1, 1'b0, joy2_raw[9:6], 1'b0, joy2_raw[4:0] }
    : joy2_raw;

assign joy_mdsel = joyMDsel;
assign joy_split = joySplit;

assign joy1_is_6btn = joy1_6btn_lat;
assign joy2_is_6btn = joy2_6btn_lat;

endmodule
