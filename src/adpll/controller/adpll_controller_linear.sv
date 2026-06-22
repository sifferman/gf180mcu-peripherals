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
// Linear PI FLL loop filter: drives the multi-bit frequency error (measured - mul) to zero
// with anti-windup, so F_DCO = (mul/div) * F_clk_i. Same front end / lock detector as the
// bang-bang sibling; only the filter differs.
//
// Parameters:
//   - NumTuneBits       : DCO tune-code width
//   - MaxEdgesPerWindow : max edges/window (sets mul_i / measured width)
//   - MaxWindowSize     : max window length (sets div_i width)
//   - LockWindows, LockBand : lock-detector samples / +/- tolerance
//   - AlphaShift, BetaShift : proportional / integral gains = 2^-shift
// Ports:
//   - clk_i, rst_ni, enable_i
//   - mul_i, div_i : synthesizer ratio N / M (runtime)
//   - dco_clk_i    : DCO clock feedback
//   - tune_o       : DCO tune code
//   - lock_o       : lock asserted

module adpll_controller_linear #(
    parameter int unsigned NumTuneBits = 7,
    parameter  int unsigned MaxEdgesPerWindow = (1 << 24) - 1,
    localparam int unsigned EdgeCountWidth    = $clog2(MaxEdgesPerWindow + 1),
    parameter  int unsigned MaxWindowSize     = (1 << 16) - 1,
    localparam int unsigned WindowSizeWidth   = $clog2(MaxWindowSize + 1),
    parameter int unsigned LockWindows = 8,
    parameter int unsigned LockBand    = 2,    // linear loop dithers a little more than bang-bang
    // On a COARSE DCO the from-cold frequency error is huge (thousands of edges), so the
    // proportional gain must be tiny or it slams tune to a rail and the loop oscillates
    // rail-to-rail. Hence alpha is small (integral-dominant acquisition); the proportional
    // term mainly damps near lock. A fine multi-bit DCO would tolerate a larger alpha.
    parameter int unsigned AlphaShift  = 10,   // proportional gain alpha = 2^-AlphaShift
    parameter int unsigned BetaShift   = 8     // integral gain    beta  = 2^-BetaShift
) (
    input  wire                   clk_i,
    input  wire                   rst_ni,
    input  wire                   enable_i,
    input  wire [EdgeCountWidth-1:0]  mul_i,
    input  wire [WindowSizeWidth-1:0]    div_i,
    input  wire                   dco_clk_i,

    output wire [NumTuneBits-1:0] tune_o,
    output wire                   lock_o
);

wire [EdgeCountWidth-1:0] measured;
wire                  sample_valid;

adpll_freq_counter #(
    .MaxEdgesPerWindow(MaxEdgesPerWindow),
    .MaxWindowSize(MaxWindowSize)
) u_meas (
    .clk_i,
    .rst_ni,
    .enable_i,
    .div_i,
    .dco_clk_i,
    .measured_o    (measured),
    .sample_valid_o(sample_valid)
);

localparam int unsigned TuneMax  = (1 << NumTuneBits) - 1;
localparam int unsigned AccWidth = NumTuneBits + BetaShift + 4;

logic signed [AccWidth-1:0]   acc_q;
logic [NumTuneBits-1:0]        tune_q;

wire signed [EdgeCountWidth+1:0] error = $signed({2'b0, measured}) - $signed({2'b0, mul_i});

// Integral accumulator step with anti-windup: keep beta*acc inside the tune range.
localparam logic signed [AccWidth-1:0] AccMax = AccWidth'(TuneMax) <<< BetaShift;
wire signed [AccWidth-1:0] acc_sum  = acc_q + AccWidth'(error);
wire signed [AccWidth-1:0] acc_step = (acc_sum < 0)      ? '0     :
                                      (acc_sum > AccMax) ? AccMax : acc_sum;

// PI output: ctrl = alpha*e + beta*acc (gains are arithmetic right shifts).
wire signed [EdgeCountWidth+1:0] prop_term  = error >>> AlphaShift;
wire signed [AccWidth-1:0]   integ_term = acc_step >>> BetaShift;
wire signed [AccWidth+1:0]   ctrl       = (AccWidth+2)'(prop_term) + (AccWidth+2)'(integ_term);

function automatic logic [NumTuneBits-1:0] clamp(input logic signed [AccWidth+1:0] v);
    if (v < 0)                            clamp = '0;
    else if (v > (AccWidth+2)'(TuneMax))  clamp = NumTuneBits'(TuneMax);
    else                                  clamp = NumTuneBits'(v);
endfunction
wire [NumTuneBits-1:0] tune_step = clamp(ctrl);

// Update only on a fresh measurement; the gating lives here in _d, not in the always_ff.
logic signed [AccWidth-1:0] acc_d;
logic [NumTuneBits-1:0]     tune_d;
always_comb begin
    acc_d  = acc_q;
    tune_d = tune_q;
    if (enable_i && sample_valid) begin
        acc_d  = acc_step;
        tune_d = tune_step;
    end
end

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        acc_q  <= '0;
        tune_q <= {NumTuneBits{1'b0}};
    end else begin
        acc_q  <= acc_d;
        tune_q <= tune_d;
    end
end

// The linear loop settles to a near-static code, so watch the output tune directly.
adpll_lock_detect #(
    .Width      (NumTuneBits),
    .LockWindows(LockWindows),
    .Band       (LockBand)
) u_lock (
    .clk_i,
    .rst_ni,
    .enable_i,
    .sample_valid_i(sample_valid),
    .code_i        (tune_q),
    .lock_o        (lock_o)
);

assign tune_o = tune_q;

endmodule

