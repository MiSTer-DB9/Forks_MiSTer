// fixture: no sys/joydb9saturn.v -> not Saturn-capable -> n/a exit 0
module emu (input clk);
joydb joydb (
    .clk(clk),
    .saturn_unlocked(1'b1)
);
endmodule
