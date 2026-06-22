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

// adpll_ctrl
//
// All-digital frequency-locked loop controller (bang-bang loop filter) that tunes a ring
// DCO so F_DCO = (mul_i / div_i) * F_clk_i, the programmable-ratio synthesizer of the ADPLL
// literature [Kratyuk2007 Fig.2: F_REF -> P2D -> LF -> DCO -> /N]. mul_i (the feedback
// multiply ratio N, = target DCO edges per window) and div_i (the reference divider M, =
// window length) are runtime inputs, so the ratio is set over Ethernet via a CSR.
//
// Pipeline (each block its own module for reuse):
//   adpll_freq_meas  -- counts DCO edges over a div_i-cycle window, Gray-CDC into clk_i,
//                       emits measured + sample strobe (the frequency-to-digital front end).
//   this module      -- the loop filter.
//   adpll_lock_detect-- declares lock when the operating point settles.
//
// Loop filter -- proportional + integral (PI), the standard digital loop filter
//   [Kratyuk2007 §IV-C] "A digital equivalent of an analog loop filter consists of a
//   proportional path with a gain alpha and an integral path with a gain beta";
//   [Hanumolu2007 Fig.4] Kp/Ki paths. Here the frequency error is reduced to its sign --
//   the 1-bit detector [Hanumolu2007 §IV-A] "A DFF simply detects the sign of the phase
//   error and hence serves as a 1-bit TDC" -- which makes the loop robust to the ring's
//   strongly nonlinear, code-dependent gain K_DCO (a coarse ring "is quite a challenging
//   task, due to its highly nonlinear frequency vs. voltage characteristics"
//   [Staszewski2006 §2.1]). The integral path (IntegralGain LSB/window) gives zero
//   steady-state frequency error; the proportional path (ProportionalGain * sign) adds
//   damping. Gains are small integers (the bang-bang analogue of the power-of-two alpha/beta
//   the literature quantizes to, [Kratyuk2007 §V] "alpha ~= 2^-3, beta ~= 2^-7"); their
//   programmability is itself the stated ADPLL advantage [Hanumolu2007 §III] "loop
//   characteristics can be easily programmed and are also immune to process, voltage, and
//   temperature (PVT) variations." A second-order (type-II) loop suffices [Kratyuk2007 §IV].
//
//   adpll_ctrl_linear is the survey sibling that uses the full multi-bit error (the complete
//   [Kratyuk2007] linear procedure) instead of its sign.
//
// References (full citations also in this file's git history / docs/adpll_survey.md):
//   [Kratyuk2007]  Kratyuk, Hanumolu, Moon, Mayaram, IEEE TCAS-II 54(3):247-251, 2007.
//   [Hanumolu2007] Hanumolu, Wei, Moon, Mayaram, IEEE CICC 2007, pp.361-368.
//   [Staszewski2006] Staszewski & Balsara, "All-Digital Freq. Synthesizer in DSM CMOS," Wiley 2006.
//   [Razavi]       Razavi, "Design of CMOS Phase-Locked Loops" (type-II loop dynamics).
//   [DaDalt2004]   Lee, Kundert, Razavi, IEEE JSSC 39(9), 2004 (bang-bang loop dynamics).

`default_nettype none

module adpll_ctrl #(
    parameter int unsigned NumTuneBits      = 7,
    parameter int unsigned CountWidth       = 24,
    parameter int unsigned DivWidth         = 16,
    parameter int unsigned LockWindows      = 8,
    parameter int unsigned IntegralGain     = 1,
    parameter int unsigned ProportionalGain = 1
) (
    input  wire                   clk_i,
    input  wire                   rst_ni,
    input  wire                   enable_i,
    input  wire [CountWidth-1:0]  mul_i,      // target DCO edges per window (multiply ratio N)
    input  wire [DivWidth-1:0]    div_i,      // measurement window length (reference divider M)
    input  wire                   dco_clk_i,

    output wire [NumTuneBits-1:0] tune_o,
    output wire                   lock_o
);

wire [CountWidth-1:0] measured;
wire                  sample_valid;

adpll_freq_meas #(.CountWidth(CountWidth), .DivWidth(DivWidth)) u_meas (
    .clk_i, .rst_ni, .enable_i, .div_i, .dco_clk_i,
    .measured_o(measured), .sample_valid_o(sample_valid)
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

// PI loop filter, combinational next-state. dir is the 1-bit (sign) error.
wire signed [1:0]      dir     = too_fast ? 2'sd1 : (too_slow ? -2'sd1 : 2'sd0);
wire [NumTuneBits-1:0] integ_d = clamp(int'(integ_q) + dir * int'(IntegralGain));
wire [NumTuneBits-1:0] tune_d  = clamp(int'(integ_d) + dir * int'(ProportionalGain));

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        integ_q <= {NumTuneBits{1'b0}};
        tune_q  <= {NumTuneBits{1'b0}};
    end else if (enable_i && sample_valid) begin
        integ_q <= integ_d;
        tune_q  <= tune_d;
    end
end

// Lock on the integral operating point (the clean code, not the +-1 LSB limit cycle).
adpll_lock_detect #(.Width(NumTuneBits), .LockWindows(LockWindows), .Band(1)) u_lock (
    .clk_i, .rst_ni, .enable_i,
    .sample_valid_i(sample_valid),
    .code_i(integ_q),
    .lock_o(lock_o)
);

assign tune_o = tune_q;

endmodule

`default_nettype wire
