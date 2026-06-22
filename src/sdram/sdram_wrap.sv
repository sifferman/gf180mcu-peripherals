// Copyright (c) 2026 Ethan Sifferman
//
// Redistribution and use in source and binary forms, with or without modification, are permitted
// provided that the following conditions are met:
//
// 1. Redistributions of source code must retain the above copyright notice, this list of
//    conditions and the following disclaimer.
//
// 2. Redistributions in binary form must reproduce the above copyright notice, this list of
//    conditions and the following disclaimer in the documentation and/or other materials provided
//    with the distribution.
//
// 3. Neither the name of the copyright holder nor the names of its contributors may be used to
//    endorse or promote products derived from this software without specific prior written
//    permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR
// IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND
// FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR
// CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
// SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
// OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.

// sdram_wrap
//
// External-SDRAM block: ultraembedded sdram_axi (AXI4) behind an AXI4-Lite front end,
// with the DQ bus split into output / output-enable / input so chip_top can drive one
// bidirectional pad per bit. Geometry is sdram_axi's default (24-bit address, 9-bit
// column), which matches the Winbond W9825G6KH (x16, 13-row/9-col/2-bank).
//
// Functional sim: cocotb/models/tb_sdram.v against the open behavioural model (Icarus)
// or the encrypted Winbond model (VCS).

`default_nettype none

module sdram_wrap (
    input  wire        clk_i,
    input  wire        rst_ni,

    /*
     * AXI-Lite slave interface (from the on-chip interconnect)
     */
    input  wire [31:0] s_axil_awaddr,
    input  wire [2:0]  s_axil_awprot,
    input  wire        s_axil_awvalid,
    output wire        s_axil_awready,
    input  wire [31:0] s_axil_wdata,
    input  wire [3:0]  s_axil_wstrb,
    input  wire        s_axil_wvalid,
    output wire        s_axil_wready,
    output wire [1:0]  s_axil_bresp,
    output wire        s_axil_bvalid,
    input  wire        s_axil_bready,
    input  wire [31:0] s_axil_araddr,
    input  wire [2:0]  s_axil_arprot,
    input  wire        s_axil_arvalid,
    output wire        s_axil_arready,
    output wire [31:0] s_axil_rdata,
    output wire [1:0]  s_axil_rresp,
    output wire        s_axil_rvalid,
    input  wire        s_axil_rready,

    /*
     * SDRAM device pins (DQ split for a bidirectional pad)
     */
    output wire        sdram_clk_o,
    output wire        sdram_cke_o,
    output wire        sdram_cs_o,
    output wire        sdram_ras_o,
    output wire        sdram_cas_o,
    output wire        sdram_we_o,
    output wire [1:0]  sdram_dqm_o,
    output wire [12:0] sdram_addr_o,
    output wire [1:0]  sdram_ba_o,
    output wire [15:0] sdram_dq_o,
    output wire        sdram_dq_oe_o,
    input  wire [15:0] sdram_dq_i
);

wire [31:0] axi_awaddr;
wire [3:0]  axi_awid;
wire [7:0]  axi_awlen;
wire [1:0]  axi_awburst;
wire        axi_awvalid, axi_awready;
wire [31:0] axi_wdata;
wire [3:0]  axi_wstrb;
wire        axi_wlast, axi_wvalid, axi_wready;
wire [1:0]  axi_bresp;
wire        axi_bvalid, axi_bready;
wire [31:0] axi_araddr;
wire [3:0]  axi_arid;
wire [7:0]  axi_arlen;
wire [1:0]  axi_arburst;
wire        axi_arvalid, axi_arready;
wire [31:0] axi_rdata;
wire [1:0]  axi_rresp;
wire        axi_rvalid, axi_rready;

axil_to_axi4 adapter (
    .s_axil_awaddr, .s_axil_awprot, .s_axil_awvalid, .s_axil_awready,
    .s_axil_wdata, .s_axil_wstrb, .s_axil_wvalid, .s_axil_wready,
    .s_axil_bresp, .s_axil_bvalid, .s_axil_bready,
    .s_axil_araddr, .s_axil_arprot, .s_axil_arvalid, .s_axil_arready,
    .s_axil_rdata, .s_axil_rresp, .s_axil_rvalid, .s_axil_rready,
    .m_axi_awaddr(axi_awaddr), .m_axi_awid(axi_awid), .m_axi_awlen(axi_awlen),
    .m_axi_awburst(axi_awburst), .m_axi_awvalid(axi_awvalid), .m_axi_awready(axi_awready),
    .m_axi_wdata(axi_wdata), .m_axi_wstrb(axi_wstrb), .m_axi_wlast(axi_wlast),
    .m_axi_wvalid(axi_wvalid), .m_axi_wready(axi_wready),
    .m_axi_bresp(axi_bresp), .m_axi_bvalid(axi_bvalid), .m_axi_bready(axi_bready),
    .m_axi_araddr(axi_araddr), .m_axi_arid(axi_arid), .m_axi_arlen(axi_arlen),
    .m_axi_arburst(axi_arburst), .m_axi_arvalid(axi_arvalid), .m_axi_arready(axi_arready),
    .m_axi_rdata(axi_rdata), .m_axi_rresp(axi_rresp), .m_axi_rvalid(axi_rvalid), .m_axi_rready(axi_rready)
);

// sdram_axi (imported, ultraembedded) takes an active-high reset and canonical port names.
sdram_axi u_sdram (
    .clk_i(clk_i), .rst_i(!rst_ni),
    .inport_awvalid_i(axi_awvalid), .inport_awaddr_i(axi_awaddr), .inport_awid_i(axi_awid),
    .inport_awlen_i(axi_awlen), .inport_awburst_i(axi_awburst),
    .inport_wvalid_i(axi_wvalid), .inport_wdata_i(axi_wdata), .inport_wstrb_i(axi_wstrb),
    .inport_wlast_i(axi_wlast), .inport_bready_i(axi_bready),
    .inport_arvalid_i(axi_arvalid), .inport_araddr_i(axi_araddr), .inport_arid_i(axi_arid),
    .inport_arlen_i(axi_arlen), .inport_arburst_i(axi_arburst), .inport_rready_i(axi_rready),
    .sdram_data_input_i(sdram_dq_i),
    .inport_awready_o(axi_awready), .inport_wready_o(axi_wready),
    .inport_bvalid_o(axi_bvalid), .inport_bresp_o(axi_bresp), .inport_bid_o(),
    .inport_arready_o(axi_arready), .inport_rvalid_o(axi_rvalid), .inport_rdata_o(axi_rdata),
    .inport_rresp_o(axi_rresp), .inport_rid_o(), .inport_rlast_o(),
    .sdram_clk_o(sdram_clk_o), .sdram_cke_o(sdram_cke_o), .sdram_cs_o(sdram_cs_o),
    .sdram_ras_o(sdram_ras_o), .sdram_cas_o(sdram_cas_o), .sdram_we_o(sdram_we_o),
    .sdram_dqm_o(sdram_dqm_o), .sdram_addr_o(sdram_addr_o), .sdram_ba_o(sdram_ba_o),
    .sdram_data_output_o(sdram_dq_o), .sdram_data_out_en_o(sdram_dq_oe_o)
);

endmodule

`default_nettype wire
