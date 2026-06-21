// SPDX-FileCopyrightText: © 2026 gf180mcu-peripherals Authors
// SPDX-License-Identifier: Apache-2.0
//
// dpll_ctrl — digital frequency-locked control loop for ring_dco
//
// A bang-bang frequency-locked loop. Over a fixed measurement window of `WindowCycles`
// reference-clock cycles it counts how many DCO edges occurred, compares that against a
// programmable target, and nudges the DCO tune code by ±1 each window to drive the error
// toward zero. Because the DCO is coarse (one tune LSB moves the frequency by far more
// than a few edges/window), a bang-bang loop dithers by ±1 code at lock and can never sit
// inside a tight edge-count tolerance. So lock is declared on the *tune code* instead: once
// the code stays inside a ±1 band of a running centre for `LockWindows` consecutive windows
// (i.e. it has stopped converging and is only hunting the LSB), `lock_o` asserts; a larger
// excursion re-centres the band and drops lock.
//
// Clock-domain crossing: the DCO is asynchronous to the reference clock. The DCO cycle
// count is kept in a Gray-coded free-running counter and sampled into the reference
// domain through a two-flop synchronizer — Gray coding guarantees at most one bit changes
// per DCO edge, so a metastable sample is off by at most one count, which the loop filter
// tolerates. Per-window deltas are computed from successive samples.
//
// Style: lowRISC (_d/_q registers, synchronous active-low reset, ready/valid-free simple
// datapath). All control state is in the reference clock domain except the small Gray
// counter in the DCO domain.

`default_nettype none

module dpll_ctrl #(
    parameter int unsigned NumTuneBits  = 7,
    parameter int unsigned CountWidth   = 24,   // DCO-edge counter width
    parameter int unsigned WindowCycles = 4096, // reference cycles per measurement window
    parameter int unsigned LockWindows   = 8     // consecutive in-band windows to declare lock
) (
    input  wire                    clk_i,      // reference clock (core clock domain)
    input  wire                    rst_ni,     // synchronous active-low reset
    input  wire                    enable_i,   // run the loop (else hold tune/lock cleared)
    input  wire [CountWidth-1:0]   target_i,   // target DCO edges per window
    input  wire                    dco_clk_i,  // ring_dco output (asynchronous)

    output wire [NumTuneBits-1:0]  tune_o,     // tune code to ring_dco
    output wire                    lock_o      // frequency lock achieved
);

  // ---------------------------------------------------------------------------
  // DCO domain: Gray-coded free-running edge counter.
  // ---------------------------------------------------------------------------
  function automatic [CountWidth-1:0] bin2gray(input [CountWidth-1:0] b);
    bin2gray = b ^ (b >> 1);
  endfunction
  function automatic [CountWidth-1:0] gray2bin(input [CountWidth-1:0] g);
    integer k;
    begin
      gray2bin = g;
      for (k = 1; k < CountWidth; k = k + 1)
        gray2bin = gray2bin ^ (g >> k);
    end
  endfunction

  reg [CountWidth-1:0] dco_cnt_bin_q;
  reg [CountWidth-1:0] dco_cnt_gray_q;

  always @(posedge dco_clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      dco_cnt_bin_q  <= '0;
      dco_cnt_gray_q <= '0;
    end else begin
      dco_cnt_bin_q  <= dco_cnt_bin_q + 1'b1;
      dco_cnt_gray_q <= bin2gray(dco_cnt_bin_q + 1'b1);
    end
  end

  // ---------------------------------------------------------------------------
  // Reference domain: synchronize the Gray count, run the window + loop filter.
  // ---------------------------------------------------------------------------
  reg [CountWidth-1:0] gray_sync0_q, gray_sync1_q;
  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      gray_sync0_q <= '0;
      gray_sync1_q <= '0;
    end else begin
      gray_sync0_q <= dco_cnt_gray_q;
      gray_sync1_q <= gray_sync0_q;
    end
  end
  wire [CountWidth-1:0] dco_cnt_sync = gray2bin(gray_sync1_q);

  // Window timer.
  localparam int unsigned WindowW = (WindowCycles <= 1) ? 1 : $clog2(WindowCycles);
  reg [WindowW-1:0]    window_cnt_q;
  wire                 window_tick = (window_cnt_q == WindowW'(WindowCycles - 1));

  // Loop state.
  reg [CountWidth-1:0]  cnt_at_window_q;        // DCO count snapshot at last window edge
  reg [NumTuneBits-1:0] tune_q;
  reg [NumTuneBits-1:0] lock_centre_q;          // running centre of the lock band
  reg [$clog2(LockWindows+1)-1:0] in_band_q;    // consecutive in-band windows
  reg                   lock_q;

  wire [CountWidth-1:0] measured = dco_cnt_sync - cnt_at_window_q;  // edges this window
  wire too_fast = measured > target_i;                              // freq high => add delay
  wire too_slow = measured < target_i;

  // Next tune code (saturating ±1 bang-bang step). More tune => more ring delay =>
  // lower frequency => fewer edges, so speed up by decrementing.
  reg [NumTuneBits-1:0] tune_d;
  always @(*) begin
    tune_d = tune_q;
    if (too_fast && (tune_q != {NumTuneBits{1'b1}}))
      tune_d = tune_q + 1'b1;
    else if (too_slow && (tune_q != {NumTuneBits{1'b0}}))
      tune_d = tune_q - 1'b1;
  end

  // In-band test: is the next code within ±1 of the running lock centre?
  wire signed [NumTuneBits+1:0] band_err =
      $signed({2'b0, tune_d}) - $signed({2'b0, lock_centre_q});
  wire in_band = (band_err >= -1) && (band_err <= 1);

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      window_cnt_q    <= '0;
      cnt_at_window_q <= '0;
      tune_q          <= {NumTuneBits{1'b0}};
      lock_centre_q   <= {NumTuneBits{1'b0}};
      in_band_q       <= '0;
      lock_q          <= 1'b0;
    end else if (!enable_i) begin
      window_cnt_q    <= '0;
      cnt_at_window_q <= dco_cnt_sync;
      // hold tune_q so re-enabling resumes near the last operating point
      in_band_q       <= '0;
      lock_q          <= 1'b0;
    end else begin
      if (window_tick) begin
        window_cnt_q    <= '0;
        cnt_at_window_q <= dco_cnt_sync;
        tune_q          <= tune_d;

        // Lock detector: count consecutive windows whose code stays within ±1 of the
        // running centre. A larger excursion (still converging) re-centres and resets.
        if (in_band) begin
          if (in_band_q == LockWindows[$bits(in_band_q)-1:0])
            lock_q <= 1'b1;
          else
            in_band_q <= in_band_q + 1'b1;
        end else begin
          lock_centre_q <= tune_d;
          in_band_q     <= '0;
          lock_q        <= 1'b0;
        end
      end else begin
        window_cnt_q <= window_cnt_q + 1'b1;
      end
    end
  end

  assign tune_o = tune_q;
  assign lock_o = lock_q;

endmodule

`default_nettype wire
