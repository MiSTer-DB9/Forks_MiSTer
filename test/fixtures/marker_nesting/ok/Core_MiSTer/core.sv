// fixture: balanced + correctly nested (Pro inside DB9, inner closed first)
module emu (
    input clk
);

// [MiSTer-DB9 BEGIN] - DB9/SNAC8 boilerplate
wire a = 1'b0;
// [MiSTer-DB9-Pro BEGIN] - Saturn arm
wire b = 1'b0;
// [MiSTer-DB9-Pro END]
wire c = 1'b0;
// [MiSTer-DB9 END]

// [MiSTer-DB9-Pro BEGIN] - sibling Pro block
wire d = 1'b0;
// [MiSTer-DB9-Pro END]

endmodule
