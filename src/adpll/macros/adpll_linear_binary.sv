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

// adpll_linear_binary
//
// Hardened-macro wrapper: one fixed ADPLL configuration = linear PI (multi-bit error, power-of-2 gains) controller + binary-weighted delay-select ring DCO.
// A hardened macro is a frozen physical block (no parameters), so each of the six
// controller x DCO combinations is its own wrapper / DESIGN_NAME; this is the
// linear x binary variant. Black-box interface for the chip: the host programs mul_i/div_i
// and enable_i (via the CSR) and reads lock_o/tune_o back; dco_clk_o is the raw DCO
// oscillation brought out for observation. Sources: controller [Kratyuk2007], DCO [Staszewski2006];
// see src/adpll/controller/ and src/adpll/dco/ for the full derivations.

`default_nettype none

module adpll_linear_binary #(
    parameter int unsigned NumTuneBits = 7,
    parameter int unsigned EdgeCountWidth  = 24,
    parameter int unsigned WindowCountWidth    = 16
) (
    input  wire                   clk_i,
    input  wire                   rst_ni,
    input  wire                   enable_i,
    input  wire [EdgeCountWidth-1:0]  mul_i,
    input  wire [WindowCountWidth-1:0]    div_i,

    output wire                   lock_o,
    output wire [NumTuneBits-1:0] tune_o,
    output wire                   dco_clk_o   // raw DCO oscillation, for observation
);

wire [NumTuneBits-1:0] tune;
wire                   dco_clk;

adpll_controller_linear #(
    .NumTuneBits(NumTuneBits),
    .EdgeCountWidth (EdgeCountWidth),
    .WindowCountWidth   (WindowCountWidth)
) u_ctrl (
    .clk_i    (clk_i),
    .rst_ni   (rst_ni),
    .enable_i (enable_i),
    .mul_i    (mul_i),
    .div_i    (div_i),
    .dco_clk_i(dco_clk),
    .tune_o   (tune),
    .lock_o   (lock_o)
);

ring_dco_binary #(
    .NumTuneBits(NumTuneBits)
) u_dco (
    .enable_i(enable_i),
    .tune_i  (tune),
    .clk_o   (dco_clk)
);

assign tune_o    = tune;
assign dco_clk_o = dco_clk;

endmodule

`default_nettype wire
