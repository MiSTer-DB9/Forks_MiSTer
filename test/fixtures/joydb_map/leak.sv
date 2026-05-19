// fixture: P1/P2 leak (ao486 2b63c66 class). joydb_2ena arm reads joydb_1
// data -> player 2 mirrors player 1. Expect FATAL, exit 1.
module emu (input clk);
wire [31:0] joystick_0 = joydb_1ena ? (OSD_STATUS ? 32'b0 : {joydb_1[5:0]}) : joystick_0_USB;
wire [31:0] joystick_1 = joydb_2ena ? (OSD_STATUS ? 32'b0 : {joydb_1[5:0]}) : joydb_1ena ? joystick_0_USB : joystick_1_USB;
endmodule
