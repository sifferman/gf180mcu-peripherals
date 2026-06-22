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
// Asserts lock_o once the watched code stays within +/-Band of a running centre for
// LockWindows consecutive samples.
//
// Parameters:
//   - Width       : width of the watched code
//   - LockWindows : in-band samples required to declare lock
//   - Band        : +/- tolerance, in code LSBs
// Ports:
//   - clk_i, rst_ni, enable_i
//   - sample_valid_i : strobe qualifying code_i
//   - code_i         : control code being watched
//   - lock_o         : lock asserted

module adpll_lock_detect #(
    parameter int unsigned Width       = 7,
    parameter int unsigned LockWindows = 8,
    parameter int unsigned Band        = 1
) (
    input  wire             clk_i,
    input  wire             rst_ni,
    input  wire             enable_i,
    input  wire             sample_valid_i,
    input  wire [Width-1:0] code_i,
    output wire             lock_o
);

logic [Width-1:0]                 centre_d,  centre_q;
logic [$clog2(LockWindows+1)-1:0] in_band_d, in_band_q;
logic                             lock_d,    lock_q;

localparam logic signed [Width+1:0] BandSigned = (Width+2)'(Band);
wire signed [Width+1:0] band_err = $signed({2'b0, code_i}) - $signed({2'b0, centre_q});
wire in_band = (band_err >= -BandSigned) && (band_err <= BandSigned);

always_comb begin
    centre_d  = centre_q;
    in_band_d = in_band_q;
    lock_d    = lock_q;
    if (!enable_i) begin
        in_band_d = '0;
        lock_d    = 1'b0;
    end else if (sample_valid_i) begin
        if (in_band) begin
            if (in_band_q == LockWindows[$bits(in_band_q)-1:0])
                lock_d = 1'b1;
            else
                in_band_d = in_band_q + 1'b1;
        end else begin
            centre_d  = code_i;
            in_band_d = '0;
            lock_d    = 1'b0;
        end
    end
end

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        centre_q  <= '0;
        in_band_q <= '0;
        lock_q    <= 1'b0;
    end else begin
        centre_q  <= centre_d;
        in_band_q <= in_band_d;
        lock_q    <= lock_d;
    end
end

assign lock_o = lock_q;

endmodule

