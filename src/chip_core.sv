// SPDX-FileCopyrightText: © 2025 gf180mcu-peripherals Authors
// SPDX-License-Identifier: Apache-2.0
//
// chip_core — peripheral integration for the GF180MCU test chip.
//
// M1 gold path: an RMII Ethernet MAC + UDP stack (alexforencich verilog-ethernet)
// exposes a UDP->memory datapath whose AXI4-Lite master writes/reads an on-chip
// RAM.  A host PC drives it over plain UDP (see ethernet-host/dma.py and the
// cocotb testbench).  SDRAM, SD card and the digital PLL land on the same AXI
// fabric / pad mux in later milestones.
//
// Single 50 MHz clock domain (clk = clk_PAD); the chip forwards clk to the PHY
// as the RMII reference clock.
//
// Pad map (M1, stock padring — no retype yet):
//   input_in[0] = rmii_crs_dv   input_in[1] = rmii_rx_er
//   input_in[2] = rmii_rxd[0]   input_in[3] = rmii_rxd[1]
//   bidir[0] = rmii_tx_en  bidir[1] = rmii_txd[0]  bidir[2] = rmii_txd[1]
//   bidir[3] = rmii_ref_clk (forwarded clk)
//   bidir[11:4] = eth status LEDs (led_o[7:0])

