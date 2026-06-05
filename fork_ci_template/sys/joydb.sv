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
// OSD-open autodetect probe: while OSD_STATUS is high, runs the same
// idle → settle → probe → active FSM as Menu_MiSTer (battle-tested in the
// boot core). Hot-swap of USERIO gamepads mid-OSD re-routes joydb_1 /
// joy_raw to the new pad WITHOUT requiring USB/keyboard fallback —
// db9md_absent_cnt drops db9md_ena ~10 ms after the MD-pad signature
// vanishes, db15_disable masks DB15 ghost outputs on all-low pin states,
// db15_arm_delay_cnt cools down DB9MD re-detection across the swap window.
// Suppressed when snac_active or mt32_primary_active drives USER_IO
// externally.
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

    // Quartus 17.0.2 Standard rejects SV port defaults (LRM 23.2.2.4, Err 10231),
    // so each <core>.sv must bind these explicitly (porter installs 1'b0 defaults).
    input  logic        OSD_STATUS,
    input  logic        snac_active,
    input  logic        mt32_primary_active,

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

    // Per-player 6-button pad detect (unified across modes):
    //   Saturn pads are always 6-btn-shaped -> 1 whenever joy_saturn_en.
    //   DB9MD pads are 3- or 6-btn -> tracks joy_db9md_i's protocol-level
    //   handshake (joy*_is_6btn, latched at state 6).
    //   DB15 has no top/bottom row geometry -> 0 (consumers that needed a
    //   row swap for DB15 should not do it).
    // Consumers like jtcps1's row swap for SF2 use this to disable the
    // swap on a 3-btn pad so A/B/C still hit button 0..2 in 2-3 button
    // games (ffight, captcomm, ...).
    output logic        pad_1_6btn,
    output logic        pad_2_6btn,

    // joy_raw payload (caller wraps with OSD_STATUS guard at hps_io site)
    output logic [15:0] joy_raw
);

wire probe_active = OSD_STATUS & ~snac_active & ~mt32_primary_active;

