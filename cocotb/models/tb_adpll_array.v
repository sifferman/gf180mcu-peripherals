// SPDX-License-Identifier: Apache-2.0
//
// CSR test framework for the 12-PLL ADPLL array (adpll_array). Drives the AXI4-Lite slave exactly
// as the on-chip fabric does -- for each of the 12 controller x DCO macros it writes MUL/DIV and
// sets CTRL.enable, then polls that PLL's STATUS register until lock and checks the settled tune
// is in range. Finally it exercises the observation mux: select each PLL and confirm obs_lock_o
// matches that PLL's STATUS lock bit. Runs under Icarus (SYNTHESIS undefined, behavioural DCOs).
// PASSes only if all 12 PLLs lock in range and the mux tracks the selection.

module tb_adpll_array;
  localparam int unsigned NUM_PLL  = 12;
  localparam int unsigned NUM_TUNE = 7;
  localparam int unsigned MUL      = 1707;   // target edges/window (N)
  localparam int unsigned DIV      = 256;    // window length (M)
  localparam [31:0] OBS_SEL = NUM_PLL * 32'h10;   // observation-select register

  // CSR byte offsets for PLL i
  function [31:0] ctrl_a(input integer i); ctrl_a = i*32'h10 + 32'h0; endfunction
  function [31:0] mul_a (input integer i); mul_a  = i*32'h10 + 32'h4; endfunction
  function [31:0] div_a (input integer i); div_a  = i*32'h10 + 32'h8; endfunction
  function [31:0] stat_a(input integer i); stat_a = i*32'h10 + 32'hC; endfunction

  reg clk = 1'b0;
  always #(20ns) clk = ~clk;          // 25 MHz
  reg rst_n = 1'b1;

  reg  [31:0] awaddr, wdata, araddr;
  reg         awvalid, wvalid, bready, arvalid, rready;
  wire        awready, wready, bvalid, arready, rvalid;
  wire [31:0] rdata;
  wire [1:0]  bresp, rresp;
  wire        obs_dco_clk, obs_lock;

  adpll_array #(.NumTuneBits(NUM_TUNE)) u_array (
      .clk_i(clk), .rst_ni(rst_n),
      .s_axil_awaddr(awaddr), .s_axil_awprot(3'b0), .s_axil_awvalid(awvalid), .s_axil_awready(awready),
      .s_axil_wdata(wdata), .s_axil_wstrb(4'hF), .s_axil_wvalid(wvalid), .s_axil_wready(wready),
      .s_axil_bresp(bresp), .s_axil_bvalid(bvalid), .s_axil_bready(bready),
      .s_axil_araddr(araddr), .s_axil_arprot(3'b0), .s_axil_arvalid(arvalid), .s_axil_arready(arready),
      .s_axil_rdata(rdata), .s_axil_rresp(rresp), .s_axil_rvalid(rvalid), .s_axil_rready(rready),
      .obs_dco_clk_o(obs_dco_clk), .obs_lock_o(obs_lock)
  );

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
  integer i, n, locked_count;
  reg [NUM_PLL-1:0] locked;
  reg [NUM_TUNE-1:0] tune_i;

  initial begin
    awvalid=0; wvalid=0; bready=0; arvalid=0; rready=0; awaddr=0; wdata=0; araddr=0;
    locked = '0;
    rst_n = 1'b1; #(2ns) rst_n = 1'b0; repeat (5) @(posedge clk); rst_n = 1'b1; repeat (5) @(posedge clk);

    // Program + enable every PLL (each independently, as a host would over Ethernet).
    for (i = 0; i < NUM_PLL; i = i + 1) begin
      axil_write(mul_a(i), MUL);
      axil_write(div_a(i), DIV);
      axil_read (mul_a(i), rd); if (rd !== MUL) begin $display("FAIL: PLL%0d MUL readback %0d", i, rd); $finish; end
      axil_read (div_a(i), rd); if (rd !== DIV) begin $display("FAIL: PLL%0d DIV readback %0d", i, rd); $finish; end
      axil_write(ctrl_a(i), 32'h1);
    end
    $display("programmed all %0d PLLs: mul=%0d div=%0d enable=1", NUM_PLL, MUL, DIV);

    // Poll every PLL's STATUS until all lock (they run concurrently).
    for (n = 0; n < 40000 && locked != {NUM_PLL{1'b1}}; n = n + 1) begin
      for (i = 0; i < NUM_PLL; i = i + 1) begin
        if (!locked[i]) begin
          axil_read(stat_a(i), rd);
          if (rd[0]) begin
            locked[i] = 1'b1;
            tune_i = rd[NUM_TUNE:1];
            if (tune_i > 1 && tune_i < (1<<NUM_TUNE)-2)
                 $display("  PLL%0d LOCKED, tune=%0d", i, tune_i);
            else begin $display("FAIL: PLL%0d locked at a rail (tune=%0d)", i, tune_i); $finish; end
          end
        end
      end
    end

    locked_count = 0;
    for (i = 0; i < NUM_PLL; i = i + 1) if (locked[i]) locked_count = locked_count + 1;
    if (locked_count != NUM_PLL) begin
      $display("FAIL: only %0d/%0d PLLs locked", locked_count, NUM_PLL);
      $finish;
    end

    // Observation mux: select each PLL, confirm obs_lock_o matches its STATUS lock bit.
    for (i = 0; i < NUM_PLL; i = i + 1) begin
      axil_write(OBS_SEL, i);
      repeat (4) @(posedge clk);
      axil_read(stat_a(i), rd);
      if (obs_lock !== rd[0]) begin
        $display("FAIL: obs mux PLL%0d obs_lock=%0d != STATUS lock=%0d", i, obs_lock, rd[0]);
        $finish;
      end
    end
    $display("obs mux tracks selection across all %0d PLLs", NUM_PLL);

    $display("PASS: adpll_array all %0d PLLs locked in range + obs mux OK", NUM_PLL);
    $finish;
  end

  initial begin
    #(8000000ns);   // hard ceiling
    $display("FAIL: global timeout (locked=0x%0h)", locked);
    $finish;
  end
endmodule
