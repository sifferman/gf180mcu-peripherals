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

// ring_dco_thermometer
//
// DCO survey variant: a ring oscillator tuned by a UNIT-weighted (thermometer) delay
// line, in contrast to ring_dco's binary weighting. The binary input tune_i is
// thermometer-decoded so that code k inserts exactly k identical unit delay stages (each
// one inverter pair) into the loop, every stage gated by its own mux2.
//
// Why this variant: with binary weighting, the segments differ in size (1, 2, 4, ...
// pairs), so layout/process mismatch between segments can make the period-vs-code curve
// non-monotonic at a major carry (e.g. 0111->1000) -- a differential-nonlinearity (DNL)
// problem. A unit-weighted (thermometer) array uses 2**NumTuneBits-1 identical stages, so
// each code step adds one nominally-identical delay and the curve is monotonic by
// construction; mismatch can be further averaged with dynamic element matching, the
// approach Staszewski uses for the DCO varactor bank: [Staszewski2006 §3.5] frequency
// resolution improved "through Sigma-Delta dithering and dynamic element matching." The
// cost is area: 2**NumTuneBits-1 unit cells + muxes versus ring_dco's N muxes.
//
// Same enable_i/tune_i/clk_o interface as ring_dco, so the two are drop-in swappable in
// adpll_ctrl. See adpll_ctrl.sv for the full reference list and src/adpll/README.md.

`timescale 1ns/1ps   // needed by the behavioural (ifndef SYNTHESIS) model's #-delays
`default_nettype none

(* keep_hierarchy *)
module ring_dco_thermometer #(
    parameter int unsigned NumTuneBits = 7
) (
    input  wire                   enable_i,
    input  wire [NumTuneBits-1:0] tune_i,
    output wire                   clk_o
);

localparam int unsigned NumUnits = (1 << NumTuneBits) - 1;

`ifdef SYNTHESIS

// Thermometer decode: unit_enable[k] = 1 iff k < tune_i.
wire [NumUnits-1:0] unit_enable;
for (genvar k_GEN = 0; k_GEN < NumUnits; k_GEN++) begin : decode
    assign unit_enable[k_GEN] = (k_GEN < tune_i);
end

wire feedback;
wire [NumUnits:0] node;

(* keep *) (* dont_touch = "true" *)
gf180mcu_as_sc_mcu7t3v3__nand2_2 u_gate (
    .A (enable_i),
    .B (feedback),
    .Y (node[0])
);

for (genvar k_GEN = 0; k_GEN < NumUnits; k_GEN++) begin : delay_unit
    wire mid, delayed;
    (* keep *) (* dont_touch = "true" *)
    gf180mcu_as_sc_mcu7t3v3__inv_2 u_inv_a (
        .A (node[k_GEN]),
        .Y (mid)
    );
    (* keep *) (* dont_touch = "true" *)
    gf180mcu_as_sc_mcu7t3v3__inv_2 u_inv_b (
        .A (mid),
        .Y (delayed)
    );
    // Insert this unit's delay when its thermometer bit is set, else bypass.
    (* keep *) (* dont_touch = "true" *)
    gf180mcu_as_sc_mcu7t3v3__mux2_2 u_sel (
        .A (node[k_GEN]),
        .B (delayed),
        .S (unit_enable[k_GEN]),
        .Y (node[k_GEN + 1])
    );
end

assign feedback = node[NumUnits];
assign clk_o    = node[NumUnits];

`else

// Behavioural model: half-period grows linearly with the number of inserted units, i.e.
// with the binary value of tune_i -- the same monotonic curve as ring_dco's behavioural
// model (the two differ only in silicon DNL, which a zero-delay sim cannot show).
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
