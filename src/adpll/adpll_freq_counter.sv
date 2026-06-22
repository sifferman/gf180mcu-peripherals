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
// The ADPLL's frequency sensor. The loop must drive F_DCO = (mul/div) * F_clk_i but cannot read
// an analog frequency directly, so it counts DCO rising edges over a window of window_length_i
// reference cycles: that count IS (F_DCO/F_clk_i) * window_length_i, the digital frequency the
// controller compares against its target. Instantiated once inside each adpll_controller_*. The
// DCO-edge count crosses into clk_i Gray-coded through a two-flop synchronizer.
//
// Parameters:
//   - MaxEdgesPerWindow : max DCO edges counted per window (sets EdgeCountWidth)
//   - MaxWindowSize     : max window length, in reference cycles (sets WindowSizeWidth)
// Ports:
//   - clk_i, rst_ni, enable_i : reference clock, async-low reset, run
//   - window_length_i  : measurement window length, in clk_i cycles
//   - dco_clk_i        : DCO clock being measured
//   - dco_edge_count_o : DCO rising edges counted in the last completed window
//   - sample_valid_o   : one-cycle strobe marking a fresh dco_edge_count_o

module adpll_freq_counter #(
    parameter  int unsigned MaxEdgesPerWindow = (1 << 24) - 1,
    localparam int unsigned EdgeCountWidth    = $clog2(MaxEdgesPerWindow + 1),
    parameter  int unsigned MaxWindowSize     = (1 << 16) - 1,
    localparam int unsigned WindowSizeWidth   = $clog2(MaxWindowSize + 1)
) (
    input  wire                       clk_i,
    input  wire                       rst_ni,

    input  wire                       enable_i,
    input  wire [WindowSizeWidth-1:0] window_length_i,   // measurement window length, in clk_i cycles
    input  wire                       dco_clk_i,

    output wire [EdgeCountWidth-1:0]  dco_edge_count_o,  // DCO edges in the last completed window
    output wire                       sample_valid_o
);

// ================================================================ //
//  Generate freerunning_dco_edge_count_sync in the 'clk_i' domain  //
// ================================================================ //

function automatic logic [EdgeCountWidth-1:0] bin2gray(logic [EdgeCountWidth-1:0] b);
    bin2gray = b ^ (b >> 1);
endfunction
function automatic logic [EdgeCountWidth-1:0] gray2bin(logic [EdgeCountWidth-1:0] g);
    gray2bin = g;
    for (int i = 1; i < EdgeCountWidth; i++)
        gray2bin = gray2bin ^ (g >> i);
endfunction

// DCO domain: free-running edge counter, with a Gray-coded copy for the clock crossing
// (one bit changes per edge, so it survives the two-flop synchronizer below).
logic [EdgeCountWidth-1:0] freerunning_dco_edge_count_binary_d, freerunning_dco_edge_count_binary_q;
logic [EdgeCountWidth-1:0] freerunning_dco_edge_count_gray_d,   freerunning_dco_edge_count_gray_q;
always_comb freerunning_dco_edge_count_binary_d = freerunning_dco_edge_count_binary_q + 1'b1;
always_comb freerunning_dco_edge_count_gray_d   = bin2gray(freerunning_dco_edge_count_binary_d);
always_ff @(posedge dco_clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        freerunning_dco_edge_count_binary_q <= '0;
        freerunning_dco_edge_count_gray_q   <= '0;
    end else begin
        freerunning_dco_edge_count_binary_q <= freerunning_dco_edge_count_binary_d;
        freerunning_dco_edge_count_gray_q   <= freerunning_dco_edge_count_gray_d;
    end
end

// Reference domain: two-flop Gray synchronizer; _q1 may be metastable, _q2 is settled.
logic [EdgeCountWidth-1:0] freerunning_dco_edge_count_gray_sync_q1, freerunning_dco_edge_count_gray_sync_q2;
always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        freerunning_dco_edge_count_gray_sync_q1 <= '0;
        freerunning_dco_edge_count_gray_sync_q2 <= '0;
    end else begin
        freerunning_dco_edge_count_gray_sync_q1 <= freerunning_dco_edge_count_gray_q;         // CDC capture from the DCO domain
        freerunning_dco_edge_count_gray_sync_q2 <= freerunning_dco_edge_count_gray_sync_q1;   // settle
    end
end
logic [EdgeCountWidth-1:0] freerunning_dco_edge_count_sync;
always_comb freerunning_dco_edge_count_sync = gray2bin(freerunning_dco_edge_count_gray_sync_q2);


// ================================================== //
//  Generate count_at_window_start in 'clk_i' domain, //
//  and calculate dco_edge_count                      //
// ================================================== //

// Programmable measurement window: a clk_i cycle counter that rolls over every window_length_i cycles.
logic [WindowSizeWidth-1:0] window_cycle_count_d,    window_cycle_count_q;
logic [EdgeCountWidth-1:0]  count_at_window_start_d, count_at_window_start_q; // freerunning count at the last window boundary
logic [EdgeCountWidth-1:0]  dco_edge_count_d,        dco_edge_count_q;
logic                       sample_valid_d,          sample_valid_q;

wire window_tick = (window_cycle_count_q >= window_length_i - 1'b1);

always_comb begin
    window_cycle_count_d    = window_cycle_count_q + 1'b1;
    count_at_window_start_d = count_at_window_start_q;
    dco_edge_count_d        = dco_edge_count_q;
    sample_valid_d          = 1'b0;
    if (!enable_i) begin
        window_cycle_count_d    = '0;
        count_at_window_start_d = freerunning_dco_edge_count_sync;   // prime the start point so the first window after enable measures correctly
    end else if (window_tick) begin
        window_cycle_count_d    = '0;
        dco_edge_count_d        = freerunning_dco_edge_count_sync - count_at_window_start_q;
        count_at_window_start_d = freerunning_dco_edge_count_sync; // start point for the next window
        sample_valid_d          = 1'b1;
    end
end

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        window_cycle_count_q    <= '0;
        count_at_window_start_q <= '0;
        dco_edge_count_q        <= '0;
        sample_valid_q          <= 1'b0;
    end else begin
        window_cycle_count_q    <= window_cycle_count_d;
        count_at_window_start_q <= count_at_window_start_d;
        dco_edge_count_q        <= dco_edge_count_d;
        sample_valid_q          <= sample_valid_d;
    end
end

assign dco_edge_count_o = dco_edge_count_q;
assign sample_valid_o   = sample_valid_q;

endmodule
