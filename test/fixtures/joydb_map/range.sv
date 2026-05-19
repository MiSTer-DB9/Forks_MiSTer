// fixture: out-of-range bit. joydb_1/joydb_2 bits 15:14 are never live; a
// [15:0] / [14] reference is a wiring bug. Expect FATAL, exit 1.
module emu (input clk);
wire [31:0] joystick_0 = joydb_1ena ? (OSD_STATUS ? 32'b0 : {joydb_1[15:0]}) : joystick_0_USB;
endmodule
