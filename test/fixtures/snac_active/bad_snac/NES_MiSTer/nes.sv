// fixture: tabled SNAC core (NES_MiSTer) whose snac_active was reset to the
// inert 1'b0 default (the apply_db9_framework.sh / merge regression). SNAC
// will not preempt the joydb wrapper. Expect FATAL, exit 1.
module emu (input clk);
wire snac_active = 1'b0;
endmodule
