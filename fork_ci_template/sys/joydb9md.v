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

reg [7:0]state = 8'd0;
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
localparam [7:0] CHORD_DEBOUNCE = 8'd80;  // ~105 ms at ~1.31 ms/scan
reg joy1_md_thisscan = 1'b0, joy2_md_thisscan = 1'b0;
reg [7:0] joy1_chord_cnt = 8'd0, joy2_chord_cnt = 8'd0;
reg joy1_mode_inject = 1'b0, joy2_mode_inject = 1'b0;

reg [7:0] delay = 8'd0;

always @(posedge clk) begin
    delay <= delay + 1'd1;
end

// Single-cycle ticks replace the legacy `posedge|negedge delay[N]` derived
// clocks. `delay` cycles 0..255 on every clk; the tick conditions fire at the
// same counter values where the original bit-edges occurred:
//   delay[5] 0->1 (was `posedge delay[5]`)  : delay[5:0] == 32
//   delay[5] 1->0 (was `negedge delay[5]`)  : delay[5:0] == 0
//   delay[7] 1->0 (was `negedge delay[7]`)  : delay      == 0
// Bodies execute one clk cycle after the original derived edge — negligible
// vs the /64 (~1.28 us) and /256 (~5.12 us) protocol intervals at 50 MHz.
wire d5_rise = (delay[5:0] == 6'd32);
wire d5_fall = (delay[5:0] == 6'd0);
wire d7_fall = (delay      == 8'd0);

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
        state <= state + 1;
        case (state)        //-- joy_s format MXYZ SACB UDLR
            8'd0: begin
                joyMDsel <= 1'b0;
            end

            8'd1: begin
                joyMDsel <= 1'b1;
            end

            8'd2: begin
                joyMDdat1[5:0] <= joy1_in[5:0]; //-- CBUDLR
                joyMDdat2[5:0] <= joy2_in[5:0]; //-- CBUDLR
                joyMDsel <= 1'b0;
                joy1_6btn <= 1'b0; // -- Assume it's not a six-button controller
                joy2_6btn <= 1'b0; // -- Assume it's not a six-button controller
                joy1_md_thisscan <= 1'b0;
                joy2_md_thisscan <= 1'b0;
            end

            8'd3: begin // Si derecha e Izda es 0 es un mando de megadrive
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

            8'd4: begin
                joyMDsel <= 1'b0;
            end

            8'd5: begin
                if (joy1_in[3:0] == 4'b000) begin
                    joy1_6btn <= 1'b1; // -- It's a six button
                end
                if (joy2_in[3:0] == 4'b000) begin
                    joy2_6btn <= 1'b1; // -- It's a six button
                end
                joyMDsel <= 1'b1;
            end

            8'd6: begin
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
