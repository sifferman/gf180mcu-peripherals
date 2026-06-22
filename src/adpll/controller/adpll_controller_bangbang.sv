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

// adpll_controller_bangbang
//
// Ref: Hanumolu et al., IEEE CICC 2007, Sec. IV-A (1-bit/DFF-sign detector);
// Lee, Kundert & Razavi, IEEE JSSC 39(9), 2004 (bang-bang dynamics).
// Bang-bang FLL loop filter: each window it steps the DCO tune code by the sign of
// (measured - mul), driving F_DCO = (mul/div) * F_clk_i. Wraps adpll_freq_counter +
// adpll_lock_detect.
//
// Parameters:
//   - NumTuneBits       : DCO tune-code width
//   - MaxEdgesPerWindow : max edges/window (sets mul_i / measured width)
//   - MaxWindowSize     : max window length (sets div_i width)
//   - LockWindows       : in-band samples to declare lock
//   - IntegralGain, ProportionalGain : per-window LSB steps (sign-scaled)
// Ports:
//   - clk_i, rst_ni, enable_i
//   - mul_i     : target edges/window (multiply ratio N)
//   - div_i     : window length, in reference cycles (divider M)
//   - dco_clk_i : DCO clock feedback
//   - tune_o    : DCO tune code
//   - lock_o    : lock asserted

module adpll_controller_bangbang #(
    parameter int unsigned NumTuneBits      = 7,
    parameter  int unsigned MaxEdgesPerWindow = (1 << 24) - 1,
    localparam int unsigned EdgeCountWidth    = $clog2(MaxEdgesPerWindow + 1),
    parameter  int unsigned MaxWindowSize     = (1 << 16) - 1,
    localparam int unsigned WindowSizeWidth   = $clog2(MaxWindowSize + 1),
    parameter int unsigned LockWindows      = 8,
    parameter int unsigned IntegralGain     = 1,
    parameter int unsigned ProportionalGain = 1
) (
    input  wire                   clk_i,
    input  wire                   rst_ni,
    input  wire                   enable_i,
    input  wire [EdgeCountWidth-1:0]  mul_i,      // target DCO edges per window (multiply ratio N)
    input  wire [WindowSizeWidth-1:0]    div_i,      // measurement window length (reference divider M)
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

wire too_fast = measured > mul_i;   // freq high => add delay  => raise tune
wire too_slow = measured < mul_i;   // freq low  => cut delay  => lower tune

localparam int unsigned TuneMax = (1 << NumTuneBits) - 1;

logic [NumTuneBits-1:0] integ_q;    // integral path: the operating-point code
logic [NumTuneBits-1:0] tune_q;     // registered PI output (stable per window)

function automatic logic [NumTuneBits-1:0] clamp(input int v);
    if (v < 0)                  clamp = '0;
    else if (v > int'(TuneMax)) clamp = NumTuneBits'(TuneMax);
    else                        clamp = NumTuneBits'(v);
endfunction

// PI loop filter. dir is the 1-bit (sign) error; *_step is the next code on a sample.
wire signed [1:0]      dir         = too_fast ? 2'sd1 : (too_slow ? -2'sd1 : 2'sd0);
wire [NumTuneBits-1:0] integ_step  = clamp(int'(integ_q)    + dir * int'(IntegralGain));
wire [NumTuneBits-1:0] tune_step   = clamp(int'(integ_step) + dir * int'(ProportionalGain));

// Update only on a fresh measurement; the gating lives here in _d, not in the always_ff.
logic [NumTuneBits-1:0] integ_d, tune_d;
always_comb begin
    integ_d = integ_q;
    tune_d  = tune_q;
    if (enable_i && sample_valid) begin
        integ_d = integ_step;
        tune_d  = tune_step;
    end
end

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        integ_q <= {NumTuneBits{1'b0}};
        tune_q  <= {NumTuneBits{1'b0}};
    end else begin
        integ_q <= integ_d;
        tune_q  <= tune_d;
    end
end

// Lock on the integral operating point (the clean code, not the +-1 LSB limit cycle).
adpll_lock_detect #(
    .Width      (NumTuneBits),
    .LockWindows(LockWindows),
    .Band       (1)
) u_lock (
    .clk_i,
    .rst_ni,
    .enable_i,
    .sample_valid_i(sample_valid),
    .code_i        (integ_q),
    .lock_o        (lock_o)
);

assign tune_o = tune_q;

endmodule

