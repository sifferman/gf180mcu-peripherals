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

// adpll_tdc
//
// Ref: Staszewski & Balsara (Wiley, 2006), Ch. 6 (time-to-digital converter, flash delay line).
// Time-to-digital converter for the phase-domain ADPLL: at each reference edge (clk_i) it
// measures how far into the current DCO period the reference fell -- the sub-cycle fractional
// phase of dco_clk_i, in [0,1) scaled to 2^FracBits. The integer DCO phase is the edge count;
// this fraction is what gives the loop sub-cycle resolution (Staszewski's normalized OTW).
// SYNTHESIS = structural delay-line flash TDC (gf180 dlybuff chain sampled by dfxtp flops, then
// a thermometer popcount); else a behavioural model reading the elapsed time directly.
//
// Parameters:
//   - FracBits : fractional-phase resolution; structural delay line is 2^FracBits-1 taps
// Ports:
//   - clk_i      : reference clock (the instant whose DCO phase is measured)
//   - rst_ni     : async-low reset (behavioural register only)
//   - dco_clk_i  : DCO clock whose sub-cycle phase is measured
//   - frac_o     : fractional DCO phase at the clk_i edge, in [0,1) * 2^FracBits

module adpll_tdc #(
    parameter int unsigned FracBits = 6
) (
    input  wire                clk_i,
    input  wire                rst_ni,
    input  wire                dco_clk_i,
    output wire [FracBits-1:0] frac_o
);

localparam int unsigned NumTaps = (1 << FracBits) - 1;

`ifdef SYNTHESIS

// Flash TDC: the DCO edge propagates down a dlybuff delay line; the reference edge latches every
// tap at once, so the count of taps the edge has reached = elapsed DCO time in delay-cell units.
// NOTE: this is the raw delay-line count; a silicon build must back-annotate cell delays (SDF /
// SPICE) and size the line so 2^FracBits-1 taps span one DCO period (true Staszewski TDCs also
// measure the period and divide to normalise -- left as a follow-up).
wire [NumTaps:0] tap;
assign tap[0] = dco_clk_i;
for (genvar i_GEN = 0; i_GEN < NumTaps; i_GEN++) begin : delay_line
    (* keep *) (* dont_touch = "true" *)
    gf180mcu_as_sc_mcu7t3v3__dlybuff_2 u_dly (
        .A (tap[i_GEN]),
        .Y (tap[i_GEN + 1])
    );
end

wire [NumTaps-1:0] sampled;
for (genvar i_GEN = 0; i_GEN < NumTaps; i_GEN++) begin : sampler
    (* keep *) (* dont_touch = "true" *)
    gf180mcu_as_sc_mcu7t3v3__dfxtp_2 u_ff (
        .CLK (clk_i),
        .D   (tap[i_GEN + 1]),
        .Q   (sampled[i_GEN])
    );
end

function automatic logic [FracBits-1:0] popcount(logic [NumTaps-1:0] taps);
    popcount = '0;
    for (int i = 0; i < NumTaps; i++)
        popcount += FracBits'(taps[i]);
endfunction

logic [FracBits-1:0] frac_comb;
always_comb frac_comb = popcount(sampled);
assign frac_o = frac_comb;

`else

// Behavioural model: read the elapsed time from the last DCO rising edge to this reference edge
// and divide by the measured DCO period -> fraction in [0,1). Sim-only (uses $realtime, like the
// ring-DCO behavioural models); the structural delay line above is the synthesizable form.
realtime dco_rise_time, dco_rise_prev, dco_period;
initial begin
    dco_rise_time = 0.0;
    dco_rise_prev = 0.0;
    dco_period    = 2.0ns;   // seed (> 0) so the first divide is safe
end
always @(posedge dco_clk_i) begin
    dco_rise_prev = dco_rise_time;
    dco_rise_time = $realtime;
    if (dco_rise_time > dco_rise_prev)
        dco_period = dco_rise_time - dco_rise_prev;
end

logic [FracBits-1:0] frac_q;
real frac_real;
always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        frac_q <= '0;
    end else begin
        frac_real = (dco_period > 0.0) ? ($realtime - dco_rise_time) / dco_period : 0.0;
        if (frac_real < 0.0)   frac_real = 0.0;
        if (frac_real > 0.999) frac_real = 0.999;
        frac_q <= FracBits'($rtoi(frac_real * (1 << FracBits)));
    end
end
assign frac_o = frac_q;

`endif

endmodule
