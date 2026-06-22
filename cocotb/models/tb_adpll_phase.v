// SPDX-License-Identifier: Apache-2.0
//
// Testbench for the phase-domain ADPLL (ring DCO + TDC + phase-locked controller). Runs under
// Icarus (SYNTHESIS undefined) so the DCO and TDC compile their behavioural models. Unlike the
// frequency-locked tb_adpll, this loop nulls PHASE: the controller advances a reference phase by
// fcw_i each reference cycle and the variable phase by the DCO edge count plus the TDC fraction.
//
// 25 MHz reference (40 ns). With the behavioural DCO (half-period 1.0+0.1*tune ns), tune~=20 gives
// a 6 ns DCO period, so F_DCO/F_ref = 40/6 = 6.667; in Q.FracBits (FracBits=6) that is fcw = 427.
// Reports time-to-lock and the settled tune, PASSing on a sane mid-range code.

module tb_adpll_phase;
  localparam int unsigned NUM_TUNE = 7;
  localparam int unsigned FRAC     = 6;
  localparam int unsigned FCW_W    = 24;
  localparam int unsigned FCW      = 427;   // 6.667 * 2^FRAC  (targets tune ~= 20)

  reg clk = 1'b0;
  always #(20ns) clk = ~clk;          // 25 MHz reference (40 ns)

  reg rst_n  = 1'b1;
  reg enable = 1'b0;

  wire [NUM_TUNE-1:0] tune;
  wire                lock;
  wire                dco_clk;
  wire [FRAC-1:0]     tdc_frac;

  ring_dco_binary #(.NumTuneBits(NUM_TUNE)) u_dco (
      .enable_i(enable),
      .tune_i  (tune),
      .clk_o   (dco_clk)
  );

  adpll_tdc #(.FracBits(FRAC)) u_tdc (
      .clk_i    (clk),
      .rst_ni   (rst_n),
      .dco_clk_i(dco_clk),
      .frac_o   (tdc_frac)
  );

  adpll_controller_phase #(
      .NumTuneBits(NUM_TUNE),
      .FracBits   (FRAC),
      .FcwWidth   (FCW_W)
  ) u_ctrl (
      .clk_i     (clk),
      .rst_ni    (rst_n),
      .enable_i  (enable),
      .fcw_i     (FCW_W'(FCW)),
      .dco_clk_i (dco_clk),
      .tdc_frac_i(tdc_frac),
      .tune_o    (tune),
      .lock_o    (lock)
  );

  integer cycles = 0, enable_cycle = 0;

  always @(posedge clk) begin
    cycles = cycles + 1;
    if (lock) begin
      $display("LOCKED @%0t ns : tune=%0d  lock_time=%0d ref-cycles", $time, tune, cycles - enable_cycle);
      if (tune > 1 && tune < (1<<NUM_TUNE)-2) $display("PASS: phase adpll locked, tune=%0d in-range", tune);
      else                                    $display("FAIL: phase adpll locked at a rail (tune=%0d)", tune);
      $finish;
    end
    if (cycles > 2_000_000) begin $display("FAIL: timeout, no lock (tune=%0d)", tune); $finish; end
  end

  initial begin
    rst_n = 1'b1; enable = 1'b0;
    #(2ns) rst_n = 1'b0;                 // async-reset pulse for the gated DCO-domain counter
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (5) @(posedge clk);
    enable = 1'b1;
    enable_cycle = cycles;
  end
endmodule
