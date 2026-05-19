// fixture: P1/P2 bit-SET divergence (Arcade-Tecmo class) -- P2 drops bit
// [9] that P1 uses, so the players reference different buttons (not just a
// reorder). Expect exit 0 with a FINDING line (non-gating).
module emu (input clk);
wire [15:0] joystick_0 = joydb_1ena ? (OSD_STATUS ? 16'b0 : {joydb_1[11],joydb_1[9],joydb_1[10],joydb_1[6:0]}) : joystick_0_USB;
wire [15:0] joystick_1 = joydb_2ena ? (OSD_STATUS ? 16'b0 : {joydb_2[11],joydb_2[10],joydb_2[6:0]}) : joydb_1ena ? joystick_0_USB : joystick_1_USB;
endmodule
