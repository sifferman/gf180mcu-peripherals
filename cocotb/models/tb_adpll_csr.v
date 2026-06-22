// SPDX-License-Identifier: Apache-2.0
//
// Unit test for the integrated ADPLL subsystem: adpll_csr (AXI4-Lite) -> adpll_controller_bangbang
// (bang-bang PI) -> ring_dco_binary (behavioural). Drives the CSR exactly as the on-chip
// fabric does -- writes MUL/DIV then sets CTRL.enable -- and polls the STATUS register
// until the lock bit reads back, mirroring how a host would over Ethernet. Runs under
// Icarus (SYNTHESIS undefined, behavioural DCO). PASSes on lock with an in-range tune.


module tb_adpll_csr;
  localparam int unsigned NUM_TUNE = 7;
  localparam int unsigned CNT_W    = 24;
  localparam int unsigned DIV_W    = 16;
  localparam int unsigned MUL      = 1707;
  localparam int unsigned DIV      = 256;

  // register byte offsets
  localparam [31:0] CTRL = 32'h0, MUL_A = 32'h4, DIV_A = 32'h8, STAT = 32'hC;

  reg clk = 1'b0;
  always #(20ns) clk = ~clk;          // 25 MHz
  reg rst_n = 1'b1;

  reg  [31:0] awaddr, wdata, araddr;
  reg         awvalid, wvalid, bready, arvalid, rready;
  wire        awready, wready, bvalid, arready, rvalid;
  wire [31:0] rdata;
  wire [1:0]  bresp, rresp;

  wire                enable;
  wire [CNT_W-1:0]    mul;
  wire [DIV_W-1:0]    div;
  wire                lock;
  wire [NUM_TUNE-1:0] tune;
  wire                dco_clk;

  adpll_csr #(.NumTuneBits(NUM_TUNE)) u_csr (
      .clk_i(clk), .rst_ni(rst_n),
      .s_axil_awaddr(awaddr), .s_axil_awprot(3'b0), .s_axil_awvalid(awvalid), .s_axil_awready(awready),
      .s_axil_wdata(wdata), .s_axil_wstrb(4'hF), .s_axil_wvalid(wvalid), .s_axil_wready(wready),
      .s_axil_bresp(bresp), .s_axil_bvalid(bvalid), .s_axil_bready(bready),
      .s_axil_araddr(araddr), .s_axil_arprot(3'b0), .s_axil_arvalid(arvalid), .s_axil_arready(arready),
      .s_axil_rdata(rdata), .s_axil_rresp(rresp), .s_axil_rvalid(rvalid), .s_axil_rready(rready),
      .enable_o(enable), .mul_o(mul), .div_o(div), .lock_i(lock), .tune_i(tune)
  );

  adpll_controller_bangbang #(.NumTuneBits(NUM_TUNE)) u_ctrl (
      .clk_i(clk), .rst_ni(rst_n), .enable_i(enable),
      .mul_i(mul), .div_i(div), .dco_clk_i(dco_clk),
      .tune_o(tune), .lock_o(lock)
  );

  ring_dco_binary #(.NumTuneBits(NUM_TUNE)) u_dco (.enable_i(enable), .tune_i(tune), .clk_o(dco_clk));

  task axil_write(input [31:0] addr, input [31:0] data);
    begin
      @(posedge clk);
      awaddr <= addr; wdata <= data; awvalid <= 1'b1; wvalid <= 1'b1; bready <= 1'b1;
      @(posedge clk);
      while (!(awready && wready)) @(posedge clk);
      awvalid <= 1'b0; wvalid <= 1'b0;
      while (!bvalid) @(posedge clk);
      @(posedge clk); bready <= 1'b0;
    end
  endtask

  task axil_read(input [31:0] addr, output [31:0] data);
    begin
      @(posedge clk);
      araddr <= addr; arvalid <= 1'b1; rready <= 1'b1;
      @(posedge clk);
      while (!arready) @(posedge clk);
      arvalid <= 1'b0;
      while (!rvalid) @(posedge clk);
      data = rdata;
      @(posedge clk); rready <= 1'b0;
    end
  endtask

  reg [31:0] rd;
  integer i;
  initial begin
    awvalid=0; wvalid=0; bready=0; arvalid=0; rready=0; awaddr=0; wdata=0; araddr=0;
    rst_n = 1'b1; #(2ns) rst_n = 1'b0; repeat (5) @(posedge clk); rst_n = 1'b1; repeat (5) @(posedge clk);

    // program the synthesizer ratio, then enable -- exactly as a host would over Ethernet
    axil_write(MUL_A, MUL);
    axil_write(DIV_A, DIV);
    axil_read (MUL_A, rd); if (rd !== MUL) begin $display("FAIL: MUL readback %0d != %0d", rd, MUL); $finish; end
    axil_read (DIV_A, rd); if (rd !== DIV) begin $display("FAIL: DIV readback %0d != %0d", rd, DIV); $finish; end
    axil_write(CTRL, 32'h1);
    axil_read (CTRL, rd); if (rd[0] !== 1'b1) begin $display("FAIL: enable not set"); $finish; end
    $display("CSR programmed: mul=%0d div=%0d enable=1", MUL, DIV);

    // poll STATUS for lock
    for (i = 0; i < 20000; i = i + 1) begin
      axil_read(STAT, rd);
      if (rd[0]) begin
        $display("LOCKED via CSR: STATUS=0x%08x  lock=%0d tune=%0d", rd, rd[0], rd[NUM_TUNE:1]);
        if (rd[NUM_TUNE:1] > 1 && rd[NUM_TUNE:1] < (1<<NUM_TUNE)-2)
             $display("PASS: adpll_csr locked, tune=%0d in-range", rd[NUM_TUNE:1]);
        else $display("FAIL: locked at a rail (tune=%0d)", rd[NUM_TUNE:1]);
        $finish;
      end
    end
    $display("FAIL: timeout, no lock via CSR (last STATUS=0x%08x)", rd);
    $finish;
  end
endmodule

