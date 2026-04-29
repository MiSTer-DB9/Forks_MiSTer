// [MiSTer-DB9-Pro BEGIN] - key gate v1.5 (per-customer SipHash MAC)
// FPGA companion of Main_MiSTer/db9_key.cpp; key file layout in
// porting/KEY_GATE_V15_DESIGN.md §3. On a valid 40-byte 0xFE stream the
// SipHash tag matches, feature_mask is latched from payload bytes [24..28),
// and saturn_unlocked goes high. On any failure feature_mask stays 0 and
// gated features remain inert.

module db9_key_gate #(
	// Upper 128 bits reserved for v2 nonce mode (HMAC seed derivation);
	// Quartus prunes them at no silicon cost.
	parameter [255:0] MASTER_ROOT = 256'h0
) (
	input              clk,
	input              cmd_db9,
	input        [5:0] byte_cnt,
	input       [15:0] io_din,
	output      [31:0] feature_mask,
	output             saturn_unlocked
);

	localparam [5:0] PAYLOAD_FIRST    = 6'd1;
	localparam [5:0] PAYLOAD_LAST     = 6'd16;
	localparam [5:0] TAG_FIRST        = 6'd17;
	localparam [5:0] TAG_LAST         = 6'd20;
	localparam       FEATURE_MASK_LSB = 192;

	reg [255:0] payload   = 0;
	reg  [63:0] tag_in    = 0;
	reg         start_sip = 0;

	// Indexed-slice writes (not shift register): hps_io.sv holds cmd_db9 high
	// for the entire 40-byte transaction (cmd is a latched register, not a
	// strobe). Same-slot rewrites are idempotent; a shift register would
	// scramble payload/tag_in on every held cycle.
	always @(posedge clk) begin
		start_sip <= 1'b0;
		if (cmd_db9) begin
			if (byte_cnt >= PAYLOAD_FIRST && byte_cnt <= PAYLOAD_LAST)
				payload[(byte_cnt - PAYLOAD_FIRST) * 16 +: 16] <= io_din;
			else if (byte_cnt >= TAG_FIRST && byte_cnt <= TAG_LAST)
				tag_in[(byte_cnt - TAG_FIRST) * 16 +: 16] <= io_din;
			if (byte_cnt == TAG_LAST) start_sip <= 1'b1;
		end
	end

	wire [63:0] tag_expected;
	wire        sip_done;

	siphash24 u_sip (
		.clk   (clk),
		.start (start_sip),
		.key   (MASTER_ROOT[127:0]),
		.msg   (payload),
		.tag   (tag_expected),
		.done  (sip_done)
	);

	wire eq = ~|(tag_expected ^ tag_in);

	reg [31:0] feature_mask_r = 0;
	always @(posedge clk) begin
		if (sip_done)
			feature_mask_r <= eq ? payload[FEATURE_MASK_LSB +: 32] : 32'b0;
	end
	assign feature_mask    = feature_mask_r;
	assign saturn_unlocked = feature_mask_r[0];

endmodule
// [MiSTer-DB9-Pro END]
