// SPDX-License-Identifier: Apache-2.0
//
// Minimal 1-master -> 2-slave AXI4-Lite interconnect (address-decoded).
//
// The upstream master (the Ethernet UDP bridge) is single-outstanding, so routing
// is purely combinational: a select bit picks the slave for AW/W/AR, and only the
// selected slave ever produces a B/R response — so responses are just OR/mux'd
// (no transaction tracking needed). Slave 0 = low region (on-chip scratch RAM),
// slave 1 = high region (SDRAM), chosen by address bit SEL_BIT.

`default_nettype none

module axil_interconnect #(
    parameter int unsigned AddrWidth = 32,
    parameter int unsigned SelBit    = 28   // addr[SelBit]==1 -> slave 1 (SDRAM)
) (
    // ---- upstream slave (from Ethernet master) ----
    input  wire [AddrWidth-1:0] u_awaddr_i,
    input  wire [2:0]           u_awprot_i,
    input  wire                 u_awvalid_i,
    output wire                 u_awready_o,
    input  wire [31:0]          u_wdata_i,
    input  wire [3:0]           u_wstrb_i,
    input  wire                 u_wvalid_i,
    output wire                 u_wready_o,
    output wire [1:0]           u_bresp_o,
    output wire                 u_bvalid_o,
    input  wire                 u_bready_i,
    input  wire [AddrWidth-1:0] u_araddr_i,
    input  wire [2:0]           u_arprot_i,
    input  wire                 u_arvalid_i,
    output wire                 u_arready_o,
    output wire [31:0]          u_rdata_o,
    output wire [1:0]           u_rresp_o,
    output wire                 u_rvalid_o,
    input  wire                 u_rready_i,

    // ---- downstream slave 0 (scratch RAM) ----
    output wire [AddrWidth-1:0] m0_awaddr_o, output wire [2:0] m0_awprot_o,
    output wire m0_awvalid_o, input wire m0_awready_i,
    output wire [31:0] m0_wdata_o, output wire [3:0] m0_wstrb_o,
    output wire m0_wvalid_o, input wire m0_wready_i,
    input  wire [1:0] m0_bresp_i, input wire m0_bvalid_i, output wire m0_bready_o,
    output wire [AddrWidth-1:0] m0_araddr_o, output wire [2:0] m0_arprot_o,
    output wire m0_arvalid_o, input wire m0_arready_i,
    input  wire [31:0] m0_rdata_i, input wire [1:0] m0_rresp_i,
    input  wire m0_rvalid_i, output wire m0_rready_o,

    // ---- downstream slave 1 (SDRAM) ----
    output wire [AddrWidth-1:0] m1_awaddr_o, output wire [2:0] m1_awprot_o,
    output wire m1_awvalid_o, input wire m1_awready_i,
    output wire [31:0] m1_wdata_o, output wire [3:0] m1_wstrb_o,
    output wire m1_wvalid_o, input wire m1_wready_i,
    input  wire [1:0] m1_bresp_i, input wire m1_bvalid_i, output wire m1_bready_o,
    output wire [AddrWidth-1:0] m1_araddr_o, output wire [2:0] m1_arprot_o,
    output wire m1_arvalid_o, input wire m1_arready_i,
    input  wire [31:0] m1_rdata_i, input wire [1:0] m1_rresp_i,
    input  wire m1_rvalid_i, output wire m1_rready_o
);
    wire wsel = u_awaddr_i[SelBit];   // 0 -> slave0, 1 -> slave1
    wire rsel = u_araddr_i[SelBit];

    // ---- write address/data: broadcast addr/data, gate valid by select ----
    assign m0_awaddr_o = u_awaddr_i; assign m0_awprot_o = u_awprot_i;
    assign m1_awaddr_o = u_awaddr_i; assign m1_awprot_o = u_awprot_i;
    assign m0_awvalid_o = u_awvalid_i & ~wsel;
    assign m1_awvalid_o = u_awvalid_i &  wsel;

    assign m0_wdata_o = u_wdata_i; assign m0_wstrb_o = u_wstrb_i;
    assign m1_wdata_o = u_wdata_i; assign m1_wstrb_o = u_wstrb_i;
    assign m0_wvalid_o = u_wvalid_i & ~wsel;
    assign m1_wvalid_o = u_wvalid_i &  wsel;

    assign u_awready_o = wsel ? m1_awready_i : m0_awready_i;
    assign u_wready_o  = wsel ? m1_wready_i  : m0_wready_i;

    // ---- write response: only the selected slave is active ----
    assign u_bvalid_o = m0_bvalid_i | m1_bvalid_i;
    assign u_bresp_o  = m1_bvalid_i ? m1_bresp_i : m0_bresp_i;
    assign m0_bready_o = u_bready_i;
    assign m1_bready_o = u_bready_i;

    // ---- read address ----
    assign m0_araddr_o = u_araddr_i; assign m0_arprot_o = u_arprot_i;
    assign m1_araddr_o = u_araddr_i; assign m1_arprot_o = u_arprot_i;
    assign m0_arvalid_o = u_arvalid_i & ~rsel;
    assign m1_arvalid_o = u_arvalid_i &  rsel;
    assign u_arready_o = rsel ? m1_arready_i : m0_arready_i;

    // ---- read data ----
    assign u_rvalid_o = m0_rvalid_i | m1_rvalid_i;
    assign u_rdata_o  = m1_rvalid_i ? m1_rdata_i : m0_rdata_i;
    assign u_rresp_o  = m1_rvalid_i ? m1_rresp_i : m0_rresp_i;
    assign m0_rready_o = u_rready_i;
    assign m1_rready_o = u_rready_i;
endmodule

`default_nettype wire
