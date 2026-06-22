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

// ring_dco_muxtap
//
// Ref: Kajiwara & Nakagawa (early digital frequency synthesizer), via Staszewski & Balsara
// (Wiley, 2006), Ch. 1.
// Variable-LENGTH ring: a 2^N:1 binary mux tree selects which tap of an inverter-pair chain
// closes the loop, so tune_i sets the ring length (and thus frequency) directly.
// SYNTHESIS = structural gf180 cells; else a behavioural model.
//
// Parameters:
//   - NumTuneBits : tune-code width (number of delay elements)
// Ports:
//   - enable_i : gate oscillation
//   - tune_i   : unsigned tune code (higher = more delay = lower frequency)
//   - clk_o    : oscillator output

module ring_dco_muxtap #(
    parameter int unsigned NumTuneBits = 7
) (
    input  wire                   enable_i,
    input  wire [NumTuneBits-1:0] tune_i,
    output wire                   clk_o
);

localparam int unsigned NumTaps = (1 << NumTuneBits);

`ifdef SYNTHESIS

wire feedback;
wire node0;

(* keep *) (* dont_touch = "true" *)
gf180mcu_as_sc_mcu7t3v3__nand2_2 u_gate (
    .A (enable_i),
    .B (feedback),
    .Y (node0)
);

// Tap chain: tap[0] = gate output, tap[k] = tap[k-1] delayed by one inverter pair.
wire [NumTaps-1:0] tap;
assign tap[0] = node0;
for (genvar k_GEN = 1; k_GEN < NumTaps; k_GEN++) begin : tap_chain
    wire mid;
    (* keep *) (* dont_touch = "true" *)
    gf180mcu_as_sc_mcu7t3v3__inv_2 u_inv_a (
        .A (tap[k_GEN-1]),
        .Y (mid)
    );
    (* keep *) (* dont_touch = "true" *)
    gf180mcu_as_sc_mcu7t3v3__inv_2 u_inv_b (
        .A (mid),
        .Y (tap[k_GEN])
    );
end

// Binary mux tree: level L is selected by tune_i[L-1]; output of the top level is the
// chosen tap, fed back to close the loop.
wire [NumTaps-1:0] tree_level [NumTuneBits+1];
assign tree_level[0] = tap;
for (genvar lvl_GEN = 1; lvl_GEN <= NumTuneBits; lvl_GEN++) begin : tree_level_gen
    for (genvar i_GEN = 0; i_GEN < (NumTaps >> lvl_GEN); i_GEN++) begin : tree_mux
        (* keep *) (* dont_touch = "true" *)
        gf180mcu_as_sc_mcu7t3v3__mux2_2 u_mux (
            .A (tree_level[lvl_GEN-1][2*i_GEN]),
            .B (tree_level[lvl_GEN-1][2*i_GEN + 1]),
            .S (tune_i[lvl_GEN-1]),
            .Y (tree_level[lvl_GEN][i_GEN])
        );
    end
end

assign feedback = tree_level[NumTuneBits][0];
assign clk_o    = tree_level[NumTuneBits][0];

`else

// Behavioural model: half-period grows linearly with the selected ring length (tune_i).
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

