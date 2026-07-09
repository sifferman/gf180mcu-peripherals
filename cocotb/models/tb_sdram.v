// SPDX-License-Identifier: Apache-2.0
// Standalone self-checking test: ultraembedded sdram_axi + behavioral sdram_sim.
// Writes two words over AXI4 and reads them back. Pure iverilog (no cocotb):
//   iverilog -g2012 -o /tmp/tbsdram cocotb/models/tb_sdram.v \
//       third_party/ultraembedded_axi_sdram_controller/src_v/*.v cocotb/models/sdram_sim.v && vvp /tmp/tbsdram

`default_nettype none
`timescale 1ns/1ps

module tb_sdram;
    reg clk = 0, rst = 1;
    always #10 clk = ~clk;   // 50 MHz

    // AXI4 master signals
    reg         awvalid=0; reg [31:0] awaddr=0; reg [3:0] awid=0; reg [7:0] awlen=0; reg [1:0] awburst=1;
    wire        awready;
    reg         wvalid=0;  reg [31:0] wdata=0;  reg [3:0] wstrb=0; reg wlast=0;
    wire        wready;
    wire        bvalid; wire [1:0] bresp; wire [3:0] bid; reg bready=0;
    reg         arvalid=0; reg [31:0] araddr=0; reg [3:0] arid=0; reg [7:0] arlen=0; reg [1:0] arburst=1;
    wire        arready;
    wire        rvalid; wire [31:0] rdata; wire [1:0] rresp; wire [3:0] rid; wire rlast; reg rready=0;

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

    sdram_sim model (
        .Clk(s_clk), .Cke(s_cke), .Cs_n(s_cs), .Ras_n(s_ras), .Cas_n(s_cas), .We_n(s_we),
        .Ba(s_ba), .Addr(s_addr), .Dqm(s_dqm), .Dq(dq)
    );

    // This controller accepts AW and W on the same cycle (sdram_axi_pmem).
    task axi_write(input [31:0] a, input [31:0] d);
        begin
            @(posedge clk);
            awaddr<=a; awid<=0; awlen<=0; awburst<=2'b01; awvalid<=1;
            wdata<=d; wstrb<=4'hf; wlast<=1; wvalid<=1; bready<=1;
            @(posedge clk);
            while (!(awready && wready)) @(posedge clk);  // both accepted together
            awvalid<=0; wvalid<=0;
            while (!bvalid) @(posedge clk);               // bready held high -> consumed
            @(posedge clk); bready<=0;
        end
    endtask

    task axi_read(input [31:0] a, output [31:0] d);
        begin
            @(posedge clk);
            araddr<=a; arid<=0; arlen<=0; arburst<=2'b01; arvalid<=1; rready<=1;
            @(posedge clk);
            while (!arready) @(posedge clk);
            arvalid<=0;
            while (!rvalid) @(posedge clk);
            d = rdata;
            @(posedge clk); rready<=0;
        end
    endtask

    reg [31:0] got;
    integer errors = 0;
    initial begin
        repeat (5) @(posedge clk);
        rst <= 0;

        // Let the controller finish its ~100us power-up/init. axi_write holds
        // awvalid until awready, so issuing now is fine, but settle a bit first.
        repeat (7000) @(posedge clk);

        axi_write(32'h0000_0100, 32'hDEAD_BEEF);
        axi_write(32'h0000_0104, 32'hCAFE_F00D);

        axi_read(32'h0000_0100, got);
        if (got !== 32'hDEAD_BEEF) begin $display("FAIL @0x100: got %08x exp DEADBEEF", got); errors=errors+1; end
        else $display("OK   @0x100 = %08x", got);

        axi_read(32'h0000_0104, got);
        if (got !== 32'hCAFE_F00D) begin $display("FAIL @0x104: got %08x exp CAFEF00D", got); errors=errors+1; end
        else $display("OK   @0x104 = %08x", got);

        if (errors == 0) $display("PASS: SDRAM write/read-back");
        else             $display("FAIL: %0d error(s)", errors);
        $finish;
    end

    initial begin
        #2_000_000;  // 2 ms timeout
        $display("FAIL: timeout");
        $finish;
    end
endmodule

`default_nettype wire
