// fixture: same wrapper, but .status_in concat preserves status[127:8].
// The MegaDrive form. Expect PASS exit 0.
module emu (input clk);

wire   [2:0] joy_type_raw    = status[127:125];
wire         snac_active     = 1'b0;
wire   [2:0] joy_type        = snac_active ? 3'd0 : joy_type_raw;

reg [127:0] status;
wire        region_set;
wire  [1:0] region_req;

hps_io h (
    .status(status),
    .status_in({status[127:8], region_req, status[5:0]}),
    .status_set(region_set)
);

endmodule
