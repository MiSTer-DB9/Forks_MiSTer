// fixture: pre-PSX 2-bit joy_type form (`wire [1:0] joy_type =
// status[127:126]`) with truncated .status_in -> still FATAL because
// joy_type bits 127:126 are zeroed on region_set. Covers cores that haven't
// been re-ported to the 3-bit wrapper but still have the Saturn joy_type
// (which can resurface during a partial port). Expect FATAL exit 1.
module emu (input clk);

wire [1:0] joy_type = status[127:126];
wire       joy_2p   = status[125];

reg [127:0] status;
wire        region_set;
wire  [1:0] region_req;

hps_io h (
    .status(status),
    .status_in({status[63:8], region_req, status[5:0]}),
    .status_set(region_set)
);

endmodule
