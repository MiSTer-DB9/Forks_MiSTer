// fixture: core not in the SNAC table but snac_active is non-default --
// possibly a newly-SNAC core not yet tabled. Non-gating FINDING (review),
// exit 0 (keeps the FATAL tier 0-false-positive).
module emu (input clk);
wire snac_active = some_snac_enable;
endmodule
