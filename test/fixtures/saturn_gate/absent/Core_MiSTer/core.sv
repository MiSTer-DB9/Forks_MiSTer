// fixture: Saturn-capable, joydb wrapper, port NOT connected -> WEAK exit 1
module emu (input clk);
joydb joydb (
    .clk(clk),
    .joy_db15_en(1'b0)
);
endmodule
