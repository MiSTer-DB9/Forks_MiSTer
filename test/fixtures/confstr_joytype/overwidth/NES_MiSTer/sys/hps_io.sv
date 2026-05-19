// minimal fixture hps_io: 128-bit status word (MSB 127).
module hps_io
(
	output reg [127:0] status,
	input  wire        clk
);
endmodule
