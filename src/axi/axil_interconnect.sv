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

// axil_interconnect
//
// One AXI4-Lite master fanned out to two address-decoded slaves. The upstream master
// is single-outstanding, so routing is combinational: address bit SelBit picks the
// slave for AW/W and AR, and since only the selected slave ever returns a B/R the
// responses are a plain mux. Slave 0 is the low region (on-chip scratch RAM), slave 1
// the high region (SDRAM).

`default_nettype none

module axil_interconnect #(
    parameter int unsigned AddrWidth = 32,
    parameter int unsigned SelBit    = 28
) (
    /*
     * AXI-Lite slave interface (from the Ethernet master)
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
     * AXI-Lite master interface 0 (scratch RAM, low region)
     */
    output wire [AddrWidth-1:0] m0_axil_awaddr,
    output wire [2:0]           m0_axil_awprot,
    output wire                 m0_axil_awvalid,
    input  wire                 m0_axil_awready,
    output wire [31:0]          m0_axil_wdata,
    output wire [3:0]           m0_axil_wstrb,
    output wire                 m0_axil_wvalid,
    input  wire                 m0_axil_wready,
    input  wire [1:0]           m0_axil_bresp,
    input  wire                 m0_axil_bvalid,
    output wire                 m0_axil_bready,
    output wire [AddrWidth-1:0] m0_axil_araddr,
    output wire [2:0]           m0_axil_arprot,
    output wire                 m0_axil_arvalid,
    input  wire                 m0_axil_arready,
    input  wire [31:0]          m0_axil_rdata,
    input  wire [1:0]           m0_axil_rresp,
    input  wire                 m0_axil_rvalid,
    output wire                 m0_axil_rready,

    /*
     * AXI-Lite master interface 1 (SDRAM, high region)
     */
    output wire [AddrWidth-1:0] m1_axil_awaddr,
    output wire [2:0]           m1_axil_awprot,
    output wire                 m1_axil_awvalid,
    input  wire                 m1_axil_awready,
    output wire [31:0]          m1_axil_wdata,
    output wire [3:0]           m1_axil_wstrb,
    output wire                 m1_axil_wvalid,
    input  wire                 m1_axil_wready,
    input  wire [1:0]           m1_axil_bresp,
    input  wire                 m1_axil_bvalid,
    output wire                 m1_axil_bready,
    output wire [AddrWidth-1:0] m1_axil_araddr,
    output wire [2:0]           m1_axil_arprot,
    output wire                 m1_axil_arvalid,
    input  wire                 m1_axil_arready,
    input  wire [31:0]          m1_axil_rdata,
    input  wire [1:0]           m1_axil_rresp,
    input  wire                 m1_axil_rvalid,
    output wire                 m1_axil_rready
);

wire write_to_slave1 = s_axil_awaddr[SelBit];
wire read_from_slave1 = s_axil_araddr[SelBit];

assign m0_axil_awaddr  = s_axil_awaddr;
assign m0_axil_awprot  = s_axil_awprot;
assign m1_axil_awaddr  = s_axil_awaddr;
assign m1_axil_awprot  = s_axil_awprot;
assign m0_axil_awvalid = s_axil_awvalid && !write_to_slave1;
assign m1_axil_awvalid = s_axil_awvalid &&  write_to_slave1;

assign m0_axil_wdata   = s_axil_wdata;
assign m0_axil_wstrb   = s_axil_wstrb;
assign m1_axil_wdata   = s_axil_wdata;
assign m1_axil_wstrb   = s_axil_wstrb;
assign m0_axil_wvalid  = s_axil_wvalid && !write_to_slave1;
assign m1_axil_wvalid  = s_axil_wvalid &&  write_to_slave1;

assign s_axil_awready  = write_to_slave1 ? m1_axil_awready : m0_axil_awready;
assign s_axil_wready   = write_to_slave1 ? m1_axil_wready  : m0_axil_wready;

assign s_axil_bvalid   = m0_axil_bvalid || m1_axil_bvalid;
assign s_axil_bresp    = m1_axil_bvalid ? m1_axil_bresp : m0_axil_bresp;
assign m0_axil_bready  = s_axil_bready;
assign m1_axil_bready  = s_axil_bready;

assign m0_axil_araddr  = s_axil_araddr;
assign m0_axil_arprot  = s_axil_arprot;
assign m1_axil_araddr  = s_axil_araddr;
assign m1_axil_arprot  = s_axil_arprot;
assign m0_axil_arvalid = s_axil_arvalid && !read_from_slave1;
assign m1_axil_arvalid = s_axil_arvalid &&  read_from_slave1;
assign s_axil_arready  = read_from_slave1 ? m1_axil_arready : m0_axil_arready;

assign s_axil_rvalid   = m0_axil_rvalid || m1_axil_rvalid;
assign s_axil_rdata    = m1_axil_rvalid ? m1_axil_rdata : m0_axil_rdata;
assign s_axil_rresp    = m1_axil_rvalid ? m1_axil_rresp : m0_axil_rresp;
assign m0_axil_rready  = s_axil_rready;
assign m1_axil_rready  = s_axil_rready;

endmodule

`default_nettype wire
