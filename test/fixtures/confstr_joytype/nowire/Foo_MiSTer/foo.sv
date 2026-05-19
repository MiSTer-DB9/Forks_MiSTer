// fixture: bespoke / pre-wrapper core with no joy_type[_raw] decode wire.
// Must be n/a, exit 0 (no false positive — same contract as snac/mt32).
module emu (input clk);
localparam CONF_STR = {
	"FOO;;",
	"O[5],Some Toggle,Off,On;"
};
endmodule
