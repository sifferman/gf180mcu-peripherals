// Copyright (c) 2026 Ethan Sifferman
//
// Redistribution and use in source and binary forms, with or without modification, are permitted
// provided that the following conditions are met:
//
// 1. Redistributions of source code must retain the above copyright notice, this list of
//    conditions and the following disclaimer.
//
// 2. Redistributions in binary form must reproduce the above copyright notice, this list of
//    conditions and the following disclaimer in the documentation and/or other materials provided
//    with the distribution.
//
// 3. Neither the name of the copyright holder nor the names of its contributors may be used to
//    endorse or promote products derived from this software without specific prior written
//    permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR
// IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND
// FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR
// CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
// SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
// OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.

// ring_dco
//
// Digitally-controlled ring oscillator: one NAND2 gate (gates oscillation with enable_i
// and contributes the single inversion that sustains the ring) followed by NumTuneBits
// binary-weighted delay segments. Segment i is 2**i non-inverting inverter pairs; a mux2
// per segment selects whether that delay is inserted (tune bit set) or bypassed, so the
// inserted delay is proportional to the binary value of tune_i.
//
// It is a hard combinational loop, so every cell is instantiated from the gf180mcu 3v3
// library by name with keep/dont_touch (synthesis/PnR must not dissolve the loop), its
// real frequency-vs-code curve only exists after extraction (characterize in SPICE, see
// `make dco-spice`), and event-driven sim cannot evaluate a zero-delay loop so a
// behavioural clock-generator is compiled under FUNCTIONAL instead. Standalone observe-
// only block: it does not clock the core; enable_i/tune_i come from a CSR and clk_o/lock
// reach the analog pads via adpll_ctrl.

`timescale 1ns/1ps   // needed by the FUNCTIONAL behavioural model's #-delays
`default_nettype none

(* keep_hierarchy *)
module ring_dco #(
    parameter int unsigned NumTuneBits = 7
) (
    input  wire                   enable_i,
    input  wire [NumTuneBits-1:0] tune_i,
    output wire                   clk_o
);

`ifndef FUNCTIONAL

// Structural implementation (synthesis / SPICE extraction):
//   node[0]          = NAND2(enable_i, feedback)
//   node[i+1]        = mux2(bypass = node[i], delayed_i, S = tune_i[i])
//   feedback / clk_o = node[NumTuneBits]
wire feedback;
wire [NumTuneBits:0] node;

(* keep *) (* dont_touch = "true" *)
gf180mcu_as_sc_mcu7t3v3__nand2_2 u_gate (
    .A (enable_i),
    .B (feedback),
    .Y (node[0])
);

for (genvar i_GEN = 0; i_GEN < NumTuneBits; i_GEN++) begin : delay_segment
    localparam int unsigned NumStages = (1 << i_GEN);
    wire [2*NumStages:0] d;
    assign d[0] = node[i_GEN];
    for (genvar j_GEN = 0; j_GEN < NumStages; j_GEN++) begin : inverter_pair
        (* keep *) (* dont_touch = "true" *)
        gf180mcu_as_sc_mcu7t3v3__inv_2 u_inv_a (.A (d[2*j_GEN]),     .Y (d[2*j_GEN + 1]));
        (* keep *) (* dont_touch = "true" *)
        gf180mcu_as_sc_mcu7t3v3__inv_2 u_inv_b (.A (d[2*j_GEN + 1]), .Y (d[2*j_GEN + 2]));
    end
    (* keep *) (* dont_touch = "true" *)
    gf180mcu_as_sc_mcu7t3v3__mux2_2 u_sel (
        .A (node[i_GEN]),
        .B (d[2*NumStages]),
        .S (tune_i[i_GEN]),
        .Y (node[i_GEN + 1])
    );
end

assign feedback = node[NumTuneBits];
assign clk_o    = node[NumTuneBits];

`else

// Behavioural model (event-driven simulation only). A real ring oscillator has no period
// in zero-delay RTL, so clk_o is a free-running clock whose half-period grows with tune_i.
// The numbers are illustrative; SPICE gives the true curve. half_ps >= BaseHalfPs > 0
// always, so there is never a zero-delay loop. Half-period is kept in integer ps (a
// real'(vector) delay cast was unreliable) and `timescale 1ns/1ps converts via /1000.0.
localparam integer BaseHalfPs = 1000;
localparam integer StepHalfPs = 100;
logic   clk_r = 1'b1;
integer half_ps;

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
