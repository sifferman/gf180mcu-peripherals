// SPDX-License-Identifier: Apache-2.0
// cocotb HDL harness: ultraembedded sdram_axi (DUT) + behavioral sdram_model,
// with the SDRAM DQ tristate wired up. All AXI4 + clk/rst ports are exposed so
// the cocotb test (sdram_tb.py) drives them directly. This is a harness, not a
// testbench -- there is no stimulus here.
`default_nettype none
`timescale 1ns/1ps

module sdram_harness (
    input  wire        clk,
    input  wire        rst,
    // AXI4 write address / data / response
    input  wire        awvalid, input wire [31:0] awaddr, input wire [3:0] awid,
    input  wire [7:0]  awlen,   input wire [1:0]  awburst,
    output wire        awready,
    input  wire        wvalid,  input wire [31:0] wdata,  input wire [3:0] wstrb, input wire wlast,
    output wire        wready,
    output wire        bvalid,  output wire [1:0] bresp,  output wire [3:0] bid, input wire bready,
    // AXI4 read address / data
    input  wire        arvalid, input wire [31:0] araddr, input wire [3:0] arid,
    input  wire [7:0]  arlen,   input wire [1:0]  arburst,
    output wire        arready,
    output wire        rvalid,  output wire [31:0] rdata,  output wire [1:0] rresp,
    output wire [3:0]  rid,     output wire rlast, input wire rready
);
    // SDRAM bus
    wire        s_clk, s_cke, s_cs, s_ras, s_cas, s_we;
    wire [1:0]  s_dqm, s_ba;
    wire [12:0] s_addr;
    wire [15:0] s_dout; wire s_doen;
    wire [15:0] dq;

    assign dq = s_doen ? s_dout : 16'hzzzz;   // controller drives during write

    sdram_axi dut (
        .clk_i(clk), .rst_i(rst),
        .inport_awvalid_i(awvalid), .inport_awaddr_i(awaddr), .inport_awid_i(awid),
        .inport_awlen_i(awlen), .inport_awburst_i(awburst),
        .inport_wvalid_i(wvalid), .inport_wdata_i(wdata), .inport_wstrb_i(wstrb), .inport_wlast_i(wlast),
        .inport_bready_i(bready),
        .inport_arvalid_i(arvalid), .inport_araddr_i(araddr), .inport_arid_i(arid),
        .inport_arlen_i(arlen), .inport_arburst_i(arburst),
        .inport_rready_i(rready),
        .sdram_data_input_i(dq),
        .inport_awready_o(awready), .inport_wready_o(wready),
        .inport_bvalid_o(bvalid), .inport_bresp_o(bresp), .inport_bid_o(bid),
        .inport_arready_o(arready), .inport_rvalid_o(rvalid), .inport_rdata_o(rdata),
        .inport_rresp_o(rresp), .inport_rid_o(rid), .inport_rlast_o(rlast),
        .sdram_clk_o(s_clk), .sdram_cke_o(s_cke), .sdram_cs_o(s_cs), .sdram_ras_o(s_ras),
        .sdram_cas_o(s_cas), .sdram_we_o(s_we), .sdram_dqm_o(s_dqm), .sdram_addr_o(s_addr),
        .sdram_ba_o(s_ba), .sdram_data_output_o(s_dout), .sdram_data_out_en_o(s_doen)
    );

    sdram_model model (
        .Clk(s_clk), .Cke(s_cke), .Cs_n(s_cs), .Ras_n(s_ras), .Cas_n(s_cas), .We_n(s_we),
        .Ba(s_ba), .Addr(s_addr), .Dqm(s_dqm), .Dq(dq)
    );
endmodule

`default_nettype wire
