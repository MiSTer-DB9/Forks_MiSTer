// fixture: severed block -- BEGIN never closed (porter/merge dropped END)
module emu (
    input clk
);

// [MiSTer-DB9 BEGIN] - never closed
wire a = 1'b0;

endmodule
