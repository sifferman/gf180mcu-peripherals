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
// Bang-bang frequency-locked loop for ring_dco. Over a window of WindowCycles reference
// cycles it counts DCO edges, compares to target_i, and nudges the tune code ±1 to drive
// the error to zero. Because the DCO is coarse (one tune LSB moves frequency by far more
// than a few edges/window), lock is declared on the tune code, not the edge count: once
// the code stays within a ±1 band of a running centre for LockWindows windows it has
// stopped converging and is only hunting the LSB, so lock_o asserts.
//
// The DCO is asynchronous to the reference clock, so its edge count is kept in a Gray-
// coded counter and sampled through a two-flop synchronizer (Gray => at most one bit
// changes per edge, so a metastable sample is off by at most one, which the loop filter
// tolerates). The DCO-domain counter uses async reset because its clock is gated.

`default_nettype none

module adpll_ctrl #(
    parameter int unsigned NumTuneBits  = 7,
    parameter int unsigned CountWidth   = 24,
    parameter int unsigned WindowCycles = 4096,
    parameter int unsigned LockWindows  = 8
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

logic [CountWidth-1:0]          cnt_at_window_q;
logic [NumTuneBits-1:0]         tune_q;
logic [NumTuneBits-1:0]         lock_centre_q;
logic [$clog2(LockWindows+1)-1:0] in_band_q;
logic                          lock_q;

wire [CountWidth-1:0] measured = dco_cnt_sync - cnt_at_window_q;
wire too_fast = measured > target_i;
wire too_slow = measured < target_i;

// More tune => more ring delay => lower frequency => fewer edges, so speed up by
// decrementing. Saturating ±1 bang-bang step.
logic [NumTuneBits-1:0] tune_d;
always_comb begin
    tune_d = tune_q;
    if (too_fast && (tune_q != {NumTuneBits{1'b1}}))
        tune_d = tune_q + 1'b1;
    else if (too_slow && (tune_q != {NumTuneBits{1'b0}}))
        tune_d = tune_q - 1'b1;
end

wire signed [NumTuneBits+1:0] band_err =
    $signed({2'b0, tune_d}) - $signed({2'b0, lock_centre_q});
wire in_band = (band_err >= -1) && (band_err <= 1);

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        window_cnt_q    <= '0;
        cnt_at_window_q <= '0;
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
            tune_q          <= tune_d;

            if (in_band) begin
                if (in_band_q == LockWindows[$bits(in_band_q)-1:0])
                    lock_q <= 1'b1;
                else
                    in_band_q <= in_band_q + 1'b1;
            end else begin
                lock_centre_q <= tune_d;
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
