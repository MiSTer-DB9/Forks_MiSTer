// Control module for Saturn DB9 Splitter of Antonio Villena by Timothy Redaelli
// Based on joydb9md.v by Aitor Pelaez (NeuroRulez), adapted for the Saturn 4-phase protocol.
//
// Polls up to two standard Saturn digital pads through the S0/S1 select lines.
//
// joy_in is ordered as {D3,D2,D1,D0}.
// On the MiSTer-DB9 Saturn adapter this maps to {USER_IN[3],USER_IN[5],USER_IN[0],USER_IN[1]}.
// The select lines are expected on USER_IO[4] and USER_IO[6].
// 2P hardware uses USER_IO[2] for split-select.
//
// The data nibble mapping follows the Saturn core's own PAD_DIGITAL path:
//   00 -> JOY[7:4]
//   01 -> JOY[15:12]
//   10 -> JOY[11:8]
//   11 -> {JOY[3],3'b100}
//
// Connection is detected by computing the 4-bit pad ID (same formula as SMPC
// PS_ID1_4) from the 4-phase probe and accepting:
//   MD_ID == 4'hB -> standard 6-button digital pad (full button data extracted)
//   MD_ID == 4'h5 -> 3D Control Pad in analog mode (detection only; digital
//                    button data lives in the analog response, retrievable
//                    via the SMPC ID5/ANALOG handshake - use SNAC mode for
//                    actual 3D Control Pad gameplay)
// A 4-bit shift-register provides debounce: connect on 1 hit, disconnect
// after 4 consecutive misses.
// joystick format is active-high and keeps the common DB9 layout aligned:
//   [15:14] unused
//   [13]    Unused
//   [12]    L
//   [11]    R (Mode/Select position; Saturn pad has no native Mode/Select,
//             so R is exposed here so cores reading [11] as Mode/Select get
//             a working Saturn button)
//   [10]    Start
//   [9]     Z
//   [8]     Y
//   [7]     X
//   [6]     C
//   [5]     B
//   [4]     A
//   [3]     Up
//   [2]     Down
//   [1]     Left
//   [0]     Right

module joy_db9saturn (
  input         clk,
  input   [3:0] joy_in,
  output        joy_s0,
  output        joy_s1,
  output        joy_split,
  output        joy_p1_valid,
  output        joy_p2_valid,
  output [15:0] joystick1,
  output [15:0] joystick2
  );

// Each phase step is ~5.12us at 50MHz. SET->WAIT->GET gives ~10.24us
// between a line change and the sample, which matches the Saturn core's
// SMPC PORT_DELAY of 41-42 ticks at 4MHz (~10.25-10.50us).
reg [7:0] delay = 8'd0;
always @(posedge clk) delay <= delay + 1'd1;

