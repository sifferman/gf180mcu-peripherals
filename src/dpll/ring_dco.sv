// SPDX-FileCopyrightText: © 2026 gf180mcu-peripherals Authors
// SPDX-License-Identifier: Apache-2.0
//
// ring_dco — digitally-controlled ring oscillator (binary-weighted delay select)
//
// A ring oscillator whose period is tuned by a binary-weighted mux chain. The loop
// is one NAND2 (gates oscillation with `enable_i`, contributes the single inversion
// that makes the ring oscillate) followed by NUM_TUNE_BITS weighted delay segments.
// Segment i is a string of 2**i non-inverting buffer stages (inverter pairs); a mux2
// per segment selects whether that segment's delay is inserted (tune bit set) or
// bypassed. Total inserted delay is therefore proportional to the binary value of
// `tune_i`, giving a monotonic period-vs-code curve over 0 .. 2**NUM_TUNE_BITS-1 units.
//
// This is a hard combinational loop, so:
//   * every cell is instantiated from the gf180mcu 3v3 standard-cell library by name
//     and carries (* keep *)/(* dont_touch *) so synthesis/PnR cannot dissolve the
//     loop or collapse the delay chain;
//   * its real frequency-vs-code behaviour is only meaningful after parasitic
//     extraction — characterize in SPICE (see `make dco-spice`), not in RTL/STA;
//   * for event-driven simulation a zero-delay combinational loop cannot be evaluated,
//     so a behavioural clock-generator model (period = f(tune_i)) is compiled instead
//     under the FUNCTIONAL define used by the gate-level/cocotb testbenches.
//
// The DCO is a standalone, observe-only block: it does NOT clock the core. `enable_i`
// and `tune_i` are driven from a memory-mapped CSR (set over Ethernet); `clk_o` and the
// lock status are brought out to the analog observation pads via dpll_ctrl.

`timescale 1ns/1ps   // needed by the FUNCTIONAL behavioural model's #-delays
`default_nettype none

(* keep_hierarchy *)
module ring_dco #(
    parameter int unsigned NumTuneBits = 7
) (
    input  wire                    enable_i,   // 1 = oscillate, 0 = hold clk_o high
    input  wire [NumTuneBits-1:0]  tune_i,     // binary-weighted period control
    output wire                    clk_o       // oscillator output
);

`ifndef FUNCTIONAL
  // -------------------------------------------------------------------------
  // Structural implementation (synthesis / SPICE extraction).
  //
  // node[0]            = NAND2(enable_i, feedback)         -- gate + inversion
  // node[i+1]          = mux2( bypass=node[i], delayed_i, S=tune_i[i] )
  // feedback / clk_o   = node[NumTuneBits]
  // -------------------------------------------------------------------------
  wire feedback;
  wire [NumTuneBits:0] node;

  // Oscillator gate: when enable_i = 0 the NAND output is forced high and the ring
  // stops; when enable_i = 1 it acts as the inverting element that sustains oscillation.
  (* keep *) (* dont_touch = "true" *)
  gf180mcu_as_sc_mcu7t3v3__nand2_2 u_gate (
      .A (enable_i),
      .B (feedback),
      .Y (node[0])
  );

  for (genvar i = 0; i < NumTuneBits; i++) begin : g_seg
    // Binary-weighted delay segment: 2**i non-inverting buffer stages (inverter pairs).
    localparam int unsigned NumStages = (1 << i);
    wire [2*NumStages:0] d;
    assign d[0] = node[i];
    for (genvar j = 0; j < NumStages; j++) begin : g_pair
      (* keep *) (* dont_touch = "true" *)
      gf180mcu_as_sc_mcu7t3v3__inv_2 u_inv_a (.A (d[2*j]),   .Y (d[2*j + 1]));
      (* keep *) (* dont_touch = "true" *)
      gf180mcu_as_sc_mcu7t3v3__inv_2 u_inv_b (.A (d[2*j + 1]), .Y (d[2*j + 2]));
    end
    // Select the weighted delay (B) when this tune bit is set, else bypass (A).
    (* keep *) (* dont_touch = "true" *)
    gf180mcu_as_sc_mcu7t3v3__mux2_2 u_sel (
        .A (node[i]),         // bypass
        .B (d[2*NumStages]),  // delayed by 2**i inverter pairs
        .S (tune_i[i]),
        .Y (node[i + 1])
    );
  end

  assign feedback = node[NumTuneBits];
  assign clk_o    = node[NumTuneBits];

`else
  // -------------------------------------------------------------------------
  // Behavioural model (event-driven simulation only).
  //
  // A real ring oscillator has no period in zero-delay RTL, so model clk_o as a
  // free-running clock whose half-period grows monotonically with `tune_i`. The
  // numbers are illustrative (a nominal gf180 3v3 inverter pair is ~hundreds of ps);
  // SPICE gives the true curve. This only exists so the digital/cocotb testbenches
  // can observe a toggling clk_o and exercise dpll_ctrl's lock logic.
  // -------------------------------------------------------------------------
  // Half-period in picoseconds (integer, to stay portable across simulators — a
  // `real'(vector)` delay cast was unreliable). With `timescale 1ns/1ps a delay of
  // `#(N*1ps)` is written as #(N/1000.0) ns; we keep an integer ps count and convert.
  localparam integer BaseHalfPs = 1000;  // floor delay (gate + muxes) at code 0, in ps
  localparam integer StepHalfPs = 100;   // added ps per delay unit
  reg     clk_r = 1'b1;
  integer half_ps;

  // Free-running half-period generator. half_ps >= BaseHalfPs > 0 always, so there is
  // never a zero-delay loop. When disabled, hold clk_o high (matching the NAND output at
  // enable_i = 0) and still advance time on a fixed grid.
  always begin
    if (enable_i) begin
      half_ps = BaseHalfPs + StepHalfPs * tune_i;
      #(half_ps / 1000.0) clk_r = ~clk_r;
    end else begin
      clk_r = 1'b1;
      #(BaseHalfPs / 1000.0);
    end
  end

  assign clk_o = clk_r;
`endif

endmodule

`default_nettype wire
