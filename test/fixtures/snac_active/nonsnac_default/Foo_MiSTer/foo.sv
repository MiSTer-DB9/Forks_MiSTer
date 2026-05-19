// fixture: non-SNAC core, snac_active at the inert 1'b0 default (correct
// for a core with no SNAC path). Expect n/a, exit 0.
module emu (input clk);
wire snac_active = 1'b0;
endmodule
