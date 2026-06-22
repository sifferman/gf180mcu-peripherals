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

// m_axil_readwrite
//
// Single-outstanding AXI4-Lite master driven by two ready/valid channels: a request
// channel that presents one read or write command, and a read channel that returns a
// read command's data. A write completes when request_ready_o rises again; a read
// drives read_valid_o/read_rdata_o until accepted. Only idle accepts a new command.

`default_nettype none

module m_axil_readwrite #(
    parameter int unsigned AddrWidth = 32
) (
    input  wire                 clk_i,
    input  wire                 rst_ni,

    input  wire                 request_valid_i,
    output wire                 request_ready_o,
    input  wire                 request_write_not_read_i,
    input  wire [AddrWidth-1:0] request_addr_i,
    input  wire [31:0]          request_wdata_i,

    output wire                 read_valid_o,
    input  wire                 read_ready_i,
    output wire [31:0]          read_rdata_o,

    /*
     * AXI-Lite master interface
     */
    output wire [AddrWidth-1:0] m_axil_awaddr,
    output wire [2:0]           m_axil_awprot,
    output wire                 m_axil_awvalid,
    input  wire                 m_axil_awready,
    output wire [31:0]          m_axil_wdata,
    output wire [3:0]           m_axil_wstrb,
    output wire                 m_axil_wvalid,
    input  wire                 m_axil_wready,
    input  wire [1:0]           m_axil_bresp,
    input  wire                 m_axil_bvalid,
    output wire                 m_axil_bready,
    output wire [AddrWidth-1:0] m_axil_araddr,
    output wire [2:0]           m_axil_arprot,
    output wire                 m_axil_arvalid,
    input  wire                 m_axil_arready,
    input  wire [31:0]          m_axil_rdata,
    input  wire [1:0]           m_axil_rresp,
    input  wire                 m_axil_rvalid,
    output wire                 m_axil_rready
);

typedef enum logic [1:0] {
    IDLE,
    WRITE,
    READ,
    READ_RESP
} state_e;
state_e state_d, state_q;

logic [AddrWidth-1:0] awaddr_d,  awaddr_q;
logic                 awvalid_d, awvalid_q;
logic [31:0]          wdata_d,   wdata_q;
logic                 wvalid_d,  wvalid_q;
logic                 bready_d,  bready_q;
logic [AddrWidth-1:0] araddr_d,  araddr_q;
logic                 arvalid_d, arvalid_q;
logic                 rready_d,  rready_q;
logic [31:0]          rdata_d,   rdata_q;

always_comb begin
    state_d   = state_q;
    awaddr_d  = awaddr_q;
    awvalid_d = awvalid_q;
    wdata_d   = wdata_q;
    wvalid_d  = wvalid_q;
    bready_d  = bready_q;
    araddr_d  = araddr_q;
    arvalid_d = arvalid_q;
    rready_d  = rready_q;
    rdata_d   = rdata_q;

    unique case (state_q)
        IDLE: if (request_valid_i) begin
            if (request_write_not_read_i) begin
                awaddr_d = request_addr_i; awvalid_d = 1'b1;
                wdata_d  = request_wdata_i; wvalid_d = 1'b1;
                bready_d = 1'b1;
                state_d  = WRITE;
            end else begin
                araddr_d = request_addr_i; arvalid_d = 1'b1;
                rready_d = 1'b1;
                state_d  = READ;
            end
        end
        WRITE: begin
            if (awvalid_q && m_axil_awready) awvalid_d = 1'b0;
            if (wvalid_q  && m_axil_wready ) wvalid_d  = 1'b0;
            if (m_axil_bvalid) begin
                bready_d = 1'b0;
                state_d  = IDLE;
            end
        end
        READ: begin
            if (arvalid_q && m_axil_arready) arvalid_d = 1'b0;
            if (m_axil_rvalid) begin
                rdata_d  = m_axil_rdata;
                rready_d = 1'b0;
                state_d  = READ_RESP;
            end
        end
        READ_RESP: if (read_ready_i) state_d = IDLE;
        default: state_d = IDLE;
    endcase
end

always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
        state_q   <= IDLE;
        awvalid_q <= 1'b0;
        wvalid_q  <= 1'b0;
        bready_q  <= 1'b0;
        arvalid_q <= 1'b0;
        rready_q  <= 1'b0;
    end else begin
        state_q   <= state_d;
        awvalid_q <= awvalid_d;
        wvalid_q  <= wvalid_d;
        bready_q  <= bready_d;
        arvalid_q <= arvalid_d;
        rready_q  <= rready_d;
    end
end

always_ff @(posedge clk_i) begin
    awaddr_q <= awaddr_d;
    wdata_q  <= wdata_d;
    araddr_q <= araddr_d;
    rdata_q  <= rdata_d;
    `ifndef SYNTHESIS
    if (!rst_ni) begin
        awaddr_q <= 'x;
        wdata_q  <= 'x;
        araddr_q <= 'x;
        rdata_q  <= 'x;
    end
    `endif
end

assign request_ready_o = (state_q == IDLE);
assign read_valid_o    = (state_q == READ_RESP);
assign read_rdata_o    = rdata_q;

assign m_axil_awaddr  = awaddr_q;
assign m_axil_awvalid = awvalid_q;
assign m_axil_wdata   = wdata_q;
assign m_axil_wvalid  = wvalid_q;
assign m_axil_bready  = bready_q;
assign m_axil_araddr  = araddr_q;
assign m_axil_arvalid = arvalid_q;
assign m_axil_rready  = rready_q;
assign m_axil_wstrb   = 4'hf;
assign m_axil_awprot  = 3'b000;
assign m_axil_arprot  = 3'b000;

endmodule

`default_nettype wire
