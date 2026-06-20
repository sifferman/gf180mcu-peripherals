// Register a bus on the FALLING edge of a clock (a half-cycle delay).
//
// Generic and project-independent.  One use is source-synchronous outputs that
// must be launched half a clock before the receiver's rising sampling edge.

module delay_to_negedge #(
    parameter int unsigned Width = 1
) (
    input  wire             clk_i,
    input  wire [Width-1:0] d_i,
    output wire [Width-1:0] q_o
);
    logic [Width-1:0] q = '0;
    always_ff @(negedge clk_i) q <= d_i;
    assign q_o = q;
endmodule
