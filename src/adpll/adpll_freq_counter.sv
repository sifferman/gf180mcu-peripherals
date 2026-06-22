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
// Ref: Staszewski & Balsara, "All-Digital Frequency Synthesizer in Deep-Submicron CMOS"
// (Wiley, 2006), Ch. 3 (variable-phase / DCO-edge counter).
// Reference-gated frequency counter: counts DCO edges over a window of div_i reference
// cycles and emits one count per window, Gray-coded across the DCO -> clk_i crossing.
//
// Parameters:
//   - MaxEdgesPerWindow : max DCO edges counted per window (sets EdgeCountWidth)
//   - MaxWindowSize     : max window length, in reference cycles (sets WindowSizeWidth)
// Ports:
//   - clk_i, rst_ni, enable_i : reference clock, async-low reset, run
//   - div_i           : measurement window length, in reference cycles
//   - dco_clk_i       : DCO clock being measured
//   - measured_o      : DCO edge count over the last completed window
//   - sample_valid_o  : one-cycle strobe marking a fresh measured_o

module adpll_freq_counter #(
    parameter  int unsigned MaxEdgesPerWindow = (1 << 24) - 1,
    localparam int unsigned EdgeCountWidth    = $clog2(MaxEdgesPerWindow + 1),
    parameter  int unsigned MaxWindowSize     = (1 << 16) - 1,
    localparam int unsigned WindowSizeWidth   = $clog2(MaxWindowSize + 1)
) (
    input  wire                         clk_i,
    input  wire                         rst_ni,
    input  wire                         enable_i,
    input  wire [WindowSizeWidth-1:0]  div_i,        // measurement window length, in clk_i cycles
    input  wire                         dco_clk_i,

    output wire [EdgeCountWidth-1:0]    measured_o,   // DCO edges in the last completed window
    output wire                         sample_valid_o
);

function automatic logic [EdgeCountWidth-1:0] bin2gray(logic [EdgeCountWidth-1:0] b);
    bin2gray = b ^ (b >> 1);
endfunction
function automatic logic [EdgeCountWidth-1:0] gray2bin(logic [EdgeCountWidth-1:0] g);
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
logic [EdgeCountWidth-1:0] dco_cnt_sync;
always_comb dco_cnt_sync = gray2bin(gray_sync1_q);

// Programmable measurement window: a clk_i counter that rolls over every div_i cycles.
logic [WindowSizeWidth-1:0]   window_cnt_d,    window_cnt_q;
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

