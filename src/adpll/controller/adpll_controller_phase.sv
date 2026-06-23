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

// adpll_controller_phase
//
// Ref: Staszewski & Balsara (Wiley, 2006), Ch. 4-5 (phase-domain ADPLL: reference/variable phase
// accumulators + TDC); Kratyuk et al. (IEEE TCAS-II 54(3), 2007, type-II PI loop filter).
// A true phase-locked (not just frequency-locked) all-digital PLL. Each reference cycle it
// advances the reference phase by fcw_i (the frequency control word, F_DCO/F_clk_i in Q.FracBits)
// and the variable phase by the DCO edges in that cycle (integer, from adpll_freq_counter run with
// a 1-cycle window) plus the TDC's sub-cycle fraction. The phase error (variable - reference)
// drives a type-II PI loop filter -> tune, so the loop nulls *phase*, not just average frequency.
//
// Parameters:
//   - NumTuneBits       : DCO tune-code width
//   - MaxEdgesPerWindow : max DCO edges in one reference cycle (sizes the edge counter)
//   - FcwWidth          : frequency control word width (Q(FcwWidth-FracBits).FracBits)
//   - FracBits          : fractional-phase (TDC) resolution
//   - PhaseWidth        : phase-accumulator / error width (must hold the acquisition transient)
//   - AlphaShift        : proportional gain = 2^-AlphaShift
//   - BetaShift         : integral     gain = 2^-BetaShift
//   - MinSamplesForLock, BandRadius : lock-detector in-band samples / +/- tolerance
// Ports:
//   - clk_i, rst_ni, enable_i
//   - fcw_i        : frequency control word, F_DCO/F_clk_i in Q.FracBits (runtime)
//   - dco_clk_i    : DCO clock feedback
//   - tdc_frac_i   : sub-cycle DCO phase at this clk_i edge (from adpll_tdc), Q0.FracBits
//   - tune_o       : DCO tune code
//   - lock_o       : lock asserted

module adpll_controller_phase #(
    parameter  int unsigned NumTuneBits       = 7,
    parameter  int unsigned MaxEdgesPerWindow = (1 << 12) - 1,
    localparam int unsigned EdgeCountWidth    = $clog2(MaxEdgesPerWindow + 1),
    parameter  int unsigned FcwWidth          = 24,
    parameter  int unsigned FracBits          = 6,
    parameter  int unsigned PhaseWidth        = 24,
    parameter  int unsigned AlphaShift        = 6,    // proportional gain alpha = 2^-AlphaShift
    parameter  int unsigned BetaShift         = 11,   // integral     gain beta  = 2^-BetaShift
    parameter  int unsigned MinSamplesForLock = 8,
    parameter  int unsigned BandRadius        = 2
) (
    input  wire                  clk_i,
    input  wire                  rst_ni,

    input  wire                  enable_i,
    input  wire [FcwWidth-1:0]   fcw_i,        // F_DCO/F_clk_i in Q.FracBits (multiply ratio)
    input  wire                  dco_clk_i,
    input  wire [FracBits-1:0]   tdc_frac_i,   // sub-cycle DCO phase at this reference edge
    output wire [NumTuneBits-1:0] tune_o,
    output wire                  lock_o
);

// Variable phase front end: edges per single reference cycle (a 1-cycle measurement window),
// accumulated into the running DCO phase below.
wire [EdgeCountWidth-1:0] edges_this_cycle;
wire                      sample_valid;

adpll_freq_counter #(
    .MaxEdgesPerWindow(MaxEdgesPerWindow),
    .MaxWindowSize(1)
) adpll_freq_counter (
    .clk_i,
    .rst_ni,
    .enable_i,
    .window_length_i(1'b1),
    .dco_clk_i,
    .dco_edge_count_o(edges_this_cycle),
    .sample_valid_o  (sample_valid)
);

localparam int unsigned TuneMax = (1 << NumTuneBits) - 1;

// Standard 3-argument clamp: min(max(lo, value), hi).
function automatic int clamp(int lo, int value, int hi);
    clamp = (value < lo) ? lo : (value > hi) ? hi : value;
endfunction

// phase_detector_q accumulates the integer DCO phase minus the reference phase (both Q.FracBits);
// adding tdc_frac_i gives the full phase error (DCO ahead => positive => raise tune => slow down).
logic signed [PhaseWidth-1:0] phase_detector_d, phase_detector_q;   // integer DCO phase - reference phase
logic signed [PhaseWidth-1:0] integral_d,       integral_q;         // PI integral path (anti-windup)
logic        [NumTuneBits-1:0] tune_d,          tune_q;             // PI output to the DCO

localparam logic signed [PhaseWidth-1:0] IntegralMax = PhaseWidth'(TuneMax) <<< BetaShift;

// The PI sum (control_word) is clamped through `int`, so keep PhaseWidth+2 <= 32.

// type-II PI loop filter on the phase error; update only on a fresh measurement.
always_comb begin
    logic signed [PhaseWidth-1:0] phase_advance;     // DCO phase advance - reference phase advance
    logic signed [PhaseWidth-1:0] phase_error;       // full phase error, incl. TDC fraction
    logic signed [PhaseWidth-1:0] integral_sum;
    logic signed [PhaseWidth+1:0] control_word;      // alpha*error + beta*integral

    phase_error      = '0;   // default the temporaries so no latch is inferred (used only below)
    integral_sum     = '0;
    control_word     = '0;
    phase_advance    = PhaseWidth'($signed({1'b0, edges_this_cycle}) <<< FracBits) - PhaseWidth'(fcw_i);
    phase_detector_d = phase_detector_q;
    integral_d       = integral_q;
    tune_d           = tune_q;
    if (enable_i && sample_valid) begin
        phase_detector_d = phase_detector_q + phase_advance;
        phase_error      = phase_detector_d + PhaseWidth'($signed({1'b0, tdc_frac_i}));
        integral_sum     = integral_q + phase_error;
        integral_d       = (integral_sum < 0)           ? '0 :
                           (integral_sum > IntegralMax) ? IntegralMax : integral_sum;
        control_word     = (PhaseWidth+2)'(phase_error >>> AlphaShift)
                         + (PhaseWidth+2)'(integral_d  >>> BetaShift);
        tune_d           = NumTuneBits'(clamp(0, int'(control_word), int'(TuneMax)));
    end
end

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        phase_detector_q <= '0;
        integral_q       <= '0;
        tune_q           <= '0;
    end else begin
        phase_detector_q <= phase_detector_d;
        integral_q       <= integral_d;
        tune_q           <= tune_d;
    end
end

// A phase-locked loop settles to a near-static tune, so watch the output tune directly.
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
