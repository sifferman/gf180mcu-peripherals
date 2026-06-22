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

// adpll_freq_counter
//
// Shared front end for the ADPLL controllers: measures the DCO frequency by counting DCO
// edges over a window of div_i reference (clk_i) cycles, and emits one measured-count
// sample per window. With the controller driving the DCO to make measured == mul, the
// loop synthesizes F_DCO = (mul/div) * F_clk_i -- i.e. div_i is the reference divider M and
// the target count mul is the feedback-multiply ratio N of the classic synthesizer
// [Kratyuk2007 Fig.2: F_REF -> P2D -> LF -> DCO -> /N]. Both mul and div are runtime inputs
// so the ratio is programmable (set over Ethernet via a CSR).
//
// The DCO is asynchronous to clk_i, so the free-running edge count crosses domains as a
// Gray code through a two-flop synchronizer: only one bit changes per edge, so a metastable
// sample is wrong by at most one count, which the loop filter tolerates. The DCO-domain
// counter uses async reset because its clock (dco_clk_i) is gated by enable_i.
//
// sample_valid_o is a one-cycle strobe in the clk_i domain marking a fresh measured_o; the
// loop filter is always ready, so a valid strobe (not full ready/valid) is the interface.

`default_nettype none

module adpll_freq_counter #(
    parameter int unsigned EdgeCountWidth   = 24,
    parameter int unsigned WindowCountWidth = 16
) (
    input  wire                         clk_i,
    input  wire                         rst_ni,
    input  wire                         enable_i,
    input  wire [WindowCountWidth-1:0]  div_i,        // measurement window length, in clk_i cycles
    input  wire                         dco_clk_i,

    output wire [EdgeCountWidth-1:0]    measured_o,   // DCO edges in the last completed window
    output wire                         sample_valid_o
);

function automatic logic [EdgeCountWidth-1:0] bin2gray(input logic [EdgeCountWidth-1:0] b);
    bin2gray = b ^ (b >> 1);
endfunction
function automatic logic [EdgeCountWidth-1:0] gray2bin(input logic [EdgeCountWidth-1:0] g);
    gray2bin = g;
    for (int k_GEN = 1; k_GEN < EdgeCountWidth; k_GEN++)
        gray2bin = gray2bin ^ (g >> k_GEN);
endfunction

// DCO domain: Gray-coded free-running edge counter (async reset; clock is gated).
logic [EdgeCountWidth-1:0] dco_cnt_bin_d,  dco_cnt_bin_q;
logic [EdgeCountWidth-1:0] dco_cnt_gray_d, dco_cnt_gray_q;
always_comb dco_cnt_bin_d  = dco_cnt_bin_q + 1'b1;
always_comb dco_cnt_gray_d = bin2gray(dco_cnt_bin_d);
always_ff @(posedge dco_clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        dco_cnt_bin_q  <= '0;
        dco_cnt_gray_q <= '0;
    end else begin
        dco_cnt_bin_q  <= dco_cnt_bin_d;
        dco_cnt_gray_q <= dco_cnt_gray_d;
    end
end

// Reference domain: two-flop Gray synchronizer.
logic [EdgeCountWidth-1:0] gray_sync0_d, gray_sync0_q;
logic [EdgeCountWidth-1:0] gray_sync1_d, gray_sync1_q;
always_comb begin
    gray_sync0_d = dco_cnt_gray_q;
    gray_sync1_d = gray_sync0_q;
end
always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        gray_sync0_q <= '0;
        gray_sync1_q <= '0;
    end else begin
        gray_sync0_q <= gray_sync0_d;
        gray_sync1_q <= gray_sync1_d;
    end
end
wire [EdgeCountWidth-1:0] dco_cnt_sync = gray2bin(gray_sync1_q);

// Programmable measurement window: a clk_i counter that rolls over every div_i cycles.
logic [WindowCountWidth-1:0]   window_cnt_d,    window_cnt_q;
logic [EdgeCountWidth-1:0] cnt_at_window_d, cnt_at_window_q;  // edge-count snapshot at window edge
logic [EdgeCountWidth-1:0] measured_d,      measured_q;
logic                  sample_valid_d,  sample_valid_q;

wire window_tick = (window_cnt_q >= div_i - 1'b1);

always_comb begin
    window_cnt_d    = window_cnt_q + 1'b1;
    cnt_at_window_d = cnt_at_window_q;
    measured_d      = measured_q;
    sample_valid_d  = 1'b0;
    if (!enable_i) begin
        window_cnt_d    = '0;
        cnt_at_window_d = dco_cnt_sync;
    end else if (window_tick) begin
        window_cnt_d    = '0;
        cnt_at_window_d = dco_cnt_sync;
        measured_d      = dco_cnt_sync - cnt_at_window_q;
        sample_valid_d  = 1'b1;
    end
end

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        window_cnt_q    <= '0;
        cnt_at_window_q <= '0;
        measured_q      <= '0;
        sample_valid_q  <= 1'b0;
    end else begin
        window_cnt_q    <= window_cnt_d;
        cnt_at_window_q <= cnt_at_window_d;
        measured_q      <= measured_d;
        sample_valid_q  <= sample_valid_d;
    end
end

assign measured_o     = measured_q;
assign sample_valid_o = sample_valid_q;

endmodule

`default_nettype wire
