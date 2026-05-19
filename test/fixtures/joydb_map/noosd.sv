// fixture: missing OSD_STATUS guard on a controller-data arm -> ghost
// inputs reach the core/OSD while the menu is open. Expect FATAL, exit 1.
module emu (input clk);
wire [15:0] joystick_0 = joydb_1ena ? {joydb_1[11],joydb_1[10],joydb_1[4:0]} : joystick_0_USB;
endmodule
