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
        .s_axil_awaddr(awaddr),.s_axil_awprot(3'b0),.s_axil_awvalid(awvalid),.s_axil_awready(awready),
        .s_axil_wdata(wdata),.s_axil_wstrb(wstrb),.s_axil_wvalid(wvalid),.s_axil_wready(wready),
        .s_axil_bresp(bresp),.s_axil_bvalid(bvalid),.s_axil_bready(bready),
        .s_axil_araddr(araddr),.s_axil_arprot(3'b0),.s_axil_arvalid(arvalid),.s_axil_arready(arready),
        .s_axil_rdata(rdata),.s_axil_rresp(rresp),.s_axil_rvalid(rvalid),.s_axil_rready(rready),
        .m0_axil_awaddr(m0_awaddr),.m0_axil_awprot(m0_awprot),.m0_axil_awvalid(m0_awvalid),.m0_axil_awready(m0_awready),
        .m0_axil_wdata(m0_wdata),.m0_axil_wstrb(m0_wstrb),.m0_axil_wvalid(m0_wvalid),.m0_axil_wready(m0_wready),
        .m0_axil_bresp(m0_bresp),.m0_axil_bvalid(m0_bvalid),.m0_axil_bready(m0_bready),
        .m0_axil_araddr(m0_araddr),.m0_axil_arprot(m0_arprot),.m0_axil_arvalid(m0_arvalid),.m0_axil_arready(m0_arready),
        .m0_axil_rdata(m0_rdata),.m0_axil_rresp(m0_rresp),.m0_axil_rvalid(m0_rvalid),.m0_axil_rready(m0_rready),
        .m1_axil_awaddr(m1_awaddr),.m1_axil_awprot(m1_awprot),.m1_axil_awvalid(m1_awvalid),.m1_axil_awready(m1_awready),
        .m1_axil_wdata(m1_wdata),.m1_axil_wstrb(m1_wstrb),.m1_axil_wvalid(m1_wvalid),.m1_axil_wready(m1_wready),
        .m1_axil_bresp(m1_bresp),.m1_axil_bvalid(m1_bvalid),.m1_axil_bready(m1_bready),
        .m1_axil_araddr(m1_araddr),.m1_axil_arprot(m1_arprot),.m1_axil_arvalid(m1_arvalid),.m1_axil_arready(m1_arready),
        .m1_axil_rdata(m1_rdata),.m1_axil_rresp(m1_rresp),.m1_axil_rvalid(m1_rvalid),.m1_axil_rready(m1_rready)
    );

    axil_ram #(.Words(256)) sram (
        .clk_i(clk),.rst_ni(rst_n),
        .s_axil_awaddr(m0_awaddr),.s_axil_awprot(m0_awprot),.s_axil_awvalid(m0_awvalid),.s_axil_awready(m0_awready),
        .s_axil_wdata(m0_wdata),.s_axil_wstrb(m0_wstrb),.s_axil_wvalid(m0_wvalid),.s_axil_wready(m0_wready),
        .s_axil_bresp(m0_bresp),.s_axil_bvalid(m0_bvalid),.s_axil_bready(m0_bready),
        .s_axil_araddr(m0_araddr),.s_axil_arprot(m0_arprot),.s_axil_arvalid(m0_arvalid),.s_axil_arready(m0_arready),
        .s_axil_rdata(m0_rdata),.s_axil_rresp(m0_rresp),.s_axil_rvalid(m0_rvalid),.s_axil_rready(m0_rready)
    );

    wire [15:0] dq, dq_o, dq_i; wire dq_oe;
    wire s_clk,s_cke,s_cs,s_ras,s_cas,s_we; wire [1:0] s_dqm,s_ba; wire [12:0] s_addr;
    assign dq = dq_oe ? dq_o : 16'hzzzz;
    assign dq_i = dq;

    sdram_wrap sdram (
        .clk_i(clk),.rst_ni(rst_n),
        .s_axil_awaddr(m1_awaddr),.s_axil_awprot(m1_awprot),.s_axil_awvalid(m1_awvalid),.s_axil_awready(m1_awready),
        .s_axil_wdata(m1_wdata),.s_axil_wstrb(m1_wstrb),.s_axil_wvalid(m1_wvalid),.s_axil_wready(m1_wready),
        .s_axil_bresp(m1_bresp),.s_axil_bvalid(m1_bvalid),.s_axil_bready(m1_bready),
        .s_axil_araddr(m1_araddr),.s_axil_arprot(m1_arprot),.s_axil_arvalid(m1_arvalid),.s_axil_arready(m1_arready),
        .s_axil_rdata(m1_rdata),.s_axil_rresp(m1_rresp),.s_axil_rvalid(m1_rvalid),.s_axil_rready(m1_rready),
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
