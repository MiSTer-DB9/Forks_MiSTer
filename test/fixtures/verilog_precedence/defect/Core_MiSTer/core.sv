// fixture: the 3a94b0a shape -- bare non-zero literal as whole ||/&& operand.
module emu (input clk);
  reg [3:0] MD_ID;
  reg st;
  always @* begin
    // (MD_ID == 4'hF) || (4'hA)  -> constant-true, the else arm is dead
    if (MD_ID == 4'hF || 4'hA) st <= 1'b1;
    else st <= 1'b0;
  end
endmodule
