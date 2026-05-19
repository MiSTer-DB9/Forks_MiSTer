// fixture: bracket-form CONF_STR aligned with the joy_type/joy_2p decode.
// Expect ok, exit 0.
module emu (input clk);
localparam CONF_STR = {
	"NES;;",
	"d4P2O[127:126],UserIO Joystick,Off,Saturn,DB9MD,DB15;",
	"d4P2O[125],UserIO Players, 1 Player,2 Players;",
	"V,v1;"
};
wire   [1:0] joy_type_raw = status[127:126];
wire         joy_2p       = status[125];
endmodule
