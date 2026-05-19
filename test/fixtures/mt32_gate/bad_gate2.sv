// fixture: Gate 2 defect (the original the MT32 anti-contention rule bug). USER_OUT
// MT32 fallback in an UNCONDITIONAL `else` -> MT32 drives I2C onto USER_IO
// during the boot window. Gate 1 is fine. Expect FATAL "Gate 2 missing",
// exit 1. (mt32_disable sits >90 chars before the defect so it does not
// leak into the governing-condition window.)
module emu (input clk);
wire [6:0] USER_IN_MT32 = (joy_any_en | mt32_disable) ? 7'd1 : USER_IN[6:0];
always_comb begin
  if (joy_any_en) USER_OUT[6:0] = USER_OUT_DRIVE;
  else begin
    USER_OUT[6:0] = USER_OUT_MT32;
  end
end
endmodule