// Single-cycle tick equivalent to the legacy `negedge delay[7]` derived
// clock — fires the cycle delay[7] would have transitioned 1->0, i.e. when
// the counter wraps to 0. Body executes one clk cycle after the original
// derived edge (~20 ns at 50 MHz, vs the ~5.12 us phase step).
wire d7_fall = (delay == 8'd0);

localparam [3:0]  PAD_ID_DIGITAL = 4'hB;  // standard 6-button Saturn pad
localparam [3:0]  PAD_ID_ANALOG  = 4'h5;  // 3D Control Pad in analog switch position
localparam [13:0] IDLE_DATA      = 14'h3FFF;
localparam [15:0] JOY_NONE       = 16'h0000;

localparam [3:0]
  SEL     = 4'd0,
  SPLITW  = 4'd1,
  SET_00  = 4'd2,
  WAIT_00 = 4'd3,
  GET_00  = 4'd4,
  SET_10  = 4'd5,
  WAIT_10 = 4'd6,
  GET_10  = 4'd7,
  SET_01  = 4'd8,
  WAIT_01 = 4'd9,
  GET_01  = 4'd10,
  SET_11  = 4'd11,
  WAIT_11 = 4'd12,
  GET_11  = 4'd13;

reg [3:0] phase    = SEL;
reg       cur_port = 1'b0;  // 0 = P1, 1 = P2; also drives joy_split

reg [13:0] joySatScan  = IDLE_DATA;
reg [13:0] joySatDat   [0:1];
reg        joySatValid [0:1];
reg [3:0]  joySatSr    [0:1];

initial begin
  joySatDat[0]   = IDLE_DATA;
  joySatDat[1]   = IDLE_DATA;
  joySatValid[0] = 1'b0;
  joySatValid[1] = 1'b0;
  joySatSr[0]    = 4'h0;
  joySatSr[1]    = 4'h0;
end

reg joyS0    = 1'b0;
reg joyS1    = 1'b0;
reg joySplit = 1'b0;

// MD_ID formula (same as SMPC PS_ID1_4): at GET_11 joy_in holds the {1,1}
// sample and joySatScan[0..3] holds the {0,1} sample latched at GET_01.
wire [3:0] md_id = {joy_in[3] | joy_in[2], joy_in[1] | joy_in[0],
                    joySatScan[0] | joySatScan[1], joySatScan[2] | joySatScan[3]};
wire       pad_ok      = (md_id == PAD_ID_DIGITAL) | (md_id == PAD_ID_ANALOG);
// Pre-shift SR[2:0] covers the 3 samples before the current one; combined
// with the new 0 about to be shifted in, this requires 4 consecutive misses.
wire       pad_dropped = ~pad_ok & ~|joySatSr[cur_port][2:0] & joySatValid[cur_port];

always @(posedge clk) if (d7_fall) begin
  case (phase)
    SEL: begin
      joySplit   <= cur_port;
      joySatScan <= IDLE_DATA;
      phase <= SPLITW;
    end

    SPLITW: phase <= SET_00;

    SET_00: begin joyS0 <= 1'b0; joyS1 <= 1'b0; phase <= WAIT_00; end
    WAIT_00: phase <= GET_00;
    GET_00: begin
      joySatScan[13] <= joy_in[3];
      joySatScan[7]  <= joy_in[2];
      joySatScan[8]  <= joy_in[1];
      joySatScan[9]  <= joy_in[0];
      phase <= SET_10;
    end

    SET_10: begin joyS0 <= 1'b1; joyS1 <= 1'b0; phase <= WAIT_10; end
    WAIT_10: phase <= GET_10;
    GET_10: begin
      joySatScan[10] <= joy_in[3];
      joySatScan[4]  <= joy_in[2];
      joySatScan[6]  <= joy_in[1];
      joySatScan[5]  <= joy_in[0];
      phase <= SET_01;
    end

    SET_01: begin joyS0 <= 1'b0; joyS1 <= 1'b1; phase <= WAIT_01; end
    WAIT_01: phase <= GET_01;
    GET_01: begin
      joySatScan[0] <= joy_in[3];
      joySatScan[1] <= joy_in[2];
      joySatScan[2] <= joy_in[1];
      joySatScan[3] <= joy_in[0];
      phase <= SET_11;
    end

    SET_11: begin joyS0 <= 1'b1; joyS1 <= 1'b1; phase <= WAIT_11; end
    WAIT_11: phase <= GET_11;
    GET_11: begin
      joySatSr[cur_port] <= {joySatSr[cur_port][2:0], pad_ok};
      if (md_id == PAD_ID_DIGITAL) begin
        // R (joySatScan[13], latched at GET_00) is moved to bit [11] so it
        // lands on the canonical Mode/Select slot. Bit [13] stays idle-high
        // (1'b1) so the active-low → active-high inversion at the output
        // produces 0 there. L (joy_in[3] read live at GET_11) stays at [12].
        joySatDat[cur_port]   <= {1'b1, joy_in[3], joySatScan[13], joySatScan[10:0]};
        joySatValid[cur_port] <= 1'b1;
      end
      else if (md_id == PAD_ID_ANALOG) begin
        // 3D Control Pad in analog mode: digital button data requires the
        // SMPC ID5/ANALOG serial handshake which this 4-phase helper cannot
        // perform. Flag pad-present so Menu_MiSTer autodetect recognizes
        // Saturn and keep any previously-latched data; use SNAC mode
        // (status[27]) for real 3D Pad gameplay with full analog.
        joySatValid[cur_port] <= 1'b1;
      end
      else if (pad_dropped) begin
        joySatDat[cur_port]   <= IDLE_DATA;
        joySatValid[cur_port] <= 1'b0;
      end
      cur_port <= ~cur_port;
      phase    <= SEL;
    end

    default: begin
      joyS0 <= 1'b0;
      joyS1 <= 1'b0;
      phase <= SEL;
    end
  endcase
end

assign joystick1    = joySatValid[0] ? {2'b00, ~joySatDat[0]} : JOY_NONE;
assign joystick2    = joySatValid[1] ? {2'b00, ~joySatDat[1]} : JOY_NONE;
assign joy_s0       = joyS0;
assign joy_s1       = joyS1;
assign joy_split    = joySplit;
assign joy_p1_valid = joySatValid[0];
assign joy_p2_valid = joySatValid[1];

endmodule
