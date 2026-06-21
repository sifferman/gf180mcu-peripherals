// SPDX-License-Identifier: Apache-2.0
// Standalone test of the M2 on-chip fabric: AXI4-Lite master -> axil_interconnect
// -> { axil_ram (slave0, low region), sdram_wrap->sdram_axi->sdram_sim (slave1, high) }.
// Verifies address decode + the AXI4-Lite<->AXI4 adapter + SDRAM path.
//   iverilog -g2012 -o /tmp/tbm2 cocotb/models/tb_m2_fabric.v \
//     src/axi/axil_ram.sv src/axi/axil_to_axi4.sv src/axi/axil_interconnect.sv \
//     src/sdram/sdram_wrap.sv third_party/ultraembedded_axi_sdram_controller/src_v/*.v \
//     cocotb/models/sdram_sim.v && vvp /tmp/tbm2

`default_nettype none
`timescale 1ns/1ps

module tb_m2_fabric;
    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;            // 50 MHz
    wire rst = ~rst_n;

    // upstream AXI4-Lite master signals
    reg [31:0] awaddr=0; reg awvalid=0; wire awready;
    reg [31:0] wdata=0;  reg [3:0] wstrb=0; reg wvalid=0; wire wready;
    wire [1:0] bresp; wire bvalid; reg bready=0;
    reg [31:0] araddr=0; reg arvalid=0; wire arready;
    wire [31:0] rdata; wire [1:0] rresp; wire rvalid; reg rready=0;

    // interconnect <-> slaves
    wire [31:0] m0_awaddr,m0_wdata,m0_araddr,m0_rdata; wire [2:0] m0_awprot,m0_arprot;
    wire [3:0] m0_wstrb; wire [1:0] m0_bresp,m0_rresp;
    wire m0_awvalid,m0_awready,m0_wvalid,m0_wready,m0_bvalid,m0_bready,m0_arvalid,m0_arready,m0_rvalid,m0_rready;
    wire [31:0] m1_awaddr,m1_wdata,m1_araddr,m1_rdata; wire [2:0] m1_awprot,m1_arprot;
    wire [3:0] m1_wstrb; wire [1:0] m1_bresp,m1_rresp;
    wire m1_awvalid,m1_awready,m1_wvalid,m1_wready,m1_bvalid,m1_bready,m1_arvalid,m1_arready,m1_rvalid,m1_rready;

    axil_interconnect #(.SelBit(28)) ic (
        .u_awaddr_i(awaddr),.u_awprot_i(3'b0),.u_awvalid_i(awvalid),.u_awready_o(awready),
        .u_wdata_i(wdata),.u_wstrb_i(wstrb),.u_wvalid_i(wvalid),.u_wready_o(wready),
        .u_bresp_o(bresp),.u_bvalid_o(bvalid),.u_bready_i(bready),
        .u_araddr_i(araddr),.u_arprot_i(3'b0),.u_arvalid_i(arvalid),.u_arready_o(arready),
        .u_rdata_o(rdata),.u_rresp_o(rresp),.u_rvalid_o(rvalid),.u_rready_i(rready),
        .m0_awaddr_o(m0_awaddr),.m0_awprot_o(m0_awprot),.m0_awvalid_o(m0_awvalid),.m0_awready_i(m0_awready),
        .m0_wdata_o(m0_wdata),.m0_wstrb_o(m0_wstrb),.m0_wvalid_o(m0_wvalid),.m0_wready_i(m0_wready),
        .m0_bresp_i(m0_bresp),.m0_bvalid_i(m0_bvalid),.m0_bready_o(m0_bready),
        .m0_araddr_o(m0_araddr),.m0_arprot_o(m0_arprot),.m0_arvalid_o(m0_arvalid),.m0_arready_i(m0_arready),
        .m0_rdata_i(m0_rdata),.m0_rresp_i(m0_rresp),.m0_rvalid_i(m0_rvalid),.m0_rready_o(m0_rready),
        .m1_awaddr_o(m1_awaddr),.m1_awprot_o(m1_awprot),.m1_awvalid_o(m1_awvalid),.m1_awready_i(m1_awready),
        .m1_wdata_o(m1_wdata),.m1_wstrb_o(m1_wstrb),.m1_wvalid_o(m1_wvalid),.m1_wready_i(m1_wready),
        .m1_bresp_i(m1_bresp),.m1_bvalid_i(m1_bvalid),.m1_bready_o(m1_bready),
        .m1_araddr_o(m1_araddr),.m1_arprot_o(m1_arprot),.m1_arvalid_o(m1_arvalid),.m1_arready_i(m1_arready),
        .m1_rdata_i(m1_rdata),.m1_rresp_i(m1_rresp),.m1_rvalid_i(m1_rvalid),.m1_rready_o(m1_rready)
    );

    axil_ram #(.Words(256)) sram (
        .clk_i(clk),.rst_ni(rst_n),
        .s_awaddr_i(m0_awaddr),.s_awprot_i(m0_awprot),.s_awvalid_i(m0_awvalid),.s_awready_o(m0_awready),
        .s_wdata_i(m0_wdata),.s_wstrb_i(m0_wstrb),.s_wvalid_i(m0_wvalid),.s_wready_o(m0_wready),
        .s_bresp_o(m0_bresp),.s_bvalid_o(m0_bvalid),.s_bready_i(m0_bready),
        .s_araddr_i(m0_araddr),.s_arprot_i(m0_arprot),.s_arvalid_i(m0_arvalid),.s_arready_o(m0_arready),
        .s_rdata_o(m0_rdata),.s_rresp_o(m0_rresp),.s_rvalid_o(m0_rvalid),.s_rready_i(m0_rready)
    );

    wire [15:0] dq, dq_o, dq_i; wire dq_oe;
    wire s_clk,s_cke,s_cs,s_ras,s_cas,s_we; wire [1:0] s_dqm,s_ba; wire [12:0] s_addr;
    assign dq = dq_oe ? dq_o : 16'hzzzz;
    assign dq_i = dq;

    sdram_wrap sdram (
        .clk_i(clk),.rst_i(rst),
        .s_awaddr_i(m1_awaddr),.s_awprot_i(m1_awprot),.s_awvalid_i(m1_awvalid),.s_awready_o(m1_awready),
        .s_wdata_i(m1_wdata),.s_wstrb_i(m1_wstrb),.s_wvalid_i(m1_wvalid),.s_wready_o(m1_wready),
        .s_bresp_o(m1_bresp),.s_bvalid_o(m1_bvalid),.s_bready_i(m1_bready),
        .s_araddr_i(m1_araddr),.s_arprot_i(m1_arprot),.s_arvalid_i(m1_arvalid),.s_arready_o(m1_arready),
        .s_rdata_o(m1_rdata),.s_rresp_o(m1_rresp),.s_rvalid_o(m1_rvalid),.s_rready_i(m1_rready),
        .sdram_clk_o(s_clk),.sdram_cke_o(s_cke),.sdram_cs_o(s_cs),.sdram_ras_o(s_ras),
        .sdram_cas_o(s_cas),.sdram_we_o(s_we),.sdram_dqm_o(s_dqm),.sdram_addr_o(s_addr),
        .sdram_ba_o(s_ba),.sdram_dq_o(dq_o),.sdram_dq_oe_o(dq_oe),.sdram_dq_i(dq_i)
    );
    sdram_sim model (.Clk(s_clk),.Cke(s_cke),.Cs_n(s_cs),.Ras_n(s_ras),.Cas_n(s_cas),
                     .We_n(s_we),.Ba(s_ba),.Addr(s_addr),.Dqm(s_dqm),.Dq(dq));

    task wr(input [31:0] a, input [31:0] d); begin
        @(posedge clk); awaddr<=a; awvalid<=1; wdata<=d; wstrb<=4'hf; wvalid<=1; bready<=1;
        @(posedge clk); while(!(awready&&wready)) @(posedge clk); awvalid<=0; wvalid<=0;
        while(!bvalid) @(posedge clk); @(posedge clk); bready<=0;
    end endtask
    task rd(input [31:0] a, output [31:0] d); begin
        @(posedge clk); araddr<=a; arvalid<=1; rready<=1;
        @(posedge clk); while(!arready) @(posedge clk); arvalid<=0;
        while(!rvalid) @(posedge clk); d=rdata; @(posedge clk); rready<=0;
    end endtask

    reg [31:0] got; integer errs=0;
    initial begin
        repeat(5) @(posedge clk); rst_n<=1;
        repeat(7000) @(posedge clk);            // SDRAM init
        // slave0 (scratch RAM, sel bit 28 = 0)
        wr(32'h0000_0040, 32'h1234_5678);
        rd(32'h0000_0040, got);
        if (got!==32'h1234_5678) begin $display("FAIL SRAM @0x40: %08x",got); errs=errs+1; end
        else $display("OK SRAM  @0x40 = %08x", got);
        // slave1 (SDRAM, addr bit 28 = 1)
        wr(32'h1000_0040, 32'hCAFE_BABE);
        wr(32'h1000_0044, 32'hDEAD_BEEF);
        rd(32'h1000_0040, got);
        if (got!==32'hCAFE_BABE) begin $display("FAIL SDRAM @0x40: %08x",got); errs=errs+1; end
        else $display("OK SDRAM @0x40 = %08x", got);
        rd(32'h1000_0044, got);
        if (got!==32'hDEAD_BEEF) begin $display("FAIL SDRAM @0x44: %08x",got); errs=errs+1; end
        else $display("OK SDRAM @0x44 = %08x", got);
        if (errs==0) $display("PASS: M2 fabric (interconnect + SRAM + SDRAM)");
        else         $display("FAIL: %0d errors", errs);
        $finish;
    end
    initial begin #3_000_000; $display("FAIL: timeout"); $finish; end
endmodule

`default_nettype wire
