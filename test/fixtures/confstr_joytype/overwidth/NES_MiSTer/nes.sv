// fixture: a CONF_STR option references status[200] but sys/hps_io.sv
// declares only status[127:0]. Expect FATAL (over-width), exit 1.
module emu (input clk);
localparam CONF_STR = {
	"NES;;",
	"d4P2O[127:126],UserIO Joystick,Off,Saturn,DB9MD,DB15;",
	"O[200],Bogus Wide Option,No,Yes;",
	"V,v1;"
};
wire   [1:0] joy_type_raw = status[127:126];
endmodule
