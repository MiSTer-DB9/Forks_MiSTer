// MiSTer-DB9 programmable button-remap matrix.
//
// Replaces the per-core hardcoded "Buttons Config." permutation (a fixed
// combinational rewire of joydb_1/joydb_2 raw bits selected by a CONF_STR
// field) with a DATA-driven one. For each remappable output slot (MiSTer-
// standard joystick bit order, identical to the USB joystick_N word so a core
// can consume joydb_*_mapped exactly where it consumes joy0_USB) a 4-bit
// selector chooses which physical DB9/DB15/Saturn source bit drives it.
//
// Minimal-resource form (atomic-fleet build, no backward compat):
//   * D-pad outputs [3:0] are HARDWIRED to raw [3:0] -- DB9 U/D/L/R are
//     dedicated pins, never remapped -- so they cost no selector and no mux.
//   * Only button slots 4..12 (9 slots -> joystick[12:4]) are remappable;
//     outputs [15:13] are constant 0.
//   * ONE selector table is SHARED by both player ports (Main_MiSTer streams
//     identical layouts to P1 and P2), so each of the 9 slots costs one 4-bit
//     selector, not two.
//   => 9 slots x 4 bits = 36 selector bits total (was 16 x 5 x 2 = 160).
//
// The selector table is loaded over UIO command 0xFD (Main_MiSTer db9_map.cpp),
// 3 x 16-bit words (byte_cnt 1..3) into the low 36 bits. hps_io.sv holds
// remap_cmd high for the whole transaction and presents the running word index
// in byte_cnt, so we use indexed-slice writes exactly like db9_key_gate.sv (a
// shift register would scramble on every held cycle).
//
// Latency: sel is a config register written ONLY during the OSD-time 0xFD
// stream; the per-slot output is a pure combinational source mux off the
// (already Saturn-key-gated) joydb_1/joydb_2 raw bits -- same structure as the
// old hardcoded ternary, no added gameplay-path register. Satisfies Critical
// Rule #2.
//
// Fork-only file (no upstream counterpart) and always-free plumbing: the Saturn
// key gate lives UPSTREAM of this module (the Saturn arm of joydb_1/joydb_2 in
// joydb.sv is AND-gated with saturn_unlocked), so the Saturn source bits are
// already 0 when the key is missing. No Pro markers needed here.

module joydb_remap
(
    // HPS-bus clock (clk_sys), NOT the joystick scan clock. remap_cmd/
    // remap_byte_cnt/remap_din are hps_io registers in the clk_sys domain;
    // loading sel on clk_sys keeps the indexed-slice write coherent with them,
    // exactly like db9_key_gate.sv. The source mux below is combinational, so it
    // needs no clock and the mapped outputs are sampled in the core domain.
    input  logic        clk_sys,

    // UIO 0xFD selector-table load (mirrors db9_key_gate.sv receiver).
    input  logic        remap_cmd,
    input  logic [5:0]  remap_byte_cnt,
    input  logic [15:0] remap_din,

    // Raw physical-order joystick words in (already Saturn-gated upstream).
    input  logic [15:0] joydb_1,
    input  logic [15:0] joydb_2,

    // Remapped MiSTer-standard-order words out.
    output logic [15:0] joydb_1_mapped,
    output logic [15:0] joydb_2_mapped
);

    // 9 remappable button slots (output bits 4..12) x 4-bit selector = 36 bits,
    // shared by both ports. Selector values (match db9_map.h / pack_src below):
    //   0..13 select raw[value]; 14 = Start&B combo (Saturn Select when the core
    //   uses R as R); 15 = NONE (constant 0).
    //
    // Reset default = every selector 4'd15 (DB9_MAP_NONE) so each button output
    // reads 0 until Main_MiSTer streams the real per-devtype map on core load --
    // no spurious raw bit (e.g. Saturn raw[12]=L) leaks onto a button slot in
    // the pre-stream window. D-pad is hardwired, so it is live immediately,
    // which is correct: U/D/L/R map straight through on every devtype, and the
    // mapped word is only consumed when joydb_*ena is set.
    localparam [5:0] WORD_FIRST = 6'd1;
    localparam [5:0] WORD_LAST  = 6'd3;

    // 3 x 16-bit words = 48 bits; only the low 36 are used (9 x 4). The upper 12
    // are written but never read -> pruned by synthesis.
    reg [47:0] sel;
    initial sel = {48{1'b1}};   // all selectors = 4'b1111 = 15 (NONE) -> outputs 0

    always @(posedge clk_sys) begin
        if (remap_cmd && remap_byte_cnt >= WORD_FIRST && remap_byte_cnt <= WORD_LAST)
            sel[(remap_byte_cnt - WORD_FIRST) * 16 +: 16] <= remap_din;
    end

    // Source-bit lookup vector: index 0..13 = raw bits, 14 = Start&B combo,
    // 15 = 0 (NONE). Synthesis prunes the constant entry.
    wire [15:0] src_1 = pack_src(joydb_1);
    wire [15:0] src_2 = pack_src(joydb_2);

    function automatic [15:0] pack_src(input [15:0] raw);
        begin
            pack_src        = 16'd0;
            pack_src[13:0]  = raw[13:0];
            pack_src[14]    = raw[10] & raw[5];   // Start&B combo sentinel
            // pack_src[15] = 0 (NONE)
        end
    endfunction

    // D-pad: hardwired identity (no selector, no mux).
    assign joydb_1_mapped[3:0]   = joydb_1[3:0];
    assign joydb_2_mapped[3:0]   = joydb_2[3:0];

    // Unused high slots.
    assign joydb_1_mapped[15:13] = 3'b0;
    assign joydb_2_mapped[15:13] = 3'b0;

    // Button slots 4..12 through the shared 4-bit selector (same sel for both ports).
    genvar i;
    generate
        for (i = 4; i <= 12; i = i + 1) begin : g_slot
            assign joydb_1_mapped[i] = src_1[ sel[(i-4)*4 +: 4] ];
            assign joydb_2_mapped[i] = src_2[ sel[(i-4)*4 +: 4] ];
        end
    endgenerate

endmodule
