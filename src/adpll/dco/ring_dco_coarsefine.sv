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

// ring_dco_coarsefine
//
// Ref: Staszewski & Balsara (Wiley, 2006), Ch. 5 (normalized DCO: coarse + fine tuning banks).
// Two-bank ring oscillator. The high NumCoarseBits of tune_i drive a thermometer COARSE bank
// whose unit delay is one inverter chain of 2^NumFineBits pairs; the low NumFineBits drive a
// thermometer FINE bank whose unit delay is a single inverter pair. The coarse unit delay is
// therefore exactly 2^NumFineBits fine units, so the two banks splice into one monotonic curve
// (a wide range from a few coarse units, fine resolution from the fine units -- the resolution/
// range trade a single bank can't make). SYNTHESIS = structural gf180 cells; else behavioural.
//
// Parameters:
//   - NumTuneBits : total tune-code width
//   - NumFineBits : low bits driving the fine bank (the rest drive the coarse bank)
// Ports:
//   - enable_i : gate oscillation
//   - tune_i   : unsigned tune code (higher = more delay = lower frequency)
//   - clk_o    : oscillator output

module ring_dco_coarsefine #(
    parameter int unsigned NumTuneBits = 7,
    parameter int unsigned NumFineBits = 3
) (
    input  wire                   enable_i,
    input  wire [NumTuneBits-1:0] tune_i,
    output wire                   clk_o
);

if (NumFineBits >= NumTuneBits)
    $error("NumFineBits must be < NumTuneBits (need at least one coarse bit)");

localparam int unsigned NumCoarseBits  = NumTuneBits - NumFineBits;
localparam int unsigned NumCoarseUnits = (1 << NumCoarseBits) - 1;
localparam int unsigned NumFineUnits   = (1 << NumFineBits) - 1;
localparam int unsigned CoarsePairs    = (1 << NumFineBits);   // inverter pairs per coarse unit

wire [NumCoarseBits-1:0] coarse_code = tune_i[NumTuneBits-1:NumFineBits];
wire [NumFineBits-1:0]   fine_code   = tune_i[NumFineBits-1:0];

`ifdef SYNTHESIS

wire feedback;
wire [NumCoarseUnits:0] coarse_node;

(* keep *) (* dont_touch = "true" *)
gf180mcu_as_sc_mcu7t3v3__nand2_2 u_gate (
    .A (enable_i),
    .B (feedback),
    .Y (coarse_node[0])
);

// Coarse bank: unit k inserts CoarsePairs inverter-pairs of delay when k < coarse_code.
for (genvar k_GEN = 0; k_GEN < NumCoarseUnits; k_GEN++) begin : coarse_unit
    wire [2*CoarsePairs:0] d;
    assign d[0] = coarse_node[k_GEN];
    for (genvar j_GEN = 0; j_GEN < CoarsePairs; j_GEN++) begin : inverter_pair
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
        .A (coarse_node[k_GEN]),
        .B (d[2*CoarsePairs]),
        .S (k_GEN < coarse_code),
        .Y (coarse_node[k_GEN + 1])
    );
end

// Fine bank: unit k inserts one inverter-pair of delay when k < fine_code.
wire [NumFineUnits:0] fine_node;
assign fine_node[0] = coarse_node[NumCoarseUnits];
for (genvar k_GEN = 0; k_GEN < NumFineUnits; k_GEN++) begin : fine_unit
    wire mid, delayed;
    (* keep *) (* dont_touch = "true" *)
    gf180mcu_as_sc_mcu7t3v3__inv_2 u_inv_a (
        .A (fine_node[k_GEN]),
        .Y (mid)
    );
    (* keep *) (* dont_touch = "true" *)
    gf180mcu_as_sc_mcu7t3v3__inv_2 u_inv_b (
        .A (mid),
        .Y (delayed)
    );
    (* keep *) (* dont_touch = "true" *)
    gf180mcu_as_sc_mcu7t3v3__mux2_2 u_sel (
        .A (fine_node[k_GEN]),
        .B (delayed),
        .S (k_GEN < fine_code),
        .Y (fine_node[k_GEN + 1])
    );
end

assign feedback = fine_node[NumFineUnits];
assign clk_o    = fine_node[NumFineUnits];

`else

// Behavioural model: a coarse unit delay is exactly 2^NumFineBits fine units, so
// CoarseHalf*coarse + FineHalf*fine == FineHalf*tune_i -- the same monotonic curve as the
// single-bank DCOs (they differ only in silicon coarse/fine mismatch, which a zero-delay sim
// cannot show). half_period >= BaseHalf > 0 always, so there is never a zero-delay loop.
localparam realtime BaseHalf   = 1.0ns;                       // half-period at tune=0
localparam realtime FineHalf   = 0.1ns;                       // added half-period per fine LSB
localparam realtime CoarseHalf = FineHalf * (1 << NumFineBits);  // added half-period per coarse LSB
logic   clk_r = 1'b1;
realtime half_period;

always begin
    if (enable_i) begin
        half_period = BaseHalf + CoarseHalf * coarse_code + FineHalf * fine_code;
        #(half_period) clk_r = ~clk_r;
    end else begin
        clk_r = 1'b1;
        #(BaseHalf);
    end
end

assign clk_o = clk_r;

`endif

endmodule
