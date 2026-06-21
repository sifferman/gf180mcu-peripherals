// SPDX-License-Identifier: Apache-2.0
//
// SDRAM block: ultraembedded sdram_axi (AXI4) + an AXI4-Lite front end, exposing
// the SDRAM pins split into output / output-enable / input so chip_top can drive a
// bidirectional DQ pad. Targets the Winbond W9825G6KH (x16, 13-row/9-col/2-bank);
// sdram_axi's default geometry (SDRAM_ADDR_W=24, COL_W=9) matches it.
//
// Functional sim: drive against cocotb/models/sdram_sim.v (Icarus) or the encrypted
// Winbond model (VCS). See cocotb/models/tb_sdram.v.

`default_nettype none

module sdram_wrap (
    input  wire        clk_i,
    input  wire        rst_i,           // active-high (matches sdram_axi)

    // AXI4-Lite slave (from the on-chip interconnect)
    input  wire [31:0] s_awaddr_i,
    input  wire [2:0]  s_awprot_i,
    input  wire        s_awvalid_i,
    output wire        s_awready_o,
    input  wire [31:0] s_wdata_i,
    input  wire [3:0]  s_wstrb_i,
    input  wire        s_wvalid_i,
    output wire        s_wready_o,
    output wire [1:0]  s_bresp_o,
    output wire        s_bvalid_o,
    input  wire        s_bready_i,
    input  wire [31:0] s_araddr_i,
    input  wire [2:0]  s_arprot_i,
    input  wire        s_arvalid_i,
    output wire        s_arready_o,
    output wire [31:0] s_rdata_o,
    output wire [1:0]  s_rresp_o,
    output wire        s_rvalid_o,
    input  wire        s_rready_i,

    // SDRAM device pins (DQ split for a bidirectional pad)
    output wire        sdram_clk_o,
    output wire        sdram_cke_o,
    output wire        sdram_cs_o,
    output wire        sdram_ras_o,
    output wire        sdram_cas_o,
    output wire        sdram_we_o,
    output wire [1:0]  sdram_dqm_o,
    output wire [12:0] sdram_addr_o,
    output wire [1:0]  sdram_ba_o,
    output wire [15:0] sdram_dq_o,      // -> pad A
    output wire        sdram_dq_oe_o,   // -> pad OE (1 = drive)
    input  wire [15:0] sdram_dq_i       // <- pad Y
);
    // AXI4-Lite -> AXI4 (single beat)
    wire [31:0] ax_awaddr;  wire [3:0] ax_awid; wire [7:0] ax_awlen; wire [1:0] ax_awburst;
    wire        ax_awvalid, ax_awready;
    wire [31:0] ax_wdata;   wire [3:0] ax_wstrb; wire ax_wlast, ax_wvalid, ax_wready;
    wire [1:0]  ax_bresp;   wire ax_bvalid, ax_bready;
    wire [31:0] ax_araddr;  wire [3:0] ax_arid; wire [7:0] ax_arlen; wire [1:0] ax_arburst;
    wire        ax_arvalid, ax_arready;
    wire [31:0] ax_rdata;   wire [1:0] ax_rresp; wire ax_rvalid, ax_rready;

    axil_to_axi4 u_adapt (
        .s_awaddr_i, .s_awprot_i, .s_awvalid_i, .s_awready_o,
        .s_wdata_i, .s_wstrb_i, .s_wvalid_i, .s_wready_o,
        .s_bresp_o, .s_bvalid_o, .s_bready_i,
        .s_araddr_i, .s_arprot_i, .s_arvalid_i, .s_arready_o,
        .s_rdata_o, .s_rresp_o, .s_rvalid_o, .s_rready_i,
        .m_awaddr_o(ax_awaddr), .m_awid_o(ax_awid), .m_awlen_o(ax_awlen),
        .m_awburst_o(ax_awburst), .m_awvalid_o(ax_awvalid), .m_awready_i(ax_awready),
        .m_wdata_o(ax_wdata), .m_wstrb_o(ax_wstrb), .m_wlast_o(ax_wlast),
        .m_wvalid_o(ax_wvalid), .m_wready_i(ax_wready),
        .m_bresp_i(ax_bresp), .m_bvalid_i(ax_bvalid), .m_bready_o(ax_bready),
        .m_araddr_o(ax_araddr), .m_arid_o(ax_arid), .m_arlen_o(ax_arlen),
        .m_arburst_o(ax_arburst), .m_arvalid_o(ax_arvalid), .m_arready_i(ax_arready),
        .m_rdata_i(ax_rdata), .m_rresp_i(ax_rresp), .m_rvalid_i(ax_rvalid), .m_rready_o(ax_rready)
    );

    sdram_axi u_sdram (
        .clk_i(clk_i), .rst_i(rst_i),
        .inport_awvalid_i(ax_awvalid), .inport_awaddr_i(ax_awaddr), .inport_awid_i(ax_awid),
        .inport_awlen_i(ax_awlen), .inport_awburst_i(ax_awburst),
        .inport_wvalid_i(ax_wvalid), .inport_wdata_i(ax_wdata), .inport_wstrb_i(ax_wstrb),
        .inport_wlast_i(ax_wlast), .inport_bready_i(ax_bready),
        .inport_arvalid_i(ax_arvalid), .inport_araddr_i(ax_araddr), .inport_arid_i(ax_arid),
        .inport_arlen_i(ax_arlen), .inport_arburst_i(ax_arburst), .inport_rready_i(ax_rready),
        .sdram_data_input_i(sdram_dq_i),
        .inport_awready_o(ax_awready), .inport_wready_o(ax_wready),
        .inport_bvalid_o(ax_bvalid), .inport_bresp_o(ax_bresp), .inport_bid_o(),
        .inport_arready_o(ax_arready), .inport_rvalid_o(ax_rvalid), .inport_rdata_o(ax_rdata),
        .inport_rresp_o(ax_rresp), .inport_rid_o(), .inport_rlast_o(),
        .sdram_clk_o(sdram_clk_o), .sdram_cke_o(sdram_cke_o), .sdram_cs_o(sdram_cs_o),
        .sdram_ras_o(sdram_ras_o), .sdram_cas_o(sdram_cas_o), .sdram_we_o(sdram_we_o),
        .sdram_dqm_o(sdram_dqm_o), .sdram_addr_o(sdram_addr_o), .sdram_ba_o(sdram_ba_o),
        .sdram_data_output_o(sdram_dq_o), .sdram_data_out_en_o(sdram_dq_oe_o)
    );
endmodule

`default_nettype wire
