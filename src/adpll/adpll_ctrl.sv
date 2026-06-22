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
// All-digital frequency-locked loop that tunes ring_dco to a programmable target. The
// architecture and every design choice below follow the all-digital PLL (ADPLL)
// literature; see "References" and the per-decision citations.
//
// Topology — frequency-to-digital front end -> digital loop filter -> DCO -> divider,
//   the canonical ADPLL pipeline. [Kratyuk2007 Fig.2: "P2D -> Digital LF -> DCO -> /N"];
//   [Hanumolu2007 Fig.4]. A second-order (type-II) loop is used because, unlike a
//   charge-pump PLL, an ADPLL needs no third pole to suppress reference ripple:
//   [Kratyuk2007 §IV] "In all-digital PLLs, this problem does not exist, and a
//   second-order PLL is sufficient."
//
// Detector — instead of a time-to-digital converter measuring *phase*, this block counts
//   DCO edges over a fixed reference window and compares the count to target_i, i.e. it
//   measures *frequency* error. This frequency-locked-loop (FLL) variant fits a standalone,
//   CSR-tuned, observe-only DCO (no recovered data / reference phase to track). The error
//   is then reduced to its sign, which is exactly the 1-bit detector of the ADPLL
//   literature: [Hanumolu2007 §IV-A] "A DFF simply detects the sign of the phase error and
//   hence serves as a 1-bit TDC." Sign-only operation also makes the loop robust to the
//   DCO's strongly nonlinear, code-dependent gain K_DCO (a coarse ring tunes very
//   nonlinearly: [Staszewski2006 §2.1] "Frequency tuning of a low-voltage deep-submicron
//   CMOS oscillator is quite a challenging task, due to its highly nonlinear frequency vs.
//   voltage characteristics").
//
// Loop filter — proportional + integral (PI), the standard digital loop filter:
//   [Kratyuk2007 §IV-C] "A digital equivalent of an analog loop filter consists of a
//   proportional path with a gain alpha and an integral path with a gain beta";
//   [Hanumolu2007 Fig.4 / Eq.2] proportional K_P and integral K_I paths. The integral path
//   (a running accumulator, IntegralGain LSB/window) sets the steady-state tune code and so
//   gives zero steady-state frequency error; the proportional path (ProportionalGain *
//   sign(error)) adds damping for a faster, better-behaved transient. Gains are integers
//   here because the error is 1-bit; the literature quantizes the gains to powers of two
//   for hardware ([Kratyuk2007 §V] "the coefficients of the digital loop filter have to be
//   approximated as power of two values: alpha ~= 2^-3, beta ~= 2^-7"), and these defaults
//   keep that spirit. Programmability of the gains is itself a stated ADPLL advantage:
//   [Hanumolu2007 §III] "since the DPLL's loop dynamics are set by DLF coefficients, loop
//   characteristics can be easily programmed and are also immune to process, voltage, and
//   temperature (PVT) variations."
//
// Lock — declared on the *integral* state (the clean operating point), not the dithering
//   output: a bang-bang loop necessarily limit-cycles by +-1 LSB at lock, so lock is
//   detected when the integral code stays within a +-1 band for LockWindows windows
//   ([DaDalt2004] analyses this bang-bang limit cycle). The residual +-1 LSB dither is the
//   loop's own time-dithering and gives sub-LSB *average* frequency resolution, the same
//   mechanism Staszewski uses deliberately: [Staszewski2006 §3.5] "Time Dithering of DCO
//   Tuning Input" / increasing "frequency resolution through Sigma-Delta dithering".
//
// CDC — the DCO is asynchronous to clk_i, so its edge count crosses domains as a Gray code
//   through a two-flop synchronizer (at most one bit changes per edge, so a metastable
//   sample is wrong by at most one count). The DCO-domain counter uses async reset because
//   its clock is gated by enable_i.
//
// References:
//   [Kratyuk2007]  V. Kratyuk, P. K. Hanumolu, U.-K. Moon, K. Mayaram, "A Design Procedure
//                  for All-Digital Phase-Locked Loops Based on a Charge-Pump PLL Analogy,"
//                  IEEE TCAS-II, vol. 54, no. 3, pp. 247-251, Mar. 2007.
//   [Hanumolu2007] P. K. Hanumolu, G.-Y. Wei, U.-K. Moon, K. Mayaram, "Digitally-Enhanced
//                  Phase-Locking Circuits," IEEE CICC, pp. 361-368, 2007.
//   [Staszewski2006] R. B. Staszewski, P. T. Balsara, "All-Digital Frequency Synthesizer in
//                  Deep-Submicron CMOS," Wiley, 2006.
//   [Razavi]       B. Razavi, "Design of CMOS Phase-Locked Loops," (type-II loop dynamics,
//                  damping/phase-margin background for the gain choice).
//   [DaDalt2004]   J. Lee, K. S. Kundert, B. Razavi, "Analysis and modeling of bang-bang
//                  clock and data recovery circuits," IEEE JSSC, vol. 39, no. 9, 2004
//                  (Kratyuk2007 ref [12]; bang-bang loop nonlinear dynamics / limit cycle).

