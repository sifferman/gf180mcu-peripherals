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

// adpll_csr
//
// AXI4-Lite control/status register block for the on-chip ADPLL. A host sets the
// synthesizer ratio (F_DCO = (mul/div)*F_clk_i) and enables the loop over Ethernet,
// and reads back lock + the live tune code. Single outstanding transaction, same
// handshake as axil_ram (its sibling on the fabric).
//
// Register map (word-addressed, byte offsets):
//   0x0 CTRL    [0]      enable          (R/W)
//   0x4 MUL     [EdgeCountWidth-1:0] mul (N)  (R/W)
//   0x8 DIV     [WindowSizeWidth-1:0]   div (M)  (R/W)
//   0xC STATUS  [0] lock, [NumTuneBits:1] tune   (RO)

`default_nettype none

module adpll_csr #(
    parameter int unsigned AddrWidth   = 32,
    parameter int unsigned NumTuneBits = 7,
    parameter  int unsigned MaxEdgesPerWindow = (1 << 24) - 1,
    localparam int unsigned EdgeCountWidth    = $clog2(MaxEdgesPerWindow + 1),
    parameter  int unsigned MaxWindowSize     = (1 << 16) - 1,
    localparam int unsigned WindowSizeWidth   = $clog2(MaxWindowSize + 1)
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
    input  wire                  s_axil_rready,

    /*
     * ADPLL control / status
     */
    output wire                   enable_o,
    output wire [EdgeCountWidth-1:0]  mul_o,
    output wire [WindowSizeWidth-1:0]    div_o,
    input  wire                   lock_i,
    input  wire [NumTuneBits-1:0] tune_i
);

localparam int unsigned AddrLsb = 2;   // 32-bit registers

logic                  ctrl_q;          // CTRL[0] = enable
logic [EdgeCountWidth-1:0] mul_q;
logic [WindowSizeWidth-1:0]   div_q;

logic _unused;
assign _unused = &{1'b0, s_axil_awprot, s_axil_arprot,
                   s_axil_awaddr[AddrWidth-1:AddrLsb+2], s_axil_awaddr[AddrLsb-1:0],
                   s_axil_araddr[AddrWidth-1:AddrLsb+2], s_axil_araddr[AddrLsb-1:0],
                   s_axil_wdata[31:EdgeCountWidth], s_axil_wdata[31:WindowSizeWidth]};

// ---- write channel ----
logic       bvalid_d, bvalid_q;
wire        write_accept = s_axil_awvalid && s_axil_wvalid && (!bvalid_q || s_axil_bready);
wire [1:0]  write_index  = s_axil_awaddr[AddrLsb +: 2];

always_comb begin
    bvalid_d = bvalid_q;
    if (write_accept)       bvalid_d = 1'b1;
    else if (s_axil_bready) bvalid_d = 1'b0;
end

logic                  ctrl_d;
logic [EdgeCountWidth-1:0] mul_d;
logic [WindowSizeWidth-1:0]   div_d;
always_comb begin
    ctrl_d = ctrl_q;
    mul_d  = mul_q;
    div_d  = div_q;
    if (write_accept && s_axil_wstrb[0]) begin
        case (write_index)
            2'd0: ctrl_d = s_axil_wdata[0];
            2'd1: mul_d  = s_axil_wdata[EdgeCountWidth-1:0];
            2'd2: div_d  = s_axil_wdata[WindowSizeWidth-1:0];
            default: ;   // STATUS is read-only
        endcase
    end
end

always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
        bvalid_q <= 1'b0;
        ctrl_q   <= 1'b0;
        mul_q    <= '0;
        div_q    <= '0;
    end else begin
        bvalid_q <= bvalid_d;
        ctrl_q   <= ctrl_d;
        mul_q    <= mul_d;
        div_q    <= div_d;
    end
end

assign s_axil_awready = write_accept;
assign s_axil_wready  = write_accept;
assign s_axil_bvalid  = bvalid_q;
assign s_axil_bresp   = 2'b00;

// ---- read channel ----
logic        rvalid_d, rvalid_q;
logic [31:0] rdata_d, rdata_q;
wire         read_accept = s_axil_arvalid && (!rvalid_q || s_axil_rready);
wire [1:0]   read_index  = s_axil_araddr[AddrLsb +: 2];

wire [31:0] status_word = {{(31-NumTuneBits){1'b0}}, tune_i, lock_i};

always_comb begin
    rvalid_d = rvalid_q;
    if (read_accept)        rvalid_d = 1'b1;
    else if (s_axil_rready) rvalid_d = 1'b0;
end

always_comb begin
    rdata_d = rdata_q;
    if (read_accept) begin
        case (read_index)
            2'd0:    rdata_d = {31'b0, ctrl_q};
            2'd1:    rdata_d = {{(32-EdgeCountWidth){1'b0}}, mul_q};
            2'd2:    rdata_d = {{(32-WindowSizeWidth){1'b0}}, div_q};
            default: rdata_d = status_word;
        endcase
    end
end

always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
        rvalid_q <= 1'b0;
        rdata_q  <= '0;
    end else begin
        rvalid_q <= rvalid_d;
        rdata_q  <= rdata_d;
    end
end

assign s_axil_arready = read_accept;
assign s_axil_rdata   = rdata_q;
assign s_axil_rvalid  = rvalid_q;
assign s_axil_rresp   = 2'b00;

assign enable_o = ctrl_q;
assign mul_o    = mul_q;
assign div_o    = div_q;

endmodule

`default_nettype wire
