// fixture: wrong-family close -- DB9 END closes a Pro BEGIN (outer before
// inner). Counts stay balanced (1 DB9, 1 Pro) yet nesting is invalid.
module emu (
    input clk
);

// [MiSTer-DB9 BEGIN] - outer
wire a = 1'b0;
// [MiSTer-DB9-Pro BEGIN] - inner
wire b = 1'b0;
// [MiSTer-DB9 END]
wire c = 1'b0;
// [MiSTer-DB9-Pro END]

endmodule
