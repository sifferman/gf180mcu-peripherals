// SPDX-License-Identifier: Apache-2.0
//
// AXI4-Lite master -> AXI4 slave adapter (single-beat).
//
// The Ethernet datapath drives an AXI4-Lite master (m_axil_readwrite); the
// ultraembedded SDRAM controller (sdram_axi) is an AXI4 slave with id/len/burst/
// last/size fields. Each AXI4-Lite access is one 32-bit beat, so present it as an
// AXI4 single-beat burst (len=0, size=2, INCR) with id=0 and wlast=1, and drop the
// id/last fields on the response side.

`default_nettype none

module axil_to_axi4 #(
    parameter int unsigned AddrWidth = 32
) (
    // ---- AXI4-Lite slave (from the Ethernet bridge) ----
    input  wire [AddrWidth-1:0] s_awaddr_i,
    input  wire [2:0]           s_awprot_i,
    input  wire                 s_awvalid_i,
    output wire                 s_awready_o,
    input  wire [31:0]          s_wdata_i,
    input  wire [3:0]           s_wstrb_i,
    input  wire                 s_wvalid_i,
    output wire                 s_wready_o,
    output wire [1:0]           s_bresp_o,
    output wire                 s_bvalid_o,
    input  wire                 s_bready_i,
    input  wire [AddrWidth-1:0] s_araddr_i,
    input  wire [2:0]           s_arprot_i,
    input  wire                 s_arvalid_i,
    output wire                 s_arready_o,
    output wire [31:0]          s_rdata_o,
    output wire [1:0]           s_rresp_o,
    output wire                 s_rvalid_o,
    input  wire                 s_rready_i,

    // ---- AXI4 master (to sdram_axi) ----
    output wire [AddrWidth-1:0] m_awaddr_o,
    output wire [3:0]           m_awid_o,
    output wire [7:0]           m_awlen_o,
    output wire [1:0]           m_awburst_o,
    output wire                 m_awvalid_o,
    input  wire                 m_awready_i,
    output wire [31:0]          m_wdata_o,
    output wire [3:0]           m_wstrb_o,
    output wire                 m_wlast_o,
    output wire                 m_wvalid_o,
    input  wire                 m_wready_i,
    input  wire [1:0]           m_bresp_i,
    input  wire                 m_bvalid_i,
    output wire                 m_bready_o,
    output wire [AddrWidth-1:0] m_araddr_o,
    output wire [3:0]           m_arid_o,
    output wire [7:0]           m_arlen_o,
    output wire [1:0]           m_arburst_o,
    output wire                 m_arvalid_o,
    input  wire                 m_arready_i,
    input  wire [31:0]          m_rdata_i,
    input  wire [1:0]           m_rresp_i,
    input  wire                 m_rvalid_i,
    output wire                 m_rready_o
);
    // Write address
    assign m_awaddr_o  = s_awaddr_i;
    assign m_awid_o    = 4'd0;
    assign m_awlen_o   = 8'd0;       // single beat
    assign m_awburst_o = 2'b01;      // INCR
    assign m_awvalid_o = s_awvalid_i;
    assign s_awready_o = m_awready_i;

    // Write data
    assign m_wdata_o   = s_wdata_i;
    assign m_wstrb_o   = s_wstrb_i;
    assign m_wlast_o   = 1'b1;       // single beat
    assign m_wvalid_o  = s_wvalid_i;
    assign s_wready_o  = m_wready_i;

    // Write response (drop bid)
    assign s_bresp_o   = m_bresp_i;
    assign s_bvalid_o  = m_bvalid_i;
    assign m_bready_o  = s_bready_i;

    // Read address
    assign m_araddr_o  = s_araddr_i;
    assign m_arid_o    = 4'd0;
    assign m_arlen_o   = 8'd0;
    assign m_arburst_o = 2'b01;
    assign m_arvalid_o = s_arvalid_i;
    assign s_arready_o = m_arready_i;

    // Read data (drop rid/rlast)
    assign s_rdata_o   = m_rdata_i;
    assign s_rresp_o   = m_rresp_i;
    assign s_rvalid_o  = m_rvalid_i;
    assign m_rready_o  = s_rready_i;

    logic _unused;
    assign _unused = &{1'b0, s_awprot_i, s_arprot_i};
endmodule

`default_nettype wire
