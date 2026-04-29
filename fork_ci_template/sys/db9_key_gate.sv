// [MiSTer-DB9-Pro BEGIN] - key gate v1.5 (per-customer SipHash MAC)
// FPGA companion of Main_MiSTer/db9_key.cpp; key file layout in
// porting/KEY_GATE_V15_DESIGN.md §3. On a valid 40-byte 0xFE stream the
// SipHash tag matches, feature_mask is latched from payload bytes [24..28),
// and saturn_unlocked goes high. On any failure feature_mask stays 0 and
// gated features remain inert.

module db9_key_gate #(
	// 256 bits but only the low 128 feed SipHash. The upper 128 are reserved
	// for future v2 nonce mode (HMAC seed derivation) and stay synth-time
	// constant; Quartus prunes the unused bits at no silicon cost.
	parameter [255:0] MASTER_ROOT = 256'h0  // synth-time +define from CI
) (
	input              clk,

	// hps_io.sv tap: register snapshot of cmd + byte_cnt + io_din.
	input              cmd_db9,        // = (cmd == 16'hFE)
	input        [5:0] byte_cnt,       // current byte_cnt (16-bit word index)
	input       [15:0] io_din,

	output             saturn_unlocked
);

	reg  [31:0] feature_mask = 0;
	assign saturn_unlocked = feature_mask[0];

	reg [255:0] payload   = 0;
	reg  [63:0] tag_in    = 0;
	reg         start_sip = 0;

	always @(posedge clk) begin
		start_sip <= 1'b0;
		if (cmd_db9) begin
			if (byte_cnt >= 6'd1 && byte_cnt <= 6'd16)
				payload[(byte_cnt - 6'd1) * 16 +: 16] <= io_din;
			else if (byte_cnt >= 6'd17 && byte_cnt <= 6'd20)
				tag_in[(byte_cnt - 6'd17) * 16 +: 16] <= io_din;
			if (byte_cnt == 6'd20) start_sip <= 1'b1;
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

	always @(posedge clk) begin
		if (sip_done) begin
			// payload bytes 24..27 (little-endian) carry feature_mask.
			feature_mask <= eq ? payload[223:192] : 32'h0;
		end
	end

endmodule
// [MiSTer-DB9-Pro END]
