// fixture: verified true-negatives that MUST stay PASS (zero-FP anchors).
module emu (input clk);
  reg [3:0] MD_ID, INT_MASK;
  reg a, b, allow_us;
  reg [31:0] applied_period, Addr;
  always @* begin
    // correct comparison on both sides -> not a bare operand
    if (MD_ID == 4'hF || MD_ID == 4'hA) a = 1'b1;
    // literal heads a relational sub-expr (terminator test: `>` not a stop)
    if (a && 4'hF > INT_MASK) b = 1'b1;
    if (b && 4'd15 > INT_MASK) a = 1'b0;
    // identity / default operand -> value guard (0/1) excludes
    a = b || 1'b0;
    b = a && 1;
    // parenthesised literal is a sub-expression, not a bare operand
    if ((a || b) || (4'hA != MD_ID)) a = 1'b1;
    // legit comparisons with literals, no bare ||/&& operand
    if (Addr == 0 || Addr == 3) b = 1'b1;
    if (applied_period > 1 || allow_us) a = 1'b1;
    // a `||`/`&&` in a string / comment must be masked: "x || 4'hF"
    if (a) $display("dead || 4 here");
  end
endmodule
