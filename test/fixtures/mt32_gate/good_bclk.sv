// fixture: correct MT32 double-gate with the BCLK term (ao486 / AtariST /
// Minimig / X68000). Gate 2 also opens when joydb's I2S BCLK detector sees an
// RPi that has no I2C on the user port. Expect ok, exit 0.
module emu (input clk);
wire [6:0] USER_IN_MT32 = (joy_any_en | mt32_disable) ? 7'd1 : USER_IN[6:0];
always_comb begin
  if (joy_any_en) USER_OUT[6:0] = USER_OUT_DRIVE;
  else if (mt32_use | (mt32_present & ~mt32_disable)) USER_OUT[6:0] = USER_OUT_MT32;
  else USER_OUT[6:0] = 7'b1111111;
end
`ifdef SECOND_MT32
assign USER_OUT = mt32_on_primary & (mt32_use | (mt32_present & ~mt32_disable)) ? {1'b1, mt32_out} : 8'hFF;
`endif
endmodule
