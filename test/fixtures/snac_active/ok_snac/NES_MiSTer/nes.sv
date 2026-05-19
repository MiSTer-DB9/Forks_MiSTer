// fixture: tabled SNAC core (NES_MiSTer) with snac_active wired to its
// per-core SNAC-enable expr (raw_serial). Expect ok, exit 0.
module emu (input clk);
wire snac_active = raw_serial;
endmodule