wire joy_db9md_en  = (joy_type == 2'd2);
wire joy_db15_en   = (joy_type == 2'd3);
wire joy_any_en    = |joy_type;
// [MiSTer-DB9-Pro BEGIN] - Saturn mode decode
wire joy_saturn_en = (joy_type == 2'd1);
// [MiSTer-DB9-Pro END]

// ---- Menu_MiSTer-port autodetect FSM state (active only when probe_active=1) ----
// States: idle (db15-active waiting on db15_idle) → settle (~10 ms float for
// IO[0]/IO[1] recovery) → probe (~5 ms Saturn drive) → active (Saturn confirmed,
// continuous drive). On ~probe_active the whole FSM is held in reset and the
// user-mode joy_type-driven muxes below take over.
reg saturn_active = 1'b0;
reg saturn_probe  = 1'b1;  // boot / OSD-open: first frame is probe
reg saturn_settle = 1'b0;
reg db15_disable  = 1'b0;
reg db9md_ena     = 1'b0;
reg db9_any_ena   = 1'b0;

wire saturn_mode = saturn_active | saturn_probe;
wire saturn_any  = saturn_mode | saturn_settle;

// Probe-mode pin gating mirrors Menu_MiSTer:
// JOY_MDIN reads only during ~saturn_any with DB9MD latched;
// JOY_DATA reads only during ~saturn_any with DB9MD not latched;
// JOY_SATURN_IN reads whenever saturn_mode high (probe / active drive).
wire use_db9md_in  = probe_active ? (~saturn_any & db9md_ena)  : joy_db9md_en;
wire use_db15_in   = probe_active ? (~saturn_any & ~db9md_ena) : joy_db15_en;
wire use_saturn_in = probe_active ? saturn_mode                : (joy_saturn_en & saturn_unlocked);

// Pin remap (hardware-fixed)
wire [5:0] JOY_MDIN      = use_db9md_in  ? {USER_IN[6],USER_IN[3],USER_IN[5],USER_IN[7],USER_IN[1],USER_IN[2]} : '1;
wire       JOY_DATA      = use_db15_in   ? USER_IN[5] : 1'b1;
// [MiSTer-DB9-Pro BEGIN] - Saturn pin remap
wire [3:0] JOY_SATURN_IN = use_saturn_in ? {USER_IN[3],USER_IN[5],USER_IN[0],USER_IN[1]} : '1;
// [MiSTer-DB9-Pro END]

//----BA 9876543210
//----MS ZYXCBAUDLR
wire        JOY_MDSEL, JOY_SPLIT;
wire [11:0] JOYDB9MD_1_raw, JOYDB9MD_2_raw;
wire        JOYDB9MD_1_6btn, JOYDB9MD_2_6btn;
joy_db9md joy_db9md_i (
    .clk          ( clk             ),
    .joy_split    ( JOY_SPLIT       ),
    .joy_mdsel    ( JOY_MDSEL       ),
    .joy_in       ( JOY_MDIN        ),
    .joystick1    ( JOYDB9MD_1_raw  ),
    .joystick2    ( JOYDB9MD_2_raw  ),
    .joy1_is_6btn ( JOYDB9MD_1_6btn ),
    .joy2_is_6btn ( JOYDB9MD_2_6btn )
);
wire [15:0] JOYDB9MD_1 = {4'b0, JOYDB9MD_1_raw};
wire [15:0] JOYDB9MD_2 = {4'b0, JOYDB9MD_2_raw};

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
wire        JOYDBSATURN_BOTH   = JOYDBSATURN_1_VALID & JOYDBSATURN_2_VALID;
// [MiSTer-DB9-Pro END]

// ---- Menu_MiSTer-port FSM body ----
// Counter widths/values copied from Menu_MiSTer/menu.sv (tuned for 50 MHz clk).
// At 40 MHz the absent / recovery / arm windows scale to ~12.5 ms — still
// well within the hot-swap UX budget.
reg [19:0] saturn_probe_cnt   = 20'd0;
reg  [1:0] saturn_cycle_cnt   = 2'd0;
reg [15:0] db9md_lo_cnt       = 16'd0;
reg [19:0] db9md_absent_cnt   = 20'd0;
reg [15:0] db15_disable_cnt   = 16'd0;
reg [19:0] db15_recover_cnt   = 20'd0;
reg [19:0] db15_arm_delay_cnt = 20'd0;
localparam [15:0] DB9MD_DEBOUNCE        = 16'd49999;   // ~1 ms @ 50 MHz
localparam [19:0] DB9MD_ABSENT_DELAY    = 20'd999999;  // ~10 ms
localparam [15:0] DB15_DISABLE_DEBOUNCE = 16'd49999;   // ~1 ms
localparam [19:0] DB15_RECOVER_DELAY    = 20'd999999;  // ~10 ms
localparam [19:0] DB15_ARM_DELAY        = 20'd999999;  // ~10 ms (post-swap mask)

// joydb is clocked at a fixed 40-50 MHz (CLK_JOY / clk_joy=CLK_50M on jt cores),
// so these debounce/probe counters count at their tuned wall-clock rate on every
// core and db9_cen is a constant 1 (the `if(db9_cen)` count guards below are
// no-ops). (The earlier JTFRAME_SDRAM96 divide-by-2 clock enable for a 96 MHz
// clk_sys was removed once jt cores moved joydb onto a fixed CLK_50M.)
wire db9_cen = 1'b1;

wire db9_status              = db9md_ena ? 1'b1 : USER_IN[7];
wire db15_idle               = ~(|JOYDB15_1[11:0] | |JOYDB15_2[11:0]);
wire db9md_detect_low        = ~db9md_ena & ~db9_status;
wire db9md_debounce_active   = saturn_any | (db15_arm_delay_cnt != 20'd0);
wire db9md_present_signature = db9md_ena & ~JOY_MDSEL & ~USER_IN[1] & ~USER_IN[2];
wire db15_disable_pins_low   = ~USER_IN[6] | ~USER_IN[2] | ~USER_IN[3];
wire db15_disable_armed      = ~saturn_any & ~db9md_ena & ~db9md_detect_low & (db15_arm_delay_cnt == 20'd0);

task automatic reset_db9_debounce;
    begin
        db9md_lo_cnt     <= 16'd0;
        db9md_absent_cnt <= 20'd0;
        db15_disable_cnt <= 16'd0;
        db15_recover_cnt <= 20'd0;
    end
endtask

always @(posedge clk) begin
    if (~probe_active) begin
        // OSD closed / SNAC / MT32-on-primary: hold FSM in reset; user-mode
        // joy_type-driven muxes drive joydb_1/joydb_2.
        saturn_active      <= 1'b0;
        saturn_probe       <= 1'b1;
        saturn_settle      <= 1'b0;
        db15_disable       <= 1'b0;
        db9md_ena          <= 1'b0;
        db9_any_ena        <= 1'b0;
        saturn_probe_cnt   <= 20'd0;
        saturn_cycle_cnt   <= 2'd0;
        db9md_lo_cnt       <= 16'd0;
        db9md_absent_cnt   <= 20'd0;
        db15_disable_cnt   <= 16'd0;
        db15_recover_cnt   <= 20'd0;
        db15_arm_delay_cnt <= 20'd0;
    end
    else begin
        if (db9_cen && db15_arm_delay_cnt != 20'd0) db15_arm_delay_cnt <= db15_arm_delay_cnt - 1'd1;

        // DB9MD physical removal: D1=D0=0 signature missing for ~10 ms → drop.
        if (db9md_ena) begin
            if (db9md_present_signature) db9md_absent_cnt <= 20'd0;
            else if (db9md_absent_cnt < DB9MD_ABSENT_DELAY) begin if (db9_cen) db9md_absent_cnt <= db9md_absent_cnt + 1'b1; end
            else begin
                db9md_ena    <= 1'b0;
                db15_disable <= 1'b0;
                reset_db9_debounce;
                db15_arm_delay_cnt <= DB15_ARM_DELAY;
            end
        end
        else db9md_absent_cnt <= 20'd0;

        // DB9MD detection: immediate in idle/DB15 mode, ~1 ms debounce during
        // Saturn phases and the post-swap recovery window.
        if (db9md_detect_low) begin
            if (db9md_debounce_active) begin
                if (db9md_lo_cnt < DB9MD_DEBOUNCE) begin if (db9_cen) db9md_lo_cnt <= db9md_lo_cnt + 1'b1; end
                else                                db9md_ena    <= 1'b1;
            end
            else begin
                db9md_ena <= 1'b1;
                reset_db9_debounce;
            end
        end
        else db9md_lo_cnt <= 16'd0;

        // DB15 disable latch: all-low pin signature for ~1 ms while in idle/DB15
        // (suggests Saturn-floating pins) → mask DB15 output until pins clear.
        if (~db15_disable_armed | ~db15_disable_pins_low) begin
            db15_disable_cnt <= 16'd0;
        end
        else if (!db15_disable) begin
            if (db15_disable_cnt < DB15_DISABLE_DEBOUNCE) begin if (db9_cen) db15_disable_cnt <= db15_disable_cnt + 1'b1; end
            else                                          db15_disable     <= 1'b1;
        end
        if (db15_disable & ~saturn_any & ~db9md_ena & ~db15_disable_pins_low) begin
            if (db15_recover_cnt < DB15_RECOVER_DELAY) begin if (db9_cen) db15_recover_cnt <= db15_recover_cnt + 1'b1; end
            else begin
                db15_disable     <= 1'b0;
                db15_recover_cnt <= 20'd0;
            end
        end
        else db15_recover_cnt <= 20'd0;

        // DB15/DB9MD active latch: any button-2 press on either port. Cleared
        // when db9md_ena is positively asserted so a positive DB9MD signature
        // wins over a sticky DB15 latch (e.g. phantom button-2 from a floating
        // 2P-MUX side during a missed MD handshake).
        if (JOYDB9MD_1[2] | JOYDB15_1[2] | (~JOYDB9MD_1[2] & JOYDB9MD_2[2]) | JOYDB15_2[2]) db9_any_ena <= 1'b1;
        else if (db9md_ena) db9_any_ena <= 1'b0;

        // Saturn autodetect: idle → settle → probe → settle → ... → active.
        // saturn_any masks JOY_DATA / JOY_MDIN; saturn_mode drives Saturn pins.
        if (saturn_active) begin
            if (~JOYDBSATURN_1_VALID & ~JOYDBSATURN_2_VALID) begin
                saturn_active      <= 1'b0;
                db9_any_ena        <= 1'b1;
                db15_disable       <= 1'b0;
                db9md_ena          <= 1'b0;
                reset_db9_debounce;
                db15_arm_delay_cnt <= DB15_ARM_DELAY;
            end
            saturn_probe_cnt <= 20'd0;
            saturn_settle    <= 1'b0;
            saturn_cycle_cnt <= 2'd0;
        end
        else if (saturn_probe) begin
            if (JOYDBSATURN_1_VALID | JOYDBSATURN_2_VALID) begin
                saturn_active    <= 1'b1;
                saturn_probe     <= 1'b0;
                saturn_probe_cnt <= 20'd0;
            end
            else if (db9md_ena) begin
                saturn_probe     <= 1'b0;
                saturn_probe_cnt <= 20'd0;
                saturn_cycle_cnt <= 2'd0;
            end
            else if (saturn_probe_cnt < 20'd499999) begin
                if (db9_cen) saturn_probe_cnt <= saturn_probe_cnt + 1'd1;
            end
            else begin
                saturn_probe     <= 1'b0;
                saturn_probe_cnt <= 20'd0;
                saturn_settle    <= 1'b1;
            end
        end
        else if (saturn_settle) begin
            if (saturn_probe_cnt < 20'd999999) begin
                if (db9_cen) saturn_probe_cnt <= saturn_probe_cnt + 1'd1;
            end
            else begin
                saturn_settle    <= 1'b0;
                saturn_probe_cnt <= 20'd0;
                if (db9md_ena) begin
                    saturn_cycle_cnt <= 2'd0;
                end
                else if (saturn_cycle_cnt < 2'd1) begin
                    saturn_probe     <= 1'b1;
                    saturn_cycle_cnt <= saturn_cycle_cnt + 1'd1;
                end
                else begin
                    saturn_cycle_cnt <= 2'd0;
                end
            end
        end
        else if (~db9md_ena & db15_idle) begin
            if (saturn_probe_cnt < 20'd999999) begin
                if (db9_cen) saturn_probe_cnt <= saturn_probe_cnt + 1'd1;
            end
            else begin
                saturn_probe_cnt <= 20'd0;
                saturn_settle    <= 1'b1;
            end
        end
        else begin
            saturn_probe_cnt <= 20'd0;
        end
    end
end

wire [1:0] joy_raw_detect = saturn_active ? 2'd1   // Saturn
                          : db9md_ena     ? 2'd2   // DB9MD
                          : db9_any_ena   ? 2'd3   // DB15
                          :                 2'd0;

// ---- Unified selector wires (probe vs user mode) ---------------------------
// Probe mode → FSM state; user mode → joy_type-derived flags ANDed with
// saturn_unlocked on the Saturn arm. db15_disable suppresses DB15 ghost output
// while the floating-pin signature persists (boot-core exception applies in
// probe mode — Main_MiSTer suppresses Saturn shm write when key missing).
wire data_sel_saturn = probe_active ? saturn_active                              : (joy_saturn_en & saturn_unlocked);
wire data_sel_db9md  = probe_active ? db9md_ena                                  : joy_db9md_en;
wire data_sel_db15   = probe_active ? (db9_any_ena & ~db9md_ena & ~db15_disable) : joy_db15_en;

// Drive-path: probe mode uses saturn_mode (continuous drive while saturn_active=1).
wire drive_sel_saturn = probe_active ? saturn_mode                : joy_saturn_en;
wire drive_sel_db9md  = probe_active ? (~saturn_any & db9md_ena)  : joy_db9md_en;
wire drive_sel_db15   = probe_active ? (~saturn_any & ~db9md_ena) : joy_db15_en;

// Saturn 1P routing: SINGLE in probe / user 1P, P1 in user 2P.
wire        saturn_p1_single = probe_active | ~joy_2p;
wire [15:0] saturn_p1        = saturn_p1_single ? JOYDBSATURN_SINGLE : JOYDBSATURN_1;
// Saturn 2P: gate on BOTH-valid during probe so P2 stays 0 until both pads land.
wire        saturn_p2_valid  = ~probe_active | JOYDBSATURN_BOTH;
wire [15:0] saturn_p2        = saturn_p2_valid ? JOYDBSATURN_2 : 16'h0000;

// [MiSTer-DB9-Pro BEGIN] - Saturn arm AND-gated with saturn_unlocked via data_sel_saturn
assign joydb_1 = data_sel_saturn ? saturn_p1
               : data_sel_db9md  ? JOYDB9MD_1
               : data_sel_db15   ? JOYDB15_1
               :                   16'h0000;
assign joydb_2 = data_sel_saturn ? saturn_p2
               : data_sel_db9md  ? JOYDB9MD_2
               : data_sel_db15   ? JOYDB15_2
               :                   16'h0000;
// [MiSTer-DB9-Pro END]
// Probe needs joydb_1 active even when user had Off (joy_any_en=0) so the OSD
// nav path still sees Start+C from the hot-swapped pad.
assign joydb_1ena = probe_active | joy_any_en;
assign joydb_2ena = probe_active | (joy_any_en & joy_2p);

// Per-player 6-button pad presence. Mirrors the data_sel_* mux above so the
// flag tracks whatever source is actively driving joydb_1 / joydb_2 (probe
// FSM or user-mode joy_type). Saturn pads are always 6-btn-shaped; DB9MD
// follows the helper's protocol-level detect; DB15 has no row geometry.
assign pad_1_6btn = data_sel_saturn
                  | (data_sel_db9md & JOYDB9MD_1_6btn);
assign pad_2_6btn = data_sel_saturn
                  | (data_sel_db9md & JOYDB9MD_2_6btn);

assign USER_OSD  = joydb_1[10] & joydb_1[6];  // Start+C opens OSD

// USER_PP_DRIVE: Saturn-settle (saturn_any & ~saturn_mode) forces all pins to
// open-drain so IO[0]/IO[1] recover before the next probe. Mirrors Menu_MiSTer.
assign USER_PP_DRIVE = drive_sel_saturn               ? 8'b01010100
                     : (probe_active & saturn_any)    ? 8'b00000000
                     : drive_sel_db9md                ? 8'b00010001
                     : drive_sel_db15                 ? 8'b00000011
                     :                                  8'b00000000;

// Cores compose USER_OUT with MT32 fallback if applicable:
//   assign USER_OUT = mt32_use ? mt32_drive : USER_OUT_DRIVE;
// [MiSTer-DB9-Pro BEGIN] - Saturn arm prepended (DB9-only baseline had no Saturn arm)
assign USER_OUT_DRIVE = drive_sel_saturn            ? {1'b1,JOY_SAT_S1,1'b1,JOY_SAT_S0,1'b1,JOY_SAT_SPLIT,2'b11}
                      : (probe_active & saturn_any) ? 8'hFF
                      : drive_sel_db9md             ? {3'b111,JOY_SPLIT,3'b111,JOY_MDSEL}
                      : drive_sel_db15              ? {6'b111011, JOY_CLK, JOY_LOAD}
                      :                               8'hFF;
// [MiSTer-DB9-Pro END]

// joy_raw payload: {detected (while probing) | selected (otherwise), buttons}.
assign joy_raw = {probe_active ? joy_raw_detect : joy_type, joydb_1[13:0] | joydb_2[13:0]};

endmodule
