// fixture: clean joydb mux. joydb_1ena arm reads only joydb_1 (OSD-guarded),
// joydb_2ena arm reads only joydb_2, both reference the same bit set.
module emu (input clk);
wire [31:0] joystick_0 = joydb_1ena ? (OSD_STATUS ? 32'b0 : {joydb_1[11],joydb_1[9],joydb_1[10],joydb_1[4:0]}) : joystick_0_USB;
wire [31:0] joystick_1 = joydb_2ena ? (OSD_STATUS ? 32'b0 : {joydb_2[11],joydb_2[10],joydb_2[9],joydb_2[4:0]}) : joydb_1ena ? joystick_0_USB : joystick_1_USB;
endmodule
