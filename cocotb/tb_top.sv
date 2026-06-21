// SPDX-License-Identifier: Apache-2.0
//
// Simulation wrapper: breaks the RMII / LED signals out of chip_top's pad vectors
// so cocotb (cocotbext-eth RmiiPhy) can drive them. Used for RTL (`make sim`) and
// gate-level (`make sim-gl`). Pad map must match src/chip_core.sv (M2: 5 input,
// 47 bidir). The SDRAM pads (bidir[8..46]) are left unconnected here — the gold-path
// test exercises the on-chip scratch RAM region; the SDRAM datapath is covered by
// cocotb/models/tb_m2_fabric.v.

`default_nettype none

module tb_top (
    input  wire        clk,      // = clk_PAD (50 MHz RMII ref / core clock)
    input  wire        rst_n,    // = rst_n_PAD
    input  wire        crs_dv,
    input  wire        rx_er,
    input  wire [1:0]  rxd,
    output wire        tx_en,
    output wire [1:0]  txd,
    output wire        ref_clk,
    output wire [3:0]  leds
);
    wire [4:0]  input_PAD;
    wire [46:0] bidir_PAD;
    wire [1:0]  analog_PAD;

    // Drive DUT input pads.
    assign input_PAD[0]   = crs_dv;
    assign input_PAD[1]   = rx_er;
    assign input_PAD[3:2] = rxd;
    assign input_PAD[4]   = 1'b0;   // mode strap

    // Observe DUT bidir pads.
    assign tx_en   = bidir_PAD[0];
    assign txd     = bidir_PAD[2:1];
    assign ref_clk = bidir_PAD[3];
    assign leds    = bidir_PAD[7:4];

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
