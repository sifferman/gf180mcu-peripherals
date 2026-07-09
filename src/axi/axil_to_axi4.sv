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

// axil_to_axi4
//
// AXI4-Lite slave to AXI4 master adapter for the SDRAM path. Each AXI4-Lite access is
// a single 32-bit beat, so it maps to an AXI4 single-beat INCR burst (len=0, size
// implied, id=0, wlast=1); the id/last response fields are dropped. Combinational —
// the AXI4 side simply mirrors the AXI4-Lite side plus the constant burst fields.

`default_nettype none

module axil_to_axi4 #(
    parameter int unsigned AddrWidth = 32
) (
    /*
     * AXI-Lite slave interface (from the Ethernet bridge)
     */
    input  wire [AddrWidth-1:0] s_axil_awaddr,
    input  wire [2:0]           s_axil_awprot,
    input  wire                 s_axil_awvalid,
    output wire                 s_axil_awready,
    input  wire [31:0]          s_axil_wdata,
    input  wire [3:0]           s_axil_wstrb,
    input  wire                 s_axil_wvalid,
    output wire                 s_axil_wready,
    output wire [1:0]           s_axil_bresp,
    output wire                 s_axil_bvalid,
    input  wire                 s_axil_bready,
    input  wire [AddrWidth-1:0] s_axil_araddr,
    input  wire [2:0]           s_axil_arprot,
    input  wire                 s_axil_arvalid,
    output wire                 s_axil_arready,
    output wire [31:0]          s_axil_rdata,
    output wire [1:0]           s_axil_rresp,
    output wire                 s_axil_rvalid,
    input  wire                 s_axil_rready,

    /*
     * AXI4 master interface (to sdram_axi)
     */
    output wire [AddrWidth-1:0] m_axi_awaddr,
    output wire [3:0]           m_axi_awid,
    output wire [7:0]           m_axi_awlen,
    output wire [1:0]           m_axi_awburst,
    output wire                 m_axi_awvalid,
    input  wire                 m_axi_awready,
    output wire [31:0]          m_axi_wdata,
    output wire [3:0]           m_axi_wstrb,
    output wire                 m_axi_wlast,
    output wire                 m_axi_wvalid,
    input  wire                 m_axi_wready,
    input  wire [1:0]           m_axi_bresp,
    input  wire                 m_axi_bvalid,
    output wire                 m_axi_bready,
    output wire [AddrWidth-1:0] m_axi_araddr,
    output wire [3:0]           m_axi_arid,
    output wire [7:0]           m_axi_arlen,
    output wire [1:0]           m_axi_arburst,
    output wire                 m_axi_arvalid,
    input  wire                 m_axi_arready,
    input  wire [31:0]          m_axi_rdata,
    input  wire [1:0]           m_axi_rresp,
    input  wire                 m_axi_rvalid,
    output wire                 m_axi_rready
);

localparam logic [1:0] BurstIncr = 2'b01;

assign m_axi_awaddr   = s_axil_awaddr;
assign m_axi_awid     = 4'd0;
assign m_axi_awlen    = 8'd0;
assign m_axi_awburst  = BurstIncr;
assign m_axi_awvalid  = s_axil_awvalid;
assign s_axil_awready = m_axi_awready;

assign m_axi_wdata    = s_axil_wdata;
assign m_axi_wstrb    = s_axil_wstrb;
assign m_axi_wlast    = 1'b1;
assign m_axi_wvalid   = s_axil_wvalid;
assign s_axil_wready  = m_axi_wready;

assign s_axil_bresp   = m_axi_bresp;
assign s_axil_bvalid  = m_axi_bvalid;
assign m_axi_bready   = s_axil_bready;

assign m_axi_araddr   = s_axil_araddr;
assign m_axi_arid     = 4'd0;
assign m_axi_arlen    = 8'd0;
assign m_axi_arburst  = BurstIncr;
assign m_axi_arvalid  = s_axil_arvalid;
assign s_axil_arready = m_axi_arready;

assign s_axil_rdata   = m_axi_rdata;
assign s_axil_rresp   = m_axi_rresp;
assign s_axil_rvalid  = m_axi_rvalid;
assign m_axi_rready   = s_axil_rready;

logic _unused;
assign _unused = &{1'b0, s_axil_awprot, s_axil_arprot};

endmodule

`default_nettype wire
