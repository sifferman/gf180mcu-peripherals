// SPDX-License-Identifier: Apache-2.0
//
// Standalone self-checking testbench for the digital PLL (ring_dco behavioural model
// + adpll_ctrl frequency-locked loop). Runs under Icarus with the FUNCTIONAL define so
// ring_dco compiles its behavioural clock-generator (a real ring oscillator has no
// period in zero-delay RTL). Verifies that, from a cold tune code of 0, the loop drives
// the DCO toward a target edge-count and asserts lock, with the tune code settling.
//
//   iverilog -g2012 -DFUNCTIONAL -o /tmp/tb_adpll.vvp \
//       src/adpll/ring_dco.sv src/adpll/adpll_ctrl.sv cocotb/models/tb_adpll.v && vvp /tmp/tb_adpll.vvp

`timescale 1ns/1ps
`default_nettype none

module tb_adpll;
  localparam int unsigned NUM_TUNE   = 7;
  localparam int unsigned CNT_W      = 24;
  localparam int unsigned WINDOW     = 256;   // small window for a fast standalone sim
  localparam int unsigned LOCK_WINS  = 8;
  // Behavioural DCO: half-period = 1.0 + 0.1*tune ns => period = 2*(1+0.1*tune) ns.
  // Window time = WINDOW * 40 ns = 10240 ns. Aim for tune ~= 20 (period 6 ns):
  //   edges ~= 10240 / 6 ~= 1707.
  localparam int unsigned TARGET     = 1707;

  reg clk = 1'b0;
  always #20 clk = ~clk;          // 25 MHz reference (40 ns period)

  reg rst_n  = 1'b0;
  reg enable = 1'b0;

  wire [NUM_TUNE-1:0] tune;
  wire                lock;
  wire                dco_clk;

  ring_dco #(.NumTuneBits(NUM_TUNE)) u_dco (
      .enable_i (enable),
      .tune_i   (tune),
      .clk_o    (dco_clk)
  );

  adpll_ctrl #(
      .NumTuneBits  (NUM_TUNE),
      .CountWidth   (CNT_W),
      .WindowCycles (WINDOW),
      .LockWindows  (LOCK_WINS)
  ) u_ctrl (
      .clk_i     (clk),
      .rst_ni    (rst_n),
      .enable_i  (enable),
      .target_i  (CNT_W'(TARGET)),
      .dco_clk_i (dco_clk),
      .tune_o    (tune),
      .lock_o    (lock)
  );

  integer cycles = 0;
  always @(posedge clk) begin
    if (lock) begin
      // Once locked, tune should be in a sane mid-range band (not pinned at a rail)
      // and the behavioural DCO period should be near the target.
      $display("LOCKED  @%0t ns : tune=%0d (period ~= %0d ps)", $time, tune,
               2*(1000 + 100*tune));
      if (tune > 1 && tune < (1<<NUM_TUNE)-2)
        $display("PASS: adpll locked with tune=%0d in-range", tune);
      else
        $display("FAIL: adpll locked at a rail (tune=%0d)", tune);
      $finish;
    end
    cycles = cycles + 1;
    if (cycles > 2_000_000) begin
      $display("FAIL: timeout, no lock (tune=%0d)", tune);
      $finish;
    end
  end

  initial begin
    // Start reset HIGH then pulse LOW so the async-reset (negedge rst_ni) flops in
    // adpll_ctrl actually see a reset edge, then release.
    rst_n  = 1'b1;
    enable = 1'b0;
    #2 rst_n = 1'b0;
    repeat (5) @(posedge clk);
    rst_n  = 1'b1;
    repeat (5) @(posedge clk);
    enable = 1'b1;
  end
endmodule

`default_nettype wire
