// fixture: Gate 1 defect. USER_IN_MT32 gated on bare joy_any_en only (no
// mt32_disable) -> at boot joy_any_en=0 leaves MT32 reading raw DB9
// signals. Gate 2 is fine. Expect FATAL "Gate 1 missing", exit 1.
module emu (input clk);
wire [6:0] USER_IN_MT32 = joy_any_en ? 7'd1 : USER_IN[6:0];
always_comb begin
  if (joy_any_en)      USER_OUT[6:0] = USER_OUT_DRIVE;
  else if (mt32_use)   USER_OUT[6:0] = USER_OUT_MT32;
  else                 USER_OUT[6:0] = 7'b1111111;
end
endmodule
