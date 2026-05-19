// fixture: tabled SNAC core (Genesis_MiSTer) with NO `wire snac_active`
// line at all -> joy_type ungated, SNAC cannot preempt the joydb wrapper.
// Expect FATAL, exit 1.
module emu (input clk);
wire [1:0] joy_type = status[127:126];
endmodule
