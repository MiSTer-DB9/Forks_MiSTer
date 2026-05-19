// fixture: correct MT32 double-gate, always_comb style (Minimig/AtariST
// /X68000). Gate 1 USER_IN_MT32 AND-includes mt32_disable; Gate 2 USER_OUT
// MT32 fallback governed by `else if (mt32_use)`. Expect ok, exit 0.
module emu (input clk);
wire [6:0] USER_IN_MT32 = (joy_any_en | mt32_disable) ? 7'd1 : USER_IN[6:0];
always_comb begin
  if (joy_any_en)      USER_OUT[6:0] = USER_OUT_DRIVE;
  else if (mt32_use)   USER_OUT[6:0] = USER_OUT_MT32;
  else                 USER_OUT[6:0] = 7'b1111111;
end
endmodule
