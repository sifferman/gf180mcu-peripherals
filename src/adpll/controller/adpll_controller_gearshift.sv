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

// adpll_controller_gearshift
//
// Ref: Da Dalt, "A design-oriented study of the nonlinear dynamics of digital bang-bang PLLs"
// (IEEE TCAS-I 52(1), 2005, Sec. V, gear shifting); Staszewski & Balsara (Wiley, 2006).
// Bang-bang FLL with an adaptive step. It steps the tune code by +/-(1 << gear) on the sign of
// (dco_edge_count - mul); each time the error sign reverses (an overshoot) it downshifts a gear,
// halving the step. So acquisition is a coarse binary search (fast slew) that automatically
// refines to a +/-1 LSB limit cycle (low jitter) -- no manual Kp/Ki tuning. Wraps
// adpll_freq_counter + adpll_lock_detect.
//
// Parameters:
//   - NumTuneBits       : DCO tune-code width
//   - MaxEdgesPerWindow : max edges/window (sets mul_i / dco_edge_count width)
//   - MaxWindowSize     : max window length (sets div_i width)
//   - MinSamplesForLock : consecutive in-band samples to declare lock
//   - MaxGear           : starting gear; initial step is 1 << MaxGear
// Ports:
//   - clk_i, rst_ni, enable_i
//   - mul_i     : target edges/window (multiply ratio N)
//   - div_i     : window length, in reference cycles (divider M)
//   - dco_clk_i : DCO clock feedback
//   - tune_o    : DCO tune code
//   - lock_o    : lock asserted

module adpll_controller_gearshift #(
    parameter  int unsigned NumTuneBits       = 7,
    parameter  int unsigned MaxEdgesPerWindow = (1 << 24) - 1,
    localparam int unsigned EdgeCountWidth    = $clog2(MaxEdgesPerWindow + 1),
    parameter  int unsigned MaxWindowSize     = (1 << 16) - 1,
    localparam int unsigned WindowSizeWidth   = $clog2(MaxWindowSize + 1),
    parameter  int unsigned MinSamplesForLock = 8,
    parameter  int unsigned MaxGear           = (NumTuneBits >= 3) ? NumTuneBits - 2 : 0,
    localparam int unsigned GearWidth         = $clog2(MaxGear + 1)
) (
    input  wire                       clk_i,
    input  wire                       rst_ni,

    input  wire                       enable_i,
    input  wire [EdgeCountWidth-1:0]  mul_i,      // target DCO edges per window (multiply ratio N)
    input  wire [WindowSizeWidth-1:0] div_i,      // measurement window length (reference divider M)
    input  wire                       dco_clk_i,

    output wire [NumTuneBits-1:0] tune_o,
    output wire                   lock_o
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

wire too_fast = dco_edge_count > mul_i;   // freq high => add delay => raise tune
wire too_slow = dco_edge_count < mul_i;   // freq low  => cut delay => lower tune

localparam int unsigned TuneMax = (1 << NumTuneBits) - 1;

logic [NumTuneBits-1:0] tune_d, tune_q;             // gear-shifted accumulator = the tune code
logic [GearWidth-1:0]   gear_d, gear_q;             // current gear; step = 1 << gear
logic signed [1:0]      previous_sign_d, previous_sign_q;   // last nonzero error sign (for reversal detect)

// Standard 3-argument clamp: min(max(lo, value), hi).
function automatic int clamp(int lo, int value, int hi);
    clamp = (value < lo) ? lo : (value > hi) ? hi : value;
endfunction

// Gear-shift loop; update only on a fresh measurement (gating lives in _d, not the always_ff).
always_comb begin
    logic signed [1:0]      error_sign;
    logic [NumTuneBits-1:0] step;
    case ({too_fast, too_slow})
        2'b10:   error_sign = 1;
        2'b01:   error_sign = -1;
        default: error_sign = 0;
    endcase
    step = NumTuneBits'(1 << gear_q);

    tune_d          = tune_q;
    gear_d          = gear_q;
    previous_sign_d = previous_sign_q;
    if (enable_i && sample_valid && error_sign != 0) begin
        // An error-sign reversal means the last step overshot: downshift to halve the step.
        if (previous_sign_q != 0 && error_sign != previous_sign_q && gear_q != 0)
            gear_d = gear_q - 1'b1;
        previous_sign_d = error_sign;
        tune_d          = NumTuneBits'(clamp(0, int'(tune_q) + int'(error_sign) * int'(step), int'(TuneMax)));
    end
end

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        tune_q          <= '0;
        gear_q          <= GearWidth'(MaxGear);
        previous_sign_q <= '0;
    end else begin
        tune_q          <= tune_d;
        gear_q          <= gear_d;
        previous_sign_q <= previous_sign_d;
    end
end

// Once the gear reaches 0 the code dithers +-1 LSB about the target, so watch tune directly.
adpll_lock_detect #(
    .SampleWidth(NumTuneBits),
    .MinSamplesForLock(MinSamplesForLock),
    .BandRadius (1)
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
