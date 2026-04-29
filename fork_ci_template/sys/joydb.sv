// MiSTer-DB9 unified joystick wrapper.
//
// Absorbs the per-core DB9MD / DB15 / Saturn boilerplate that previously
// lived in every <core>.sv as ~80 lines of byte-identical Verilog. Drop in
// one instance per core; expose status-bit-derived joy_type / joy_2p /
// saturn_unlocked, and consume the unified joydb_1 / joydb_2 / *_ena /
// USER_OUT_DRIVE / USER_PP_DRIVE / USER_OSD / joy_raw outputs.
//
// joy_type encoding (Saturn-first to avoid OSD-cycle ghost inputs):
//   2'd0 = Off, 2'd1 = Saturn, 2'd2 = DB9MD, 2'd3 = DB15.
//
// USER_PP_DRIVE encodes per-pin push-pull as a single 8-bit mask:
//   DB15   -> 8'b00000011 (LOAD pin 0, CLK pin 1)
//   DB9MD  -> 8'b00010001 (SELECT pin 0, TH pin 4)
//   Saturn -> 8'b01010100 (SPLIT pin 2, S0 pin 4, S1 pin 6)
//   Off    -> 8'b00000000 (all open-drain)
// This subsumes the legacy USER_MODE[1:0] signal (which only encoded the
// 3-pin DB9MD/DB15 push-pull mask via hard-coded sys_top.v ternaries).
//
// Key gating: the Saturn arm of joydb_1 / joydb_2 is AND-gated with
// saturn_unlocked inside this module so a per-core port cannot forget the
// gate.
// Tie saturn_unlocked = 1'b0 in cores whose hps_io.sv does not yet expose
// it; the module degrades cleanly to DB9MD/DB15-only behavior.
//
// This file is fork-only (does not exist upstream), so it is implicitly
// MiSTer-DB9. Only [MiSTer-DB9-Pro BEGIN/END] markers appear, to flag the
// Key-gated sections (Saturn arms in the joystick mux). USER_PP_DRIVE is
// always-free baseline now since DB9MD/DB15 also flow through it; only the
// Saturn-specific 8'b01010100 term in the mask is gated by saturn_unlocked
// at the joydb_1/joydb_2 mux above.

module joydb
(
    input  logic        clk,            // CLK_JOY (40-50 MHz)
    input  logic [7:0]  USER_IN,

    input  logic [1:0]  joy_type,
    input  logic        joy_2p,
    // [MiSTer-DB9-Pro BEGIN] - Saturn key gate input
    input  logic        saturn_unlocked,
    // [MiSTer-DB9-Pro END]

    output logic [7:0]  USER_OUT_DRIVE,
    output logic [7:0]  USER_PP_DRIVE,
    output logic        USER_OSD,

    output logic [15:0] joydb_1,
    output logic [15:0] joydb_2,
    output logic        joydb_1ena,
    output logic        joydb_2ena,

    // joy_raw payload (caller wraps with OSD_STATUS guard at hps_io site)
    output logic [15:0] joy_raw
);

