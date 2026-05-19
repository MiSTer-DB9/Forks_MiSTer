// fixture: Saturn-capable, joydb wrapper, constant tie -> WEAK exit 1
// (legit for an always-unlocked test core; delta-cancelled in merge_validate)
module emu (input clk);
joydb joydb (
    .clk(clk),
    .saturn_unlocked(1'b1)
);
endmodule
