// SPDX-FileCopyrightText: © 2025 gf180mcu-peripherals Authors
// SPDX-License-Identifier: Apache-2.0
//
// chip_core — peripheral integration (M2: Ethernet + SDRAM).
//
// RMII Ethernet MAC + UDP stack (alexforencich verilog-ethernet) exposes a
// UDP->memory AXI4-Lite master. A small interconnect routes it by address to:
//   - slave 0 (addr[28]=0): on-chip scratch RAM (axil_ram), and
//   - slave 1 (addr[28]=1): external SDRAM via sdram_wrap (ultraembedded sdram_axi,
//     Winbond W9825G6KH x16).
// So a host writes/reads SDRAM over plain UDP. Single 50 MHz domain (clk = clk_PAD,
// forwarded to the PHY as the RMII reference clock).
//
// Pad map (1x1 slot, retyped to NUM_BIDIR=47 / NUM_INPUT=5):
//   input_in[0]=rmii_crs_dv [1]=rmii_rx_er [2]=rmii_rxd0 [3]=rmii_rxd1 [4]=mode_strap
//   bidir[0]=tx_en [1]=txd0 [2]=txd1 [3]=ref_clk [4..7]=eth LEDs
//   bidir[8..23]=SDRAM DQ[15:0] (bidirectional)   bidir[24]=sdram_clk [25]=cke
//   [26]=cs [27]=ras [28]=cas [29]=we [30]=dqm0 [31]=dqm1 [32..44]=A[12:0] [45]=ba0 [46]=ba1

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

    input  wire clk,       // 50 MHz
    input  wire rst_n,     // reset (active low)

    input  wire [NUM_INPUT_PADS-1:0] input_in,
    output wire [NUM_INPUT_PADS-1:0] input_pu,
    output wire [NUM_INPUT_PADS-1:0] input_pd,

    input  wire [NUM_BIDIR_PADS-1:0] bidir_in,
    output wire [NUM_BIDIR_PADS-1:0] bidir_out,
    output wire [NUM_BIDIR_PADS-1:0] bidir_oe,
    output wire [NUM_BIDIR_PADS-1:0] bidir_cs,
    output wire [NUM_BIDIR_PADS-1:0] bidir_sl,
    output wire [NUM_BIDIR_PADS-1:0] bidir_ie,
    output wire [NUM_BIDIR_PADS-1:0] bidir_pu,
    output wire [NUM_BIDIR_PADS-1:0] bidir_pd,

    inout  wire [NUM_ANALOG_PADS-1:0] analog
);
    wire rst = ~rst_n;   // active-high for imported (verilog-ethernet/sdram_axi) blocks

    // ---- RMII pad inputs ----
    wire        rmii_crs_dv = input_in[0];
    wire        rmii_rx_er  = input_in[1];
    wire [1:0]  rmii_rxd    = input_in[3:2];

    // ---- Ethernet UDP -> memory master (AXI4-Lite) ----
    wire        rmii_tx_en;
    wire [1:0]  rmii_txd;
    wire [7:0]  led;
    wire [31:0] m_awaddr, m_wdata, m_araddr, m_rdata;
    wire [2:0]  m_awprot, m_arprot;
    wire [3:0]  m_wstrb;
    wire [1:0]  m_bresp, m_rresp;
    wire        m_awvalid,m_awready,m_wvalid,m_wready,m_bvalid,m_bready,
                m_arvalid,m_arready,m_rvalid,m_rready;

    alexforencich_udp_memory_server #(.Target("GENERIC")) i_eth (
        .clk_i(clk), .rst_i(rst),
        .phy_rmii_ref_clk_i(clk), .phy_rmii_crsdv_i(rmii_crs_dv),
        .phy_rmii_rxer_i(rmii_rx_er), .phy_rmii_rxd_i(rmii_rxd),
        .phy_rmii_txen_o(rmii_tx_en), .phy_rmii_txd_o(rmii_txd),
        .m_mem_awaddr(m_awaddr), .m_mem_awprot(m_awprot), .m_mem_awvalid(m_awvalid), .m_mem_awready(m_awready),
        .m_mem_wdata(m_wdata), .m_mem_wstrb(m_wstrb), .m_mem_wvalid(m_wvalid), .m_mem_wready(m_wready),
        .m_mem_bresp(m_bresp), .m_mem_bvalid(m_bvalid), .m_mem_bready(m_bready),
        .m_mem_araddr(m_araddr), .m_mem_arprot(m_arprot), .m_mem_arvalid(m_arvalid), .m_mem_arready(m_arready),
        .m_mem_rdata(m_rdata), .m_mem_rresp(m_rresp), .m_mem_rvalid(m_rvalid), .m_mem_rready(m_rready),
        .led_o(led)
    );

    // ---- interconnect: master -> {slave0 scratch RAM, slave1 SDRAM} ----
    wire [31:0] s0_awaddr,s0_wdata,s0_araddr,s0_rdata, s1_awaddr,s1_wdata,s1_araddr,s1_rdata;
    wire [2:0]  s0_awprot,s0_arprot, s1_awprot,s1_arprot;
    wire [3:0]  s0_wstrb,s1_wstrb;
    wire [1:0]  s0_bresp,s0_rresp, s1_bresp,s1_rresp;
    wire s0_awvalid,s0_awready,s0_wvalid,s0_wready,s0_bvalid,s0_bready,s0_arvalid,s0_arready,s0_rvalid,s0_rready;
    wire s1_awvalid,s1_awready,s1_wvalid,s1_wready,s1_bvalid,s1_bready,s1_arvalid,s1_arready,s1_rvalid,s1_rready;

    axil_interconnect #(.SelBit(28)) i_ic (
        .u_awaddr_i(m_awaddr),.u_awprot_i(m_awprot),.u_awvalid_i(m_awvalid),.u_awready_o(m_awready),
        .u_wdata_i(m_wdata),.u_wstrb_i(m_wstrb),.u_wvalid_i(m_wvalid),.u_wready_o(m_wready),
        .u_bresp_o(m_bresp),.u_bvalid_o(m_bvalid),.u_bready_i(m_bready),
        .u_araddr_i(m_araddr),.u_arprot_i(m_arprot),.u_arvalid_i(m_arvalid),.u_arready_o(m_arready),
        .u_rdata_o(m_rdata),.u_rresp_o(m_rresp),.u_rvalid_o(m_rvalid),.u_rready_i(m_rready),
        .m0_awaddr_o(s0_awaddr),.m0_awprot_o(s0_awprot),.m0_awvalid_o(s0_awvalid),.m0_awready_i(s0_awready),
        .m0_wdata_o(s0_wdata),.m0_wstrb_o(s0_wstrb),.m0_wvalid_o(s0_wvalid),.m0_wready_i(s0_wready),
        .m0_bresp_i(s0_bresp),.m0_bvalid_i(s0_bvalid),.m0_bready_o(s0_bready),
        .m0_araddr_o(s0_araddr),.m0_arprot_o(s0_arprot),.m0_arvalid_o(s0_arvalid),.m0_arready_i(s0_arready),
        .m0_rdata_i(s0_rdata),.m0_rresp_i(s0_rresp),.m0_rvalid_i(s0_rvalid),.m0_rready_o(s0_rready),
        .m1_awaddr_o(s1_awaddr),.m1_awprot_o(s1_awprot),.m1_awvalid_o(s1_awvalid),.m1_awready_i(s1_awready),
        .m1_wdata_o(s1_wdata),.m1_wstrb_o(s1_wstrb),.m1_wvalid_o(s1_wvalid),.m1_wready_i(s1_wready),
        .m1_bresp_i(s1_bresp),.m1_bvalid_i(s1_bvalid),.m1_bready_o(s1_bready),
        .m1_araddr_o(s1_araddr),.m1_arprot_o(s1_arprot),.m1_arvalid_o(s1_arvalid),.m1_arready_i(s1_arready),
        .m1_rdata_i(s1_rdata),.m1_rresp_i(s1_rresp),.m1_rvalid_i(s1_rvalid),.m1_rready_o(s1_rready)
    );

    axil_ram #(.Words(256)) i_mem (
        .clk_i(clk),.rst_ni(rst_n),
        .s_awaddr_i(s0_awaddr),.s_awprot_i(s0_awprot),.s_awvalid_i(s0_awvalid),.s_awready_o(s0_awready),
        .s_wdata_i(s0_wdata),.s_wstrb_i(s0_wstrb),.s_wvalid_i(s0_wvalid),.s_wready_o(s0_wready),
        .s_bresp_o(s0_bresp),.s_bvalid_o(s0_bvalid),.s_bready_i(s0_bready),
        .s_araddr_i(s0_araddr),.s_arprot_i(s0_arprot),.s_arvalid_i(s0_arvalid),.s_arready_o(s0_arready),
        .s_rdata_o(s0_rdata),.s_rresp_o(s0_rresp),.s_rvalid_o(s0_rvalid),.s_rready_i(s0_rready)
    );

    // ---- SDRAM ----
    wire        sdram_clk_w,sdram_cke,sdram_cs,sdram_ras,sdram_cas,sdram_we,sdram_dq_oe;
    wire [1:0]  sdram_dqm,sdram_ba;
    wire [12:0] sdram_addr;
    wire [15:0] sdram_dq_o, sdram_dq_i;

    sdram_wrap i_sdram (
        .clk_i(clk),.rst_i(rst),
        .s_awaddr_i(s1_awaddr),.s_awprot_i(s1_awprot),.s_awvalid_i(s1_awvalid),.s_awready_o(s1_awready),
        .s_wdata_i(s1_wdata),.s_wstrb_i(s1_wstrb),.s_wvalid_i(s1_wvalid),.s_wready_o(s1_wready),
        .s_bresp_o(s1_bresp),.s_bvalid_o(s1_bvalid),.s_bready_i(s1_bready),
        .s_araddr_i(s1_araddr),.s_arprot_i(s1_arprot),.s_arvalid_i(s1_arvalid),.s_arready_o(s1_arready),
        .s_rdata_o(s1_rdata),.s_rresp_o(s1_rresp),.s_rvalid_o(s1_rvalid),.s_rready_i(s1_rready),
        .sdram_clk_o(sdram_clk_w),.sdram_cke_o(sdram_cke),.sdram_cs_o(sdram_cs),.sdram_ras_o(sdram_ras),
        .sdram_cas_o(sdram_cas),.sdram_we_o(sdram_we),.sdram_dqm_o(sdram_dqm),.sdram_addr_o(sdram_addr),
        .sdram_ba_o(sdram_ba),.sdram_dq_o(sdram_dq_o),.sdram_dq_oe_o(sdram_dq_oe),.sdram_dq_i(sdram_dq_i)
    );

    // ---- bidir pad outputs (see pad map above) ----
    assign bidir_out[0]     = rmii_tx_en;
    assign bidir_out[2:1]   = rmii_txd;
    assign bidir_out[3]     = clk;            // RMII ref_clk to PHY
    assign bidir_out[7:4]   = led[3:0];
    assign bidir_out[23:8]  = sdram_dq_o;
    assign bidir_out[24]    = sdram_clk_w;
    assign bidir_out[25]    = sdram_cke;
    assign bidir_out[26]    = sdram_cs;
    assign bidir_out[27]    = sdram_ras;
    assign bidir_out[28]    = sdram_cas;
    assign bidir_out[29]    = sdram_we;
    assign bidir_out[31:30] = sdram_dqm;
    assign bidir_out[44:32] = sdram_addr;
    assign bidir_out[46:45] = sdram_ba;

    // OE: SDRAM DQ tristated by the controller; everything else drives out.
    assign bidir_oe[7:0]    = 8'hFF;
    assign bidir_oe[23:8]   = {16{sdram_dq_oe}};
    assign bidir_oe[46:24]  = {23{1'b1}};

    assign sdram_dq_i       = bidir_in[23:8];

    assign bidir_cs = '0;
    assign bidir_sl = '0;
    assign bidir_ie = ~bidir_oe;
    assign bidir_pu = '0;
    assign bidir_pd = '0;

    // ---- input pad controls ----
    assign input_pu = '0;
    assign input_pd = '0;

    // ---- unused ----
    logic _unused;
    assign _unused = &{1'b0, led[7:4], input_in[NUM_INPUT_PADS-1:4],
                       bidir_in[7:0], bidir_in[NUM_BIDIR_PADS-1:24], analog};

endmodule

`default_nettype wire
