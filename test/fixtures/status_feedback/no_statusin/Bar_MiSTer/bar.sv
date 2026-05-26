// fixture: joy_type wrapper present, but the hps_io instance leaves
// .status_in unconnected (status_set always 0 -> no feedback path). The
// check should bail out at exit 2 (n/a fail-open).
module emu (input clk);

wire   [2:0] joy_type_raw    = status[127:125];
wire         snac_active     = 1'b0;
wire   [2:0] joy_type        = snac_active ? 3'd0 : joy_type_raw;

reg [127:0] status;

hps_io h (
    .status(status),
    .status_set(1'b0)
);

endmodule
