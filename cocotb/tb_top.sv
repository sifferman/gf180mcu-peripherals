// SPDX-License-Identifier: Apache-2.0
//
// Simulation wrapper: breaks the RMII / LED signals out of chip_top's pad
// vectors into individual nets so cocotb (and cocotbext-eth's RmiiPhy) can drive
// them.  Used for both RTL (`make sim`) and gate-level (`make sim-gl`) runs —
// in GL the instantiated chip_top is the post-layout netlist.
//
// Pad map must match src/chip_core.sv.

`default_nettype none

module tb_top (
    input  wire        clk,      // = clk_PAD, the 50 MHz RMII reference / core clock
    input  wire        rst_n,    // = rst_n_PAD
    input  wire        crs_dv,
    input  wire        rx_er,
    input  wire [1:0]  rxd,
    output wire        tx_en,
    output wire [1:0]  txd,
    output wire        ref_clk,
    output wire [7:0]  leds
);
    wire [11:0] input_PAD;
    wire [39:0] bidir_PAD;
    wire [1:0]  analog_PAD;

    // Drive the DUT's input pads.
    assign input_PAD[0]    = crs_dv;
    assign input_PAD[1]    = rx_er;
    assign input_PAD[3:2]  = rxd;
    assign input_PAD[11:4] = 8'b0;

    // Observe the DUT's bidir pads.
    assign tx_en   = bidir_PAD[0];
    assign txd     = bidir_PAD[2:1];
    assign ref_clk = bidir_PAD[3];
    assign leds    = bidir_PAD[11:4];

`ifdef USE_POWER_PINS
    wire VDD, VSS, DVDD, DVSS;
    assign VDD  = 1'b1;
    assign DVDD = 1'b1;
    assign VSS  = 1'b0;
    assign DVSS = 1'b0;
`endif

    chip_top dut (
`ifdef USE_POWER_PINS
        .VDD   (VDD),
        .VSS   (VSS),
        .DVDD  (DVDD),
        .DVSS  (DVSS),
`endif
        .clk_PAD    (clk),
        .rst_n_PAD  (rst_n),
        .input_PAD  (input_PAD),
        .bidir_PAD  (bidir_PAD),
        .analog_PAD (analog_PAD)
    );
endmodule

`default_nettype wire
