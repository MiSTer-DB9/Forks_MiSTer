// fixture: 3-bit joy_type wrapper (status[127:125]) but .status_in concat
// truncates at bit 63 -> region_set zeros joy_type / joy_2p. The real
// Genesis.sv:440 bug. Expect FATAL exit 1.
module emu (input clk);

wire   [2:0] joy_type_raw    = status[127:125];
wire         snac_active     = 1'b0;
wire   [2:0] joy_type        = snac_active ? 3'd0 : joy_type_raw;

reg [127:0] status;
wire        region_set;
wire  [1:0] region_req;

hps_io h (
    .status(status),
    .status_in({status[63:8], region_req, status[5:0]}),
    .status_set(region_set)
);

endmodule
