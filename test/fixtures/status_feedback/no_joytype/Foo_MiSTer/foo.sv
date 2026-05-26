// fixture: no joy_type wrapper at all (un-ported / bespoke core). The
// check should bail out at exit 2 (n/a fail-open) regardless of what
// .status_in does, because there is nothing DB9-specific to protect.
module emu (input clk);

reg [127:0] status;
wire        region_set;
wire  [1:0] region_req;

hps_io h (
    .status(status),
    .status_in({status[63:8], region_req, status[5:0]}),
    .status_set(region_set)
);

endmodule
