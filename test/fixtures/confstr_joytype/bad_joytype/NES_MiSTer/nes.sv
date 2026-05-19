// fixture: the NES 7fc497b regression — CONF_STR left at the legacy letter
// form `oUV` (= status[63:62]) while the decode reads status[127:126]. The
// menu writes bits the decode never reads -> controller silently dead.
// Expect FATAL, exit 1.
module emu (input clk);
localparam CONF_STR = {
	"NES;;",
	"d4P2oUV,UserIO Joystick,Off,Saturn,DB9MD,DB15;",
	"d4P2O[125],UserIO Players, 1 Player,2 Players;"
};
wire   [1:0] joy_type_raw = status[127:126];
wire         joy_2p       = status[125];
endmodule
