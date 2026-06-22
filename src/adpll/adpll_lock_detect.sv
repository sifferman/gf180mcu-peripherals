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

// adpll_lock_detect
//
// Ref: Lee, Kundert & Razavi, IEEE JSSC 39(9), 2004 (bang-bang limit-cycle lock).
// Asserts lock_o once the sampled value stays within +/-BandRadius of the band_center (its
// held reference) for MinSamplesForLock consecutive samples.
//
// Parameters:
//   - SampleWidth : width of the sample
//   - MinSamplesForLock : consecutive in-band samples required to declare lock
//   - BandRadius  : +/- tolerance around band_center, in LSBs
// Ports:
//   - clk_i, rst_ni, enable_i
//   - sample_valid_i  : strobe qualifying tuning_sample_i
//   - tuning_sample_i : value sampled each window (its stability is what is detected)
//   - lock_o          : lock asserted

module adpll_lock_detect #(
    parameter int unsigned SampleWidth = 7,
    parameter int unsigned MinSamplesForLock = 8,
    parameter int unsigned BandRadius  = 1
) (
    input  wire                   clk_i,
    input  wire                   rst_ni,

    input  wire                   enable_i,
    input  wire                   sample_valid_i,
    input  wire [SampleWidth-1:0] tuning_sample_i,
    output wire                   lock_o
);

logic [SampleWidth-1:0]           band_center_d, band_center_q;
logic [$clog2(MinSamplesForLock+1)-1:0] in_band_d, in_band_q;
logic                             lock_d, lock_q;

wire signed [SampleWidth+1:0] band_error     = $signed({2'b0, tuning_sample_i}) - $signed({2'b0, band_center_q});
wire        [SampleWidth:0]   band_error_abs  = band_error[SampleWidth+1] ? -band_error : band_error;
wire                          in_band         = (band_error_abs <= BandRadius);

always_comb begin
    band_center_d  = band_center_q;
    in_band_d = in_band_q;
    lock_d    = lock_q;
    if (!enable_i) begin
        in_band_d = '0;
        lock_d    = 1'b0;
    end else if (sample_valid_i) begin
        if (in_band) begin
            if (in_band_q == MinSamplesForLock[$bits(in_band_q)-1:0])
                lock_d = 1'b1;
            else
                in_band_d = in_band_q + 1'b1;
        end else begin
            band_center_d  = tuning_sample_i;
            in_band_d = '0;
            lock_d    = 1'b0;
        end
    end
end

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        band_center_q  <= '0;
        in_band_q <= '0;
        lock_q    <= 1'b0;
    end else begin
        band_center_q  <= band_center_d;
        in_band_q <= in_band_d;
        lock_q    <= lock_d;
    end
end

assign lock_o = lock_q;

endmodule