`default_nettype none

module adpll_ctrl #(
    parameter int unsigned NumTuneBits      = 7,
    parameter int unsigned CountWidth       = 24,
    parameter int unsigned WindowCycles     = 4096,
    parameter int unsigned LockWindows      = 8,
    // PI loop-filter gains (LSB per window, applied to the 1-bit error). IntegralGain=1
    // sets the slowest stable integration; ProportionalGain adds damping. Both are small
    // integers, the bang-bang analogue of the power-of-two alpha/beta in [Kratyuk2007 §V].
    parameter int unsigned IntegralGain     = 1,
    parameter int unsigned ProportionalGain = 1
) (
    input  wire                   clk_i,
    input  wire                   rst_ni,
    input  wire                   enable_i,
    input  wire [CountWidth-1:0]  target_i,
    input  wire                   dco_clk_i,

    output wire [NumTuneBits-1:0] tune_o,
    output wire                   lock_o
);

function automatic logic [CountWidth-1:0] bin2gray(input logic [CountWidth-1:0] b);
    bin2gray = b ^ (b >> 1);
endfunction
function automatic logic [CountWidth-1:0] gray2bin(input logic [CountWidth-1:0] g);
    gray2bin = g;
    for (int k_GEN = 1; k_GEN < CountWidth; k_GEN++)
        gray2bin = gray2bin ^ (g >> k_GEN);
endfunction

// DCO domain: Gray-coded free-running edge counter (async reset; clock is gated).
logic [CountWidth-1:0] dco_cnt_bin_q;
logic [CountWidth-1:0] dco_cnt_gray_q;

always_ff @(posedge dco_clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        dco_cnt_bin_q  <= '0;
        dco_cnt_gray_q <= '0;
    end else begin
        dco_cnt_bin_q  <= dco_cnt_bin_q + 1'b1;
        dco_cnt_gray_q <= bin2gray(dco_cnt_bin_q + 1'b1);
    end
end

// Reference domain: synchronize the Gray count.
logic [CountWidth-1:0] gray_sync0_q, gray_sync1_q;
always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        gray_sync0_q <= '0;
        gray_sync1_q <= '0;
    end else begin
        gray_sync0_q <= dco_cnt_gray_q;
        gray_sync1_q <= gray_sync0_q;
    end
end
wire [CountWidth-1:0] dco_cnt_sync = gray2bin(gray_sync1_q);

localparam int unsigned WindowCounterWidth = (WindowCycles <= 1) ? 1 : $clog2(WindowCycles);
logic [WindowCounterWidth-1:0] window_cnt_q;
wire window_tick = (window_cnt_q == WindowCounterWidth'(WindowCycles - 1));

// Frequency-to-digital: edges this window, reduced to a 1-bit sign error.
wire [CountWidth-1:0] measured = dco_cnt_sync - cnt_at_window_q;
wire too_fast = measured > target_i;   // freq high  => add delay  => raise tune
wire too_slow = measured < target_i;   // freq low   => cut delay  => lower tune

localparam int unsigned TuneMax = (1 << NumTuneBits) - 1;

logic [CountWidth-1:0]            cnt_at_window_q;
logic [NumTuneBits-1:0]          integ_q;          // integral path: the operating-point code
logic [NumTuneBits-1:0]          tune_q;           // registered PI output (stable per window)
logic [NumTuneBits-1:0]          lock_centre_q;
logic [$clog2(LockWindows+1)-1:0] in_band_q;
logic                            lock_q;

function automatic logic [NumTuneBits-1:0] clamp(input int v);
    if (v < 0)                  clamp = '0;
    else if (v > int'(TuneMax)) clamp = NumTuneBits'(TuneMax);
    else                        clamp = NumTuneBits'(v);
endfunction

// PI loop filter, combinational next-state. dir is the 1-bit (sign) error; integ_d is the
// integral accumulator step (IntegralGain LSB/window) and tune_d adds the proportional term
// (ProportionalGain * sign) on top of the updated integral.
wire signed [1:0]      dir     = too_fast ? 2'sd1 : (too_slow ? -2'sd1 : 2'sd0);
wire [NumTuneBits-1:0] integ_d = clamp(int'(integ_q) + dir * int'(IntegralGain));
wire [NumTuneBits-1:0] tune_d  = clamp(int'(integ_d) + dir * int'(ProportionalGain));

// Lock when the integral operating point stays within +-1 of a running centre.
wire signed [NumTuneBits+1:0] band_err =
    $signed({2'b0, integ_d}) - $signed({2'b0, lock_centre_q});
wire in_band = (band_err >= -1) && (band_err <= 1);

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        window_cnt_q    <= '0;
        cnt_at_window_q <= '0;
        integ_q         <= {NumTuneBits{1'b0}};
        tune_q          <= {NumTuneBits{1'b0}};
        lock_centre_q   <= {NumTuneBits{1'b0}};
        in_band_q       <= '0;
        lock_q          <= 1'b0;
    end else if (!enable_i) begin
        window_cnt_q    <= '0;
        cnt_at_window_q <= dco_cnt_sync;
        in_band_q       <= '0;
        lock_q          <= 1'b0;
    end else begin
        if (window_tick) begin
            window_cnt_q    <= '0;
            cnt_at_window_q <= dco_cnt_sync;
            integ_q         <= integ_d;
            tune_q          <= tune_d;

            if (in_band) begin
                if (in_band_q == LockWindows[$bits(in_band_q)-1:0])
                    lock_q <= 1'b1;
                else
                    in_band_q <= in_band_q + 1'b1;
            end else begin
                lock_centre_q <= integ_d;
                in_band_q     <= '0;
                lock_q        <= 1'b0;
            end
        end else begin
            window_cnt_q <= window_cnt_q + 1'b1;
        end
    end
end

assign tune_o = tune_q;
assign lock_o = lock_q;

endmodule

`default_nettype wire
