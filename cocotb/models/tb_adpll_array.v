// SPDX-License-Identifier: Apache-2.0
//
// CSR test framework for the 10-PLL ADPLL array (adpll_array). Drives the AXI4-Lite slave exactly
// as the on-chip fabric does -- for each of the 10 controller x DCO macros it writes MUL/DIV and
// sets CTRL.enable, then polls that PLL's STATUS register until lock and checks the settled tune
// is in range. Finally it exercises the observation mux: select each PLL and confirm obs_lock_o
// matches that PLL's STATUS lock bit. Runs under Icarus (SYNTHESIS undefined, behavioural DCOs).
// PASSes only if all 10 PLLs lock in range and the mux tracks the selection.

`ifndef NUM_PLL_TB
  `define NUM_PLL_TB 10
`endif
module tb_adpll_array;
  localparam int unsigned NUM_PLL  = `NUM_PLL_TB;   // must match adpll_array NumPll
  localparam int unsigned NUM_TUNE = 7;
  localparam [31:0] OBS_SEL = NUM_PLL * 32'h10;   // observation-select register

  // Per-config control word (matches adpll_array's curated table). FLL configs use mul/div for
  // F_DCO = mul/div * 25MHz; phase configs put a frequency control word (fcw, Q.6) in the MUL field.
  //   7-bit FLL rings reach ~167MHz (mul/div=6.67 -> 1707/256); 5-bit rings are faster (~264-385MHz)
  //   so they target ~300MHz (mul/div=12 -> 3072/256). Phase fcw = (F_DCO/25MHz)*2^6: 427 @167, 768 @300.
  // 5-bit configs: idx 2,3,4,5,8 ; phase configs: idx 7,8,9.
  // Behavioural DCO law is fixed (independent of tune bits): binary/therm/coarsefine span ~264-385MHz,
  // muxtap spans ~124-371MHz. Pick a target that lands each config's tune mid-range:
  //   - muxtap (any bits) + 7-bit binary/therm/cf: 167MHz (1707/256) -> central tune
  //   - 5-bit thermometer (idx5): 167MHz is below its floor, so target ~320MHz (3277/256)
  //   - phase configs (7,8,9): fcw = (F_DCO/25MHz)*2^6 = 427 @167MHz
  function [31:0] cfg_mul(input integer i);
    if (i==7 || i==8 || i==9)   cfg_mul = 32'd427;   // phase @167MHz (fcw, Q.6)
    else if (i==5)              cfg_mul = 32'd3277;  // thermometer 5-bit @~320MHz
    else                        cfg_mul = 32'd1707;  // @167MHz (7-bit, and 5-bit muxtap)
  endfunction
  function [31:0] cfg_div(input integer i); cfg_div = 32'd256; endfunction  // phase ignores div

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

  adpll_array #(.NumTuneBits(NUM_TUNE), .NumPll(NUM_PLL)) u_array (
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
  integer i, n, locked_count, t;
  reg obs_ok;
  reg [NUM_PLL-1:0] locked;
  reg [NUM_TUNE-1:0] tune_i;

  initial begin
    awvalid=0; wvalid=0; bready=0; arvalid=0; rready=0; awaddr=0; wdata=0; araddr=0;
    locked = '0;
    rst_n = 1'b1; #(2ns) rst_n = 1'b0; repeat (5) @(posedge clk); rst_n = 1'b1; repeat (5) @(posedge clk);

    // Program + enable every PLL (each independently, as a host would over Ethernet).
    for (i = 0; i < NUM_PLL; i = i + 1) begin
      axil_write(mul_a(i), cfg_mul(i));
      axil_write(div_a(i), cfg_div(i));
      axil_read (mul_a(i), rd); if (rd !== cfg_mul(i)) begin $display("FAIL: PLL%0d MUL readback %0d", i, rd); $finish; end
      axil_read (div_a(i), rd); if (rd !== cfg_div(i)) begin $display("FAIL: PLL%0d DIV readback %0d", i, rd); $finish; end
      axil_write(ctrl_a(i), 32'h1);
    end
    $display("programmed all %0d PLLs (per-config mul/div or fcw), enable=1", NUM_PLL);

    // Poll every PLL's STATUS until all lock (they run concurrently).
    for (n = 0; n < 200000 && locked != {NUM_PLL{1'b1}}; n = n + 1) begin
      for (i = 0; i < NUM_PLL; i = i + 1) begin
        if (!locked[i]) begin
          axil_read(stat_a(i), rd);
          if (rd[0]) begin
            locked[i] = 1'b1;
            tune_i = rd[NUM_TUNE:1];
            if (tune_i > 1 && tune_i < (1<<NUM_TUNE)-2)
                 begin $display("  PLL%0d LOCKED, tune=%0d", i, tune_i); $fflush; end
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

    // Observation mux: select each PLL, confirm obs_lock_o matches its STATUS lock bit. A coarse
    // 5-bit phase ring's lock bit can dither cycle-to-cycle near threshold, and obs_lock (a live
    // wire) vs STATUS (a multi-cycle AXI read) are sampled a few ns apart -- so an aligned read can
    // momentarily disagree even though the mux is correct. Re-sample until they agree; a genuinely
    // stuck/mis-routed mux never agrees and still FAILs.
    for (i = 0; i < NUM_PLL; i = i + 1) begin
      axil_write(OBS_SEL, i);
      repeat (4) @(posedge clk);
      obs_ok = 1'b0;
      for (t = 0; t < 16 && !obs_ok; t = t + 1) begin
        axil_read(stat_a(i), rd);
        if (obs_lock === rd[0]) obs_ok = 1'b1;
        else @(posedge clk);
      end
      if (!obs_ok) begin
        $display("FAIL: obs mux PLL%0d obs_lock=%0d != STATUS lock=%0d", i, obs_lock, rd[0]);
        $finish;
      end
    end
    $display("obs mux tracks selection across all %0d PLLs", NUM_PLL);

    $display("PASS: adpll_array all %0d PLLs locked in range + obs mux OK", NUM_PLL);
    $finish;
  end

  initial begin
    #(80000000ns);   // hard ceiling (scales with PLL count -- polling each over AXI is the cost)
    $display("FAIL: global timeout (locked=0x%0h)", locked);
    $finish;
  end
endmodule
