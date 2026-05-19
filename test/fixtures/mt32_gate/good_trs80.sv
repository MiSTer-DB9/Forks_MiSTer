// fixture: TRS-80 variant (the MT32 anti-contention rule "different (correct)
// approach"). Both USER_IN_MT32 and the USER_OUT MT32 fallback gated on
// mt32_disable directly, assign style. Expect ok, exit 0.
module emu (input clk);
wire mt32_disable = ~status[33];
wire [6:0] USER_IN_MT32 = mt32_disable ? 7'd1 : USER_IN[6:0];
assign USER_OUT[6:0] = mt32_disable ? 7'b1111111 : USER_OUT_MT32;
endmodule
