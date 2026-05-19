// fixture: core with no MT32-pi support. No mt32pi / USER_*_MT32 / mt32_use
// tokens -> the check is n/a (never a false skip: non-MT32 cores never
// carry these tokens). Expect n/a, exit 0.
module emu (input clk);
wire [7:0] USER_OUT_DRIVE = 8'hFF;
assign USER_OUT = USER_OUT_DRIVE;
endmodule
