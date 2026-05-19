// fixture: legacy uppercase letter form `OUV` (U=30, V=31 -> status[31:30])
// aligned with a status[31:30] decode. Validates the letter-form decoder
// path (a matched legacy form must NOT FATAL). Expect ok, exit 0.
module emu (input clk);
localparam CONF_STR = {
	"BAR;;",
	"P2OUV,UserIO Joystick,Off,Saturn,DB9MD,DB15;",
	"P2OT,UserIO Players, 1 Player,2 Players;"
};
wire   [1:0] joy_type = status[31:30];
wire         joy_2p   = status[29];
endmodule