// Mode decode
wire joy_db9md_en  = (joy_type == 2'd2);
wire joy_db15_en   = (joy_type == 2'd3);
wire joy_any_en    = |joy_type;
// [MiSTer-DB9-Pro BEGIN] - Saturn mode decode
wire joy_saturn_en = (joy_type == 2'd1);
// [MiSTer-DB9-Pro END]

// Pin remap (hardware-fixed)
wire [5:0] JOY_MDIN = joy_db9md_en ? {USER_IN[6],USER_IN[3],USER_IN[5],USER_IN[7],USER_IN[1],USER_IN[2]} : '1;
wire       JOY_DATA = joy_db15_en  ? USER_IN[5] : 1'b1;
// [MiSTer-DB9-Pro BEGIN] - Saturn pin remap
wire [3:0] JOY_SATURN_IN = joy_saturn_en ? {USER_IN[3],USER_IN[5],USER_IN[0],USER_IN[1]} : '1;
// [MiSTer-DB9-Pro END]

// DB9MD instance
//----BA 9876543210
//----MS ZYXCBAUDLR
wire        JOY_MDSEL, JOY_SPLIT;
wire [11:0] JOYDB9MD_1_raw, JOYDB9MD_2_raw;
joy_db9md joy_db9md_i (
    .clk       ( clk            ),
    .joy_split ( JOY_SPLIT      ),
    .joy_mdsel ( JOY_MDSEL      ),
    .joy_in    ( JOY_MDIN       ),
    .joystick1 ( JOYDB9MD_1_raw ),
    .joystick2 ( JOYDB9MD_2_raw )
);
wire [15:0] JOYDB9MD_1 = {4'b0, JOYDB9MD_1_raw};
wire [15:0] JOYDB9MD_2 = {4'b0, JOYDB9MD_2_raw};

// DB15 instance
//----BA 9876543210
//----LS FEDCBAUDLR
wire        JOY_CLK, JOY_LOAD;
wire [15:0] JOYDB15_1, JOYDB15_2;
joy_db15 joy_db15_i (
    .clk       ( clk       ),
    .JOY_CLK   ( JOY_CLK   ),
    .JOY_DATA  ( JOY_DATA  ),
    .JOY_LOAD  ( JOY_LOAD  ),
    .joystick1 ( JOYDB15_1 ),
    .joystick2 ( JOYDB15_2 )
);

// [MiSTer-DB9-Pro BEGIN] - Saturn helper instance
//----CBA 9876543210
//----L-S ZYXCBAUDLR  (L_trigger at [12]; R is mapped to bit [11] so cores
//                    reading [11] as Mode/Select get a working Saturn button)
wire        JOY_SAT_S0, JOY_SAT_S1, JOY_SAT_SPLIT;
wire        JOYDBSATURN_1_VALID, JOYDBSATURN_2_VALID;
wire [15:0] JOYDBSATURN_1, JOYDBSATURN_2;
joy_db9saturn joy_db9saturn_i (
    .clk          ( clk                  ),
    .joy_in       ( JOY_SATURN_IN        ),
    .joy_s0       ( JOY_SAT_S0           ),
    .joy_s1       ( JOY_SAT_S1           ),
    .joy_split    ( JOY_SAT_SPLIT        ),
    .joy_p1_valid ( JOYDBSATURN_1_VALID  ),
    .joy_p2_valid ( JOYDBSATURN_2_VALID  ),
    .joystick1    ( JOYDBSATURN_1        ),
    .joystick2    ( JOYDBSATURN_2        )
);

// 1P routing: prefer P1, fall back to P2 if only P2 is connected.
wire [15:0] JOYDBSATURN_SINGLE = JOYDBSATURN_1_VALID ? JOYDBSATURN_1
                               : JOYDBSATURN_2_VALID ? JOYDBSATURN_2
                                                     : 16'h0000;
// [MiSTer-DB9-Pro END]

// Unified joystick mux.
// [MiSTer-DB9-Pro BEGIN] - Saturn arm AND-gated with saturn_unlocked
assign joydb_1 = (joy_saturn_en & saturn_unlocked) ? (joy_2p ? JOYDBSATURN_1 : JOYDBSATURN_SINGLE)
               : joy_db9md_en  ? JOYDB9MD_1
               : joy_db15_en   ? JOYDB15_1
               :                 16'h0000;
assign joydb_2 = (joy_saturn_en & saturn_unlocked) ? JOYDBSATURN_2
               : joy_db9md_en  ? JOYDB9MD_2
               : joy_db15_en   ? JOYDB15_2
               :                 16'h0000;
// [MiSTer-DB9-Pro END]
assign joydb_1ena = joy_any_en;
assign joydb_2ena = joy_any_en & joy_2p;

assign USER_OSD  = joydb_1[10] & joydb_1[6];  // Start+C opens OSD

// USER_PP_DRIVE: per-pin push-pull mask. Saturn term is the only gated bit
// pattern (S0/S1/SPLIT on IO[6]/IO[4]/IO[2]) — gating happens here via
// joy_saturn_en, which itself is held false unless the user selects Saturn.
// DB9MD pushes pins 0 (SELECT) and 4 (TH); DB15 pushes pins 0 (LOAD) and 1 (CLK).
assign USER_PP_DRIVE = joy_saturn_en ? 8'b01010100
                     : joy_db9md_en  ? 8'b00010001
                     : joy_db15_en   ? 8'b00000011
                     :                 8'b00000000;

// USER_OUT pre-composed pattern. Cores compose with MT32 fallback if applicable:
//   assign USER_OUT = mt32_use ? mt32_drive : USER_OUT_DRIVE;
// Hardware wiring: USER_OUT[2]=split-select, USER_OUT[4]=S0, USER_OUT[6]=S1.
// [MiSTer-DB9-Pro BEGIN] - Saturn arm prepended (DB9-only baseline had no Saturn arm)
assign USER_OUT_DRIVE = joy_saturn_en ? {1'b1,JOY_SAT_S1,1'b1,JOY_SAT_S0,1'b1,JOY_SAT_SPLIT,2'b11}
                      : joy_db9md_en  ? {3'b111,JOY_SPLIT,3'b111,JOY_MDSEL}
                      : joy_db15_en   ? {6'b111111,JOY_CLK,JOY_LOAD}
                      :                 8'hFF;
// [MiSTer-DB9-Pro END]

// joy_raw payload: {joy_type, joydb_1[13:0] | joydb_2[13:0]}
// joy_type itself encodes Saturn-vs-DB9MD-vs-DB15, so the [15:14] field
// always matches the user's selection — no separate Pro AND-gate needed
// here (the data path is already gated above at joydb_1/joydb_2).
assign joy_raw = {joy_type, joydb_1[13:0] | joydb_2[13:0]};

endmodule
