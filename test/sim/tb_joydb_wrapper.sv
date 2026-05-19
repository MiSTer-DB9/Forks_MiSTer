// Tier-1 regression testbench for the canonical unified wrapper.
//
// DUT = Forks_MiSTer/fork_ci_template/sys/joydb.sv driving the real
// joy_db15 instance underneath. Validates the porting contract that every
// ported <core>.sv depends on: in DB15 mode (joy_type=2'd3) joydb_1/joydb_2
// carry the decoded DB15 state, *_ena assert, USER_PP_DRIVE/USER_OUT_DRIVE
// take the DB15 patterns; in Off mode everything is inert. DB15 arm is NOT
// key-gated so saturn_unlocked is tied 0 (no crypto needed).
//
// Fork-only test infra, downstream-only repo -> no MiSTer-DB9 markers.

`timescale 1ns/1ps

module tb_joydb_wrapper;

  logic        clk = 1'b0;
  logic [7:0]  USER_IN;
  logic [1:0]  joy_type;
  logic        joy_2p;
  logic [7:0]  USER_OUT_DRIVE, USER_PP_DRIVE;
  logic        USER_OSD;
  logic [15:0] joydb_1, joydb_2;
  logic        joydb_1ena, joydb_2ena;
  logic [15:0] joy_raw;

  logic [11:0] p1 = 12'h000, p2 = 12'h000;
  integer errors = 0;

  always #10 clk = ~clk;

  // Seed the inner DB15 free-running counter (no RTL init; FPGA powers to 0).
  initial dut.joy_db15_i.JCLOCKS = 16'h0000;

  // White-box DB15 splitter model on USER_IN[5] (= JOY_DATA when joy_db15_en),
  // synchronised to the inner decoder's joy_count. Idle high on other pins.
  function automatic logic db15_bit(input logic [4:0] cnt);
    logic b;
    case (cnt)
      5'd2 : b = p1[7];  5'd3 : b = p1[6];  5'd4 : b = p1[5];  5'd5 : b = p1[4];
      5'd6 : b = p1[0];  5'd7 : b = p1[1];  5'd8 : b = p1[2];  5'd9 : b = p1[3];
      5'd10: b = p2[0];  5'd11: b = p2[1];  5'd12: b = p2[2];  5'd13: b = p2[3];
      5'd14: b = p1[9];  5'd15: b = p1[8];  5'd16: b = p1[11]; 5'd17: b = p1[10];
      5'd18: b = p2[9];  5'd19: b = p2[8];  5'd20: b = p2[11]; 5'd21: b = p2[10];
      5'd22: b = p2[7];  5'd23: b = p2[6];  5'd24: b = p2[5];  5'd25: b = p2[4];
      default: b = 1'b0;
    endcase
    return ~b;  // active-low line
  endfunction

  always_comb begin
    USER_IN    = 8'hFF;
    USER_IN[5] = db15_bit(dut.joy_db15_i.joy_count);
  end

  joydb dut (
    .clk             ( clk            ),
    .USER_IN         ( USER_IN        ),
    .joy_type        ( joy_type       ),
    .joy_2p          ( joy_2p         ),
    .saturn_unlocked ( 1'b0           ),
    .USER_OUT_DRIVE  ( USER_OUT_DRIVE ),
    .USER_PP_DRIVE   ( USER_PP_DRIVE  ),
    .USER_OSD        ( USER_OSD       ),
    .joydb_1         ( joydb_1        ),
    .joydb_2         ( joydb_2        ),
    .joydb_1ena      ( joydb_1ena     ),
    .joydb_2ena      ( joydb_2ena     ),
    .joy_raw         ( joy_raw        )
  );

  task automatic chk(input string n, input logic [31:0] got, input logic [31:0] exp);
    if (got !== exp) begin
      errors++; $display("FAIL %s: got %h expected %h", n, got, exp);
    end else $display("ok   %s: %h", n, got);
  endtask

  initial begin
    // ---- Off mode: everything inert ----
    joy_type = 2'd0; joy_2p = 1'b0; p1 = 12'h3FF; p2 = 12'h3FF;
    #200000;
    chk("off joydb_1",    joydb_1,            16'h0000);
    chk("off joydb_2",    joydb_2,            16'h0000);
    chk("off ena1",       joydb_1ena,         1'b0);
    chk("off ena2",       joydb_2ena,         1'b0);
    chk("off USER_PP",    USER_PP_DRIVE,      8'b00000000);
    chk("off USER_OUT",   USER_OUT_DRIVE,     8'hFF);
    chk("off joy_raw",    joy_raw,            16'h0000);

    // ---- DB15 1P: P1 decodes, P2 disabled ----
    joy_type = 2'd3; joy_2p = 1'b0; p1 = 12'h195; p2 = 12'h2AA;
    #200000;
    chk("db15-1p joydb_1", joydb_1,           {4'b0, 12'h195});
    chk("db15-1p ena1",    joydb_1ena,        1'b1);
    chk("db15-1p ena2",    joydb_2ena,        1'b0);
    chk("db15-1p USER_PP", USER_PP_DRIVE,     8'b00000011);
    // USER_OUT_DRIVE = {6'b111111, JOY_CLK, JOY_LOAD}: top 6 bits constant 1.
    chk("db15-1p UO[7:2]", USER_OUT_DRIVE[7:2], 6'b111111);
    chk("db15-1p jr_type", joy_raw[15:14],    2'd3);

    // ---- DB15 2P: both decode, P2 enabled ----
    joy_type = 2'd3; joy_2p = 1'b1; p1 = 12'h111; p2 = 12'h222;
    #200000;
    chk("db15-2p joydb_1", joydb_1,           {4'b0, 12'h111});
    chk("db15-2p joydb_2", joydb_2,           {4'b0, 12'h222});
    chk("db15-2p ena2",    joydb_2ena,        1'b1);

    // ---- USER_OSD = joydb_1[10] & joydb_1[6] (Start+C) ----
    joy_type = 2'd3; joy_2p = 1'b0; p1 = 12'h440; p2 = 12'h000; // bits 10 & 6
    #200000;
    chk("osd combo",       USER_OSD,          1'b1);
    p1 = 12'h400;          // only Start
    #200000;
    chk("osd not-combo",   USER_OSD,          1'b0);

    if (errors == 0) begin
      $display("TIER1 tb_joydb_wrapper: PASS"); $finish;
    end else begin
      $display("TIER1 tb_joydb_wrapper: FAIL (%0d errors)", errors); $fatal;
    end
  end

endmodule
