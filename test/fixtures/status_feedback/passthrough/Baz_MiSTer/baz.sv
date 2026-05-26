// fixture: joy_type wrapper present, .status_in(status) pass-through
// (whole-bus feedback, all bits preserved). Expect PASS exit 0.
module emu (input clk);

wire   [2:0] joy_type_raw    = status[127:125];
wire         snac_active     = 1'b0;
wire   [2:0] joy_type        = snac_active ? 3'd0 : joy_type_raw;

reg [127:0] status;
wire        region_set;

hps_io h (
    .status(status),
    .status_in(status),
    .status_set(region_set)
);

endmodule
