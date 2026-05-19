// Tier-1 regression testbench for the canonical DB15 decoder.
//
// DUT = Forks_MiSTer/fork_ci_template/sys/joydb15.v (instantiated read-only
// from the canonical path; never copied/edited). This file is fork-only test
// infra under a downstream-only repo -> no MiSTer-DB9 markers.
//
// Strategy: joy_db15 samples JOY_DATA at its internal joy_count phase
// (joydb15.v:34-59). We model a perfectly-synchronised DB15 splitter as a
// white-box function of the DUT's own joy_count: at every instant JOY_DATA
// carries the active-low line for whatever button slot the DUT is about to
// store. A real 4021-style splitter that tracks JOY_CLK/JOY_LOAD presents
// exactly this; driving it off joy_count removes clock-phase guesswork so the
// assertions test the BIT MAP + inversion logic, which is the regression
// target. Output is active-high after the `~joy` invert at joydb15.v:62, so a
// pressed button => joystick bit 1 => stored joy bit 0 => JOY_DATA = 0.
//
// joystick[15:0] layout (per joydb15.v:35-58, "----LS FEDCBAUDLR"):
//   [0]R [1]L [2]Dn [3]Up [4]A [5]B [6]C [7]D [8]E [9]F [10]Start [11]Select
//   [15:12] always 0 (never sampled, stay at reset).

`timescale 1ns/1ps
`default_nettype none

module tb_joydb15;

  reg         clk = 1'b0;
  wire        JOY_CLK, JOY_LOAD;
  wire [15:0] joystick1, joystick2;

  // Per-player stimulus in joystick[11:0] layout. 1 = button pressed.
  reg [11:0] p1 = 12'h000;
  reg [11:0] p2 = 12'h000;

  integer errors = 0;

  // 50 MHz
  always #10 clk = ~clk;

  // joydb15.v's JCLOCKS free-running counter has no RTL initializer; on real
  // silicon it powers up to 0, in sim it is X and X+1 stays X (joy_tick never
  // fires). Seed it once to model FPGA power-on. White-box, sim-only.
  initial dut.JCLOCKS = 16'h0000;

  // White-box splitter model: map DUT joy_count -> stimulus bit, active-low.
  function automatic bit_for_count;
    input [4:0] cnt;
    reg b;
    begin
      case (cnt)
        5'd2 : b = p1[7];   // P1 D
        5'd3 : b = p1[6];   // P1 C
        5'd4 : b = p1[5];   // P1 B
        5'd5 : b = p1[4];   // P1 A
        5'd6 : b = p1[0];   // P1 Right
        5'd7 : b = p1[1];   // P1 Left
        5'd8 : b = p1[2];   // P1 Down
        5'd9 : b = p1[3];   // P1 Up
        5'd10: b = p2[0];   // P2 Right
        5'd11: b = p2[1];   // P2 Left
        5'd12: b = p2[2];   // P2 Down
        5'd13: b = p2[3];   // P2 Up
        5'd14: b = p1[9];   // P1 F
        5'd15: b = p1[8];   // P1 E
        5'd16: b = p1[11];  // P1 Select
        5'd17: b = p1[10];  // P1 Start
        5'd18: b = p2[9];   // P2 F
        5'd19: b = p2[8];   // P2 E
        5'd20: b = p2[11];  // P2 Select
        5'd21: b = p2[10];  // P2 Start
        5'd22: b = p2[7];   // P2 D
        5'd23: b = p2[6];   // P2 C
        5'd24: b = p2[5];   // P2 B
        5'd25: b = p2[4];   // P2 A
        default: b = 1'b0;  // counts 0,1: no button (idle line high below)
      endcase
      bit_for_count = ~b;   // active-low: pressed => line 0
    end
  endfunction

  wire JOY_DATA = bit_for_count(dut.joy_count);

  joy_db15 dut (
    .clk       ( clk       ),
    .JOY_CLK   ( JOY_CLK   ),
    .JOY_LOAD  ( JOY_LOAD  ),
    .JOY_DATA  ( JOY_DATA  ),
    .joystick1 ( joystick1 ),
    .joystick2 ( joystick2 )
  );

  task settle;             // > 2 full 26-slot frames at /16 per slot
    begin #200000; end     // 200 us @ 50 MHz clk
  endtask

  task check;
    input [127:0] name;
    input [15:0]  got;
    input [15:0]  exp;
    begin
      if (got !== exp) begin
        errors = errors + 1;
        $display("FAIL %0s: got %h expected %h", name, got, exp);
      end else begin
        $display("ok   %0s: %h", name, got);
      end
    end
  endtask

  task run_vec;
    input [127:0] name;
    input [11:0]  s1;
    input [11:0]  s2;
    begin
      p1 = s1; p2 = s2;
      settle;
      check({name, " P1"}, joystick1, {4'b0, s1});
      check({name, " P2"}, joystick2, {4'b0, s2});
    end
  endtask

  initial begin
    run_vec("idle",   12'h000, 12'h000);
    run_vec("p1_A",    12'h010, 12'h000);  // bit4
    run_vec("p1_Up",   12'h008, 12'h000);  // bit3
    run_vec("p1_UDLR", 12'h00F, 12'h000);
    run_vec("p1_Strt", 12'h400, 12'h000);  // bit10
    run_vec("p1_Sel",  12'h800, 12'h000);  // bit11
    run_vec("p2_B",    12'h000, 12'h020);  // bit5
    run_vec("both",    12'h555, 12'hAAA);
    run_vec("all",     12'hFFF, 12'hFFF);
    run_vec("clear",   12'h000, 12'h000);  // de-press returns to 0

    if (errors == 0) begin
      $display("TIER1 tb_joydb15: PASS");
      $finish;
    end else begin
      $display("TIER1 tb_joydb15: FAIL (%0d errors)", errors);
      $fatal;
    end
  end

endmodule

`default_nettype wire