`default_nettype none

module chip_core #(
    parameter NUM_INPUT_PADS,
    parameter NUM_BIDIR_PADS,
    parameter NUM_ANALOG_PADS
    )(
    `ifdef USE_POWER_PINS
    inout  wire VDD,
    inout  wire VSS,
    `endif

    input  wire clk,       // 50 MHz clock
    input  wire rst_n,     // reset (active low)

    input  wire [NUM_INPUT_PADS-1:0] input_in,   // Input value
    output wire [NUM_INPUT_PADS-1:0] input_pu,   // Pull-up
    output wire [NUM_INPUT_PADS-1:0] input_pd,   // Pull-down

    input  wire [NUM_BIDIR_PADS-1:0] bidir_in,   // Input value
    output wire [NUM_BIDIR_PADS-1:0] bidir_out,  // Output value
    output wire [NUM_BIDIR_PADS-1:0] bidir_oe,   // Output enable
    output wire [NUM_BIDIR_PADS-1:0] bidir_cs,   // Input type (0=CMOS, 1=Schmitt)
    output wire [NUM_BIDIR_PADS-1:0] bidir_sl,   // Slew rate (0=fast, 1=slow)
    output wire [NUM_BIDIR_PADS-1:0] bidir_ie,   // Input enable
    output wire [NUM_BIDIR_PADS-1:0] bidir_pu,   // Pull-up
    output wire [NUM_BIDIR_PADS-1:0] bidir_pd,   // Pull-down

    inout  wire [NUM_ANALOG_PADS-1:0] analog  // Analog
);

    // Active-high reset for the imported (verilog-ethernet) blocks.
    wire rst = ~rst_n;

    // ---- RMII pad inputs ----
    wire rmii_crs_dv = input_in[0];
    wire rmii_rx_er  = input_in[1];
    wire [1:0] rmii_rxd = input_in[3:2];

    // ---- Ethernet UDP -> memory datapath ----
    wire        rmii_tx_en;
    wire [1:0]  rmii_txd;
    wire [7:0]  led;

    // AXI4-Lite master (eth) -> slave (on-chip RAM)
    wire [31:0] mem_awaddr;
    wire [2:0]  mem_awprot;
    wire        mem_awvalid, mem_awready;
    wire [31:0] mem_wdata;
    wire [3:0]  mem_wstrb;
    wire        mem_wvalid, mem_wready;
    wire [1:0]  mem_bresp;
    wire        mem_bvalid, mem_bready;
    wire [31:0] mem_araddr;
    wire [2:0]  mem_arprot;
    wire        mem_arvalid, mem_arready;
    wire [31:0] mem_rdata;
    wire [1:0]  mem_rresp;
    wire        mem_rvalid, mem_rready;

    alexforencich_udp_memory_server #(
        .Target("GENERIC")
    ) i_eth (
        .clk_i              (clk),
        .rst_i              (rst),
        .phy_rmii_ref_clk_i (clk),
        .phy_rmii_crsdv_i   (rmii_crs_dv),
        .phy_rmii_rxer_i    (rmii_rx_er),
        .phy_rmii_rxd_i     (rmii_rxd),
        .phy_rmii_txen_o    (rmii_tx_en),
        .phy_rmii_txd_o     (rmii_txd),
        .m_mem_awaddr       (mem_awaddr),
        .m_mem_awprot       (mem_awprot),
        .m_mem_awvalid      (mem_awvalid),
        .m_mem_awready      (mem_awready),
        .m_mem_wdata        (mem_wdata),
        .m_mem_wstrb        (mem_wstrb),
        .m_mem_wvalid       (mem_wvalid),
        .m_mem_wready       (mem_wready),
        .m_mem_bresp        (mem_bresp),
        .m_mem_bvalid       (mem_bvalid),
        .m_mem_bready       (mem_bready),
        .m_mem_araddr       (mem_araddr),
        .m_mem_arprot       (mem_arprot),
        .m_mem_arvalid      (mem_arvalid),
        .m_mem_arready      (mem_arready),
        .m_mem_rdata        (mem_rdata),
        .m_mem_rresp        (mem_rresp),
        .m_mem_rvalid       (mem_rvalid),
        .m_mem_rready       (mem_rready),
        .led_o              (led)
    );

    axil_ram #(
        .AddrWidth (32),
        .Words     (256) // 1 KiB scratch target for the gold path
    ) i_mem (
        .clk_i       (clk),
        .rst_ni      (rst_n),
        .s_awaddr_i  (mem_awaddr),
        .s_awprot_i  (mem_awprot),
        .s_awvalid_i (mem_awvalid),
        .s_awready_o (mem_awready),
        .s_wdata_i   (mem_wdata),
        .s_wstrb_i   (mem_wstrb),
        .s_wvalid_i  (mem_wvalid),
        .s_wready_o  (mem_wready),
        .s_bresp_o   (mem_bresp),
        .s_bvalid_o  (mem_bvalid),
        .s_bready_i  (mem_bready),
        .s_araddr_i  (mem_araddr),
        .s_arprot_i  (mem_arprot),
        .s_arvalid_i (mem_arvalid),
        .s_arready_o (mem_arready),
        .s_rdata_o   (mem_rdata),
        .s_rresp_o   (mem_rresp),
        .s_rvalid_o  (mem_rvalid),
        .s_rready_i  (mem_rready)
    );

    // ---- bidir pad drive ----
    // bidir[0]=tx_en, [1..2]=txd, [3]=ref_clk, [11:4]=LEDs; rest unused outputs.
    wire [NUM_BIDIR_PADS-1:0] bidir_drive;
    assign bidir_drive = {
        {(NUM_BIDIR_PADS-12){1'b0}},
        led,            // [11:4]
        clk,            // [3] forwarded RMII reference clock
        rmii_txd,       // [2:1]
        rmii_tx_en      // [0]
    };
    assign bidir_out = bidir_drive;
    assign bidir_oe  = '1;        // all bidir driven as outputs in M1
    assign bidir_cs  = '0;
    assign bidir_sl  = '0;
    assign bidir_ie  = ~bidir_oe;
    assign bidir_pu  = '0;
    assign bidir_pd  = '0;

    // ---- input pad controls ----
    assign input_pu = '0;
    assign input_pd = '0;

    // ---- unused signals ----
    logic _unused;
    assign _unused = &{1'b0, bidir_in, input_in[NUM_INPUT_PADS-1:4], analog};

endmodule

`default_nettype wire
