// fixture: joystick option aligned, but UserIO Players writes status[124]
// while joy_2p is decoded from status[125]. Expect FATAL, exit 1.
module emu (input clk);
localparam CONF_STR = {
	"NES;;",
	"d4P2O[127:126],UserIO Joystick,Off,Saturn,DB9MD,DB15;",
	"d4P2O[124],UserIO Players, 1 Player,2 Players;"
};
wire   [1:0] joy_type_raw = status[127:126];
wire         joy_2p       = status[125];
endmodule
