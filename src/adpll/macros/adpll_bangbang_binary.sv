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

// adpll_bangbang_binary
//
// Ref: Hanumolu CICC 2007 / Da Dalt JSSC 2004 (bangbang); Staszewski Wiley 2006 Ch.2-3 (binary). See the controller / DCO files for detail.
// Hardened-macro wrapper for one fixed ADPLL config = bangbang controller + binary DCO. A macro
// is a frozen block, so each controller x DCO combination is its own DESIGN_NAME; this is
// the bangbang x binary variant, presented to the chip as a black box.
//
// Parameters:
//   - NumTuneBits, MaxEdgesPerWindow, MaxWindowSize : passed through to the controller
// Ports:
//   - clk_i, rst_ni, enable_i : run + program
//   - mul_i, div_i  : synthesizer ratio N / M (set over the CSR)
//   - lock_o, tune_o : status
//   - dco_clk_o     : raw DCO clock, brought out for observation

module adpll_bangbang_binary #(
    parameter int unsigned NumTuneBits = 7,
    parameter  int unsigned MaxEdgesPerWindow = (1 << 24) - 1,
    localparam int unsigned EdgeCountWidth    = $clog2(MaxEdgesPerWindow + 1),
    parameter  int unsigned MaxWindowSize     = (1 << 16) - 1,
    localparam int unsigned WindowSizeWidth   = $clog2(MaxWindowSize + 1)
) (
    input  wire                   clk_i,
    input  wire                   rst_ni,
    input  wire                   enable_i,
    input  wire [EdgeCountWidth-1:0]  mul_i,
    input  wire [WindowSizeWidth-1:0]    div_i,

    output wire                   lock_o,
    output wire [NumTuneBits-1:0] tune_o,
    output wire                   dco_clk_o   // raw DCO oscillation, for observation
);

wire [NumTuneBits-1:0] tune;
wire                   dco_clk;

adpll_controller_bangbang #(
    .NumTuneBits(NumTuneBits),
    .MaxEdgesPerWindow(MaxEdgesPerWindow),
    .MaxWindowSize(MaxWindowSize)
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

