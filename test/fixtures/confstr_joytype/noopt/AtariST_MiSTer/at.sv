// fixture: Template-B/C computer core — has a joy_type decode wire but NO
// `UserIO Joystick` CONF_STR option (joy_type mirrored from Main_MiSTer's
// ext_ctrl into status[63:62], not menu-written). Must be n/a, exit 0, NOT
// a false FATAL.
module emu (input clk);
localparam CONF_STR = {
	"ATARIST;;",
	"OUV,Video Mode,Color,Mono;",
	"V,v1;"
};
wire   [1:0] joy_type = status[63:62];
wire         joy_2p   = status[61];
endmodule
