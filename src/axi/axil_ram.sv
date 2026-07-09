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

// axil_ram
//
// Flip-flop-backed AXI4-Lite slave RAM: the on-chip target for the Ethernet
// UDP->memory gold path, provable without any memory-macro placement. Single
// outstanding transaction, matching m_axil_readwrite (its only master).

`default_nettype none

module axil_ram #(
    parameter int unsigned AddrWidth = 32,
    parameter int unsigned Words     = 256
) (
    input  wire                  clk_i,
    input  wire                  rst_ni,

    /*
     * AXI-Lite slave interface
     */
    input  wire [AddrWidth-1:0]  s_axil_awaddr,
    input  wire [2:0]            s_axil_awprot,
    input  wire                  s_axil_awvalid,
    output wire                  s_axil_awready,
    input  wire [31:0]           s_axil_wdata,
    input  wire [3:0]            s_axil_wstrb,
    input  wire                  s_axil_wvalid,
    output wire                  s_axil_wready,
    output wire [1:0]            s_axil_bresp,
    output wire                  s_axil_bvalid,
    input  wire                  s_axil_bready,
    input  wire [AddrWidth-1:0]  s_axil_araddr,
    input  wire [2:0]            s_axil_arprot,
    input  wire                  s_axil_arvalid,
    output wire                  s_axil_arready,
    output wire [31:0]           s_axil_rdata,
    output wire [1:0]            s_axil_rresp,
    output wire                  s_axil_rvalid,
    input  wire                  s_axil_rready
);

localparam int unsigned AddrLsb    = 2;
localparam int unsigned IndexWidth = $clog2(Words);

logic [31:0] mem_q [Words];

logic _unused;
assign _unused = &{1'b0, s_axil_awprot, s_axil_arprot,
                   s_axil_awaddr[AddrWidth-1:AddrLsb+IndexWidth],
                   s_axil_araddr[AddrWidth-1:AddrLsb+IndexWidth]};

logic                 bvalid_d, bvalid_q;
wire                  write_accept = s_axil_awvalid && s_axil_wvalid && (!bvalid_q || s_axil_bready);
wire [IndexWidth-1:0] write_index  = s_axil_awaddr[AddrLsb +: IndexWidth];

always_comb begin
    bvalid_d = bvalid_q;
    if (write_accept)       bvalid_d = 1'b1;
    else if (s_axil_bready) bvalid_d = 1'b0;
end

always_ff @(posedge clk_i) begin
    if (!rst_ni) bvalid_q <= 1'b0;
    else         bvalid_q <= bvalid_d;
end

always_ff @(posedge clk_i) begin
    if (write_accept) begin
        for (int unsigned byte_GEN = 0; byte_GEN < 4; byte_GEN++)
            if (s_axil_wstrb[byte_GEN]) mem_q[write_index][byte_GEN*8 +: 8] <= s_axil_wdata[byte_GEN*8 +: 8];
    end
end

assign s_axil_awready = write_accept;
assign s_axil_wready  = write_accept;
assign s_axil_bvalid  = bvalid_q;
assign s_axil_bresp   = 2'b00;

logic                 rvalid_d, rvalid_q;
logic [31:0]          rdata_d, rdata_q;
wire                  read_accept = s_axil_arvalid && (!rvalid_q || s_axil_rready);
wire [IndexWidth-1:0] read_index  = s_axil_araddr[AddrLsb +: IndexWidth];

always_comb begin
    rvalid_d = rvalid_q;
    if (read_accept)        rvalid_d = 1'b1;
    else if (s_axil_rready) rvalid_d = 1'b0;
end

always_comb begin
    rdata_d = rdata_q;
    if (read_accept) rdata_d = mem_q[read_index];
end

always_ff @(posedge clk_i) begin
    if (!rst_ni) rvalid_q <= 1'b0;
    else         rvalid_q <= rvalid_d;
end

always_ff @(posedge clk_i) begin
    rdata_q <= rdata_d;
    `ifndef SYNTHESIS
    if (!rst_ni) rdata_q <= 'x;
    `endif
end

assign s_axil_arready = read_accept;
assign s_axil_rdata   = rdata_q;
assign s_axil_rvalid  = rvalid_q;
assign s_axil_rresp   = 2'b00;

endmodule

`default_nettype wire
