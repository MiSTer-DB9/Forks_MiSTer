// fixture: truncated .status_in concat that spans multiple lines (some
// upstream cores wrap their concat for readability). The balanced-paren
// scanner + DOTALL slice regex must still classify FATAL.
module emu (input clk);

wire   [2:0] joy_type_raw    = status[127:125];

reg [127:0] status;
wire        region_set;
wire  [1:0] region_req;

hps_io h (
    .status(status),
    .status_in({
        status[63:32],
        status[31:8],
        region_req,
        status[5:0]
    }),
    .status_set(region_set)
);

endmodule
