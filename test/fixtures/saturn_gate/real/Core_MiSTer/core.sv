// fixture: Saturn-capable, joydb wrapper, real saturn_unlocked -> PASS
module emu (input clk);
// [MiSTer-DB9-Pro BEGIN] - key gate
wire saturn_unlocked;
joydb joydb (
    .clk(clk),
    .saturn_unlocked(saturn_unlocked)
);
// [MiSTer-DB9-Pro END]
endmodule
