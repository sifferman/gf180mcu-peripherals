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

// adpll_controller_linear
//
// Ref: Kratyuk, Hanumolu, Moon & Mayaram, IEEE TCAS-II 54(3), 2007 (full digital PI
// loop-filter design procedure; power-of-two alpha/beta).
// Linear PI FLL loop filter: drives the multi-bit frequency error (dco_edge_count - mul) to zero
// with anti-windup, so F_DCO = (mul/div) * F_clk_i. Same front end / lock detector as the
// bang-bang sibling; only the filter differs.
//
// Parameters:
//   - NumTuneBits       : DCO tune-code width
//   - MaxEdgesPerWindow : max edges/window (sets mul_i / dco_edge_count width)
//   - MaxWindowSize     : max window length (sets div_i width)
//   - MinSamplesForLock, BandRadius : lock-detector in-band samples / +/- tolerance
//   - AlphaShift, BetaShift : proportional / integral gains = 2^-shift
// Ports:
//   - clk_i, rst_ni, enable_i
//   - mul_i, div_i : synthesizer ratio N / M (runtime)
//   - dco_clk_i    : DCO clock feedback
//   - tune_o       : DCO tune code
//   - lock_o       : lock asserted

module adpll_controller_linear #(
    parameter  int unsigned NumTuneBits = 7,
    parameter  int unsigned MaxEdgesPerWindow = (1 << 24) - 1,
    localparam int unsigned EdgeCountWidth    = $clog2(MaxEdgesPerWindow + 1),
    parameter  int unsigned MaxWindowSize     = (1 << 16) - 1,
    localparam int unsigned WindowSizeWidth   = $clog2(MaxWindowSize + 1),
    parameter  int unsigned MinSamplesForLock = 8,
    parameter  int unsigned BandRadius  = 2,    // linear loop dithers a little more than bang-bang
    // small alpha (integral-dominant) so a coarse DCO's huge cold-start error can't rail the loop
    parameter int unsigned AlphaShift  = 10,   // proportional gain alpha = 2^-AlphaShift
    parameter int unsigned BetaShift   = 8     // integral gain    beta  = 2^-BetaShift
) (
    input  wire                       clk_i,
    input  wire                       rst_ni,

    input  wire                       enable_i,
    input  wire [EdgeCountWidth-1:0]  mul_i,
    input  wire [WindowSizeWidth-1:0] div_i,
    input  wire                       dco_clk_i,

    output wire [NumTuneBits-1:0]     tune_o,
    output wire                       lock_o
);

wire [EdgeCountWidth-1:0] dco_edge_count;
wire                      sample_valid;

adpll_freq_counter #(
    .MaxEdgesPerWindow(MaxEdgesPerWindow),
    .MaxWindowSize(MaxWindowSize)
) adpll_freq_counter (
    .clk_i,
    .rst_ni,
    .enable_i,
    .window_length_i(div_i),
    .dco_clk_i,
    .dco_edge_count_o(dco_edge_count),
    .sample_valid_o  (sample_valid)
);

localparam int unsigned TuneMax  = (1 << NumTuneBits) - 1;
localparam int unsigned AccWidth = NumTuneBits + BetaShift + 4;
// Anti-windup limit: keep beta*accumulator inside the tune range.
localparam logic signed [AccWidth-1:0] AccMax = AccWidth'(TuneMax) <<< BetaShift;

logic signed [AccWidth-1:0] accumulator_d, accumulator_q;  // integral accumulator (anti-windup)
logic [NumTuneBits-1:0]     tune_d, tune_q;                // PI output to the DCO

// Standard 3-argument clamp: min(max(lo, value), hi).
function automatic int clamp(int lo, int value, int hi);
    clamp = (value < lo) ? lo : (value > hi) ? hi : value;
endfunction

// PI loop filter; update only on a fresh measurement (gating lives in _d, not the always_ff).
always_comb begin
    logic signed [EdgeCountWidth+1:0] error;             // signed frequency error (edges/window)
    logic signed [AccWidth-1:0]       accumulator_sum;
    logic signed [AccWidth+1:0]       control_word;      // alpha*error + beta*accumulator
    error           = '0;   // default the temporaries so no latch is inferred (used only below)
    accumulator_sum = '0;
    control_word    = '0;
    accumulator_d   = accumulator_q;
    tune_d          = tune_q;
    if (enable_i && sample_valid) begin
        error           = $signed({2'b0, dco_edge_count}) - $signed({2'b0, mul_i});
        accumulator_sum = accumulator_q + AccWidth'(error);
        accumulator_d   = (accumulator_sum < 0)      ? '0 :
                          (accumulator_sum > AccMax) ? AccMax : accumulator_sum;
        // gains are arithmetic right shifts (alpha = 2^-AlphaShift, beta = 2^-BetaShift)
        control_word    = (AccWidth+2)'(error >>> AlphaShift) + (AccWidth+2)'(accumulator_d >>> BetaShift);
        tune_d          = NumTuneBits'(clamp(0, int'(control_word), int'(TuneMax)));
    end
end

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        accumulator_q <= '0;
        tune_q        <= '0;
    end else begin
        accumulator_q <= accumulator_d;
        tune_q        <= tune_d;
    end
end

// The linear loop settles to a near-static code, so watch the output tune directly.
adpll_lock_detect #(
    .SampleWidth(NumTuneBits),
    .MinSamplesForLock(MinSamplesForLock),
    .BandRadius (BandRadius)
) adpll_lock_detect (
    .clk_i,
    .rst_ni,
    .enable_i,
    .sample_valid_i (sample_valid),
    .tuning_sample_i(tune_q),
    .lock_o         (lock_o)
);

assign tune_o = tune_q;

endmodule
