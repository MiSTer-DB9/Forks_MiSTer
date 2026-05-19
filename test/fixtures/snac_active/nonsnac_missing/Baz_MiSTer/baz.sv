// fixture: non-SNAC core with no `wire snac_active` line (the common case
// -- ~133/145 cores gate joy_type directly off status[127:126], no snac
// wrapper gate). Normal, not a defect. Expect n/a, exit 0.
module emu (input clk);
wire [1:0] joy_type = status[127:126];
endmodule
