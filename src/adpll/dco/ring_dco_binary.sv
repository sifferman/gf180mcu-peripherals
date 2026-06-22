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

// ring_dco_binary
//
// Ref: Staszewski & Balsara (Wiley, 2006), Ch. 2-3 (ring DCO, delay tuning).
// All-standard-cell ring oscillator: a NAND gate gates/sustains oscillation and
// binary-weighted inverter-pair segments (one mux each) insert delay by the binary value of
// tune_i. SYNTHESIS = structural gf180 cells (keep/dont_touch); else a behavioural model.
//
// Parameters:
//   - NumTuneBits : tune-code width (number of delay elements)
// Ports:
//   - enable_i : gate oscillation
//   - tune_i   : unsigned tune code (higher = more delay = lower frequency)
//   - clk_o    : oscillator output

module ring_dco_binary #(
    parameter int unsigned NumTuneBits = 7
) (
    input  wire                   enable_i,
    input  wire [NumTuneBits-1:0] tune_i,
    output wire                   clk_o
);

`ifdef SYNTHESIS

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
        gf180mcu_as_sc_mcu7t3v3__inv_2 u_inv_a (
            .A (d[2*j_GEN]),
            .Y (d[2*j_GEN + 1])
        );
        (* keep *) (* dont_touch = "true" *)
        gf180mcu_as_sc_mcu7t3v3__inv_2 u_inv_b (
            .A (d[2*j_GEN + 1]),
            .Y (d[2*j_GEN + 2])
        );
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

// Behavioural model (event-driven simulation only; SYNTHESIS undefined). A real ring
// oscillator has no period in zero-delay RTL, so clk_o is a free-running clock whose
// half-period grows with tune_i. The numbers are illustrative; SPICE gives the true curve.
// Half-period is a realtime built from explicit ns time literals, so the #-delays carry their
// own units and do not depend on a `timescale. half_period >= BaseHalf > 0 always, so there
// is never a zero-delay loop.
localparam realtime BaseHalf = 1.0ns;   // half-period at tune=0
localparam realtime StepHalf = 0.1ns;   // added half-period per tune LSB
logic   clk_r = 1'b1;
realtime half_period;

always begin
    if (enable_i) begin
        half_period = BaseHalf + StepHalf * tune_i;
        #(half_period) clk_r = ~clk_r;
    end else begin
        clk_r = 1'b1;
        #(BaseHalf);
    end
end

assign clk_o = clk_r;

`endif

endmodule

