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
// Ref: Staszewski & Balsara (Wiley, 2006), Ch. 3 (thermometer coding / dynamic element
// matching).
// Ring oscillator tuned by a UNIT-weighted (thermometer) delay line: code k inserts k
// identical unit-pair delays, so the curve is monotonic by construction (2^N-1 units).
// SYNTHESIS = structural gf180 cells; else a behavioural model.
//
// Parameters:
//   - NumTuneBits : tune-code width (number of delay elements)
// Ports:
//   - enable_i : gate oscillation
//   - tune_i   : unsigned tune code (higher = more delay = lower frequency)
//   - clk_o    : oscillator output

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
// with the binary value of tune_i -- the same monotonic curve as ring_dco_binary's behavioural
// model (the two differ only in silicon DNL, which a zero-delay sim cannot show).
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

