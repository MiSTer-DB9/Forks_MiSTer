// [MiSTer-DB9-Pro BEGIN] - SipHash-2-4, fixed 32-byte input
// Aumasson + Bernstein 2012, https://www.aumasson.jp/siphash/
// Companion of Main_MiSTer/siphash24.{c,h} and porting/scripts/db9_sign.py;
// all three produce identical 8-byte tags for identical inputs.
//
// SIPROUND is split into two cycles (sip_phase 0/1) to break the back-to-back
// 64-bit add chain (step1 a0=v0+v1 feeds step3 a2=a1+d0; step2 c0=v2+v3 feeds
// step4 c1=c0+b0). At 96-100 MHz on Cyclone V SE-7 the original single-cycle
// SIPROUND was too tight on the densest jtcores (cps1/cps2 ran negative slack
// after the v1.5 key gate landed). The pipelined form halves adder depth per
// cycle; total round count doubles but the gate runs once per core launch
// (see db9_key_gate.sv) so the extra latency is invisible.

module siphash24 (
	input              clk,
	input              start,        // 1-cycle pulse to begin
	input      [127:0] key,          // 16 bytes; key[63:0]=k0 (low 8B, LE)
	input      [255:0] msg,          // 32 bytes; msg[63:0]=first block (LE)
	output reg  [63:0] tag = 0,      // 8-byte output, LE
	output reg         done = 0      // 1-cycle pulse when tag valid
);

	// ---- State ----
	reg [63:0] v0 = 0, v1 = 0, v2 = 0, v3 = 0;
	reg [2:0]  state       = 0;
	reg [2:0]  blk         = 0;  // current block index 0..4
	reg [1:0]  sip_left    = 0;  // SIPROUNDs remaining in current phase
	reg        sip_phase   = 0;  // 0 = latch step1+step2; 1 = apply step3+step4
	reg        in_finalize = 0;  // ST_SIP exit target: 0 → ST_BLK_POST, 1 → ST_DONE

	// Pipeline registers — capture step1+step2 outputs at end of phase 0.
	// s_a0 isn't needed (a0 only feeds step3 through a1).
	reg [63:0] s_a1 = 0, s_b0 = 0, s_c0 = 0, s_d0 = 0;

	localparam ST_IDLE     = 3'd0;
	localparam ST_BLK_PRE  = 3'd1;  // v3 ^= m; arm 2 SIPROUNDs
	localparam ST_SIP      = 3'd2;  // SIPROUND × sip_left (2 cycles each)
	localparam ST_BLK_POST = 3'd3;  // v0 ^= m; advance blk
	localparam ST_FIN_PRE  = 3'd4;  // v2 ^= 0xff; arm 4 SIPROUNDs
	localparam ST_DONE     = 3'd5;

	// ---- Block selector ----
	// 4 message blocks + 1 length-pad block.  msg[63:0] is block 0 (first 8 bytes).
	// Pad block: 7 zero bytes + length byte (0x20 = 32) at the high byte.
	wire [63:0] cur_blk =
		(blk == 3'd0) ? msg[ 63:  0] :
		(blk == 3'd1) ? msg[127: 64] :
		(blk == 3'd2) ? msg[191:128] :
		(blk == 3'd3) ? msg[255:192] :
		                {8'd32, 56'h0};

	// ---- Stage 1: step1 + step2 (combinational from v0..v3) ----
	// step1: v0 += v1; v1 = rotl(v1,13); v1 ^= v0; v0 = rotl(v0,32)
	wire [63:0] a0 = v0 + v1;
	wire [63:0] b0 = {v1[50:0], v1[63:51]} ^ a0;
	wire [63:0] a1 = {a0[31:0], a0[63:32]};
	// step2: v2 += v3; v3 = rotl(v3,16); v3 ^= v2
	wire [63:0] c0 = v2 + v3;
	wire [63:0] d0 = {v3[47:0], v3[63:48]} ^ c0;

	// ---- Stage 2: step3 + step4 (combinational from registered intermediates) ----
	// step3: v0 += v3; v3 = rotl(v3,21); v3 ^= v0
	wire [63:0] a2 = s_a1 + s_d0;
	wire [63:0] d1 = {s_d0[42:0], s_d0[63:43]} ^ a2;
	// step4: v2 += v1; v1 = rotl(v1,17); v1 ^= v2; v2 = rotl(v2,32)
	wire [63:0] c1 = s_c0 + s_b0;
	wire [63:0] b1 = {s_b0[46:0], s_b0[63:47]} ^ c1;
	wire [63:0] c2 = {c1[31:0], c1[63:32]};

	// ---- FSM ----
	always @(posedge clk) begin
		done <= 1'b0;  // default; pulses for one cycle in DONE
		case (state)
			ST_IDLE: begin
				if (start) begin
					// Init: v_i = key_lane ^ const_lane
					v0 <= key[ 63:  0] ^ 64'h736f6d6570736575;
					v1 <= key[127: 64] ^ 64'h646f72616e646f6d;
					v2 <= key[ 63:  0] ^ 64'h6c7967656e657261;
					v3 <= key[127: 64] ^ 64'h7465646279746573;
					blk   <= 3'd0;
					state <= ST_BLK_PRE;
				end
			end

			ST_BLK_PRE: begin
				v3          <= v3 ^ cur_blk;
				sip_left    <= 2'd1;             // 2 compress rounds: 1, 0
				sip_phase   <= 1'b0;
				in_finalize <= 1'b0;
				state       <= ST_SIP;
			end
			ST_SIP: begin
				if (sip_phase == 1'b0) begin
					s_a1 <= a1; s_b0 <= b0; s_c0 <= c0; s_d0 <= d0;
					sip_phase <= 1'b1;
				end else begin
					v0 <= a2; v1 <= b1; v2 <= c2; v3 <= d1;
					sip_phase <= 1'b0;
					sip_left  <= sip_left - 2'd1;
					if (sip_left == 2'd0)
						state <= in_finalize ? ST_DONE : ST_BLK_POST;
				end
			end
			ST_BLK_POST: begin
				v0 <= v0 ^ cur_blk;
				if (blk == 3'd4) state <= ST_FIN_PRE;
				else begin blk <= blk + 3'd1; state <= ST_BLK_PRE; end
			end

			ST_FIN_PRE: begin
				v2          <= v2 ^ 64'hff;
				sip_left    <= 2'd3;             // 4 finalize rounds: 3, 2, 1, 0
				sip_phase   <= 1'b0;
				in_finalize <= 1'b1;
				state       <= ST_SIP;
			end

			ST_DONE: begin
				tag   <= v0 ^ v1 ^ v2 ^ v3;
				done  <= 1'b1;
				state <= ST_IDLE;
			end

			default: state <= ST_IDLE;
		endcase
	end

endmodule
// [MiSTer-DB9-Pro END]
