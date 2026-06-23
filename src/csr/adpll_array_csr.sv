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

// adpll_array_csr
//
// AXI4-Lite control/status registers for an array of NumPll ADPLL macros. Each PLL has its own
// enable / mul / div (programmed independently over Ethernet) and reports lock + tune; one global
// register selects which PLL's clock + lock drive the shared observation outputs. Single
// outstanding transaction, same handshake as axil_ram / adpll_csr.
//
// Register map (word-addressed; PLL i occupies 4 words at byte offset i*0x10):
//   i*0x10 + 0x0  CTRL[i]    [0]      enable                (R/W)
//   i*0x10 + 0x4  MUL[i]     [EdgeCountWidth-1:0] mul (N)   (R/W)
//   i*0x10 + 0x8  DIV[i]     [WindowSizeWidth-1:0] div (M)  (R/W)
//   i*0x10 + 0xC  STATUS[i]  [0] lock, [NumTuneBits:1] tune (RO)
//   NumPll*0x10   OBS_SEL    [SelWidth-1:0] observed PLL index (R/W)
//
// Parameters:
//   - NumPll      : number of ADPLL macros
//   - NumTuneBits, MaxEdgesPerWindow, MaxWindowSize : PLL widths (must match the macros)
// Ports: AXI4-Lite slave + flattened per-PLL control out / status in + obs_sel_o

module adpll_array_csr #(
    parameter  int unsigned AddrWidth         = 32,
    parameter  int unsigned NumPll            = 12,
    parameter  int unsigned NumTuneBits       = 7,
    parameter  int unsigned MaxEdgesPerWindow = (1 << 24) - 1,
    localparam int unsigned EdgeCountWidth    = $clog2(MaxEdgesPerWindow + 1),
    parameter  int unsigned MaxWindowSize     = (1 << 16) - 1,
    localparam int unsigned WindowSizeWidth   = $clog2(MaxWindowSize + 1),
    localparam int unsigned SelWidth          = $clog2(NumPll),
    localparam int unsigned NumWords          = NumPll * 4 + 1,
    localparam int unsigned WordIdxWidth      = $clog2(NumWords)
) (
    input  wire                  clk_i,
    input  wire                  rst_ni,

    // AXI-Lite slave interface
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

    // Per-PLL control out / status in (flattened: PLL i is bit/field i)
    output wire [NumPll-1:0]                  enable_o,
    output wire [NumPll*EdgeCountWidth-1:0]   mul_o,
    output wire [NumPll*WindowSizeWidth-1:0]  div_o,
    input  wire [NumPll-1:0]                  lock_i,
    input  wire [NumPll*NumTuneBits-1:0]      tune_i,
    // Observation select
    output wire [SelWidth-1:0]                obs_sel_o
);

localparam int unsigned AddrLsb = 2;   // 32-bit registers

// Flattened packed storage (PLL i field = [i*Width +: Width]); avoids unpacked-array assignment.
logic [NumPll-1:0]                 enable_d, enable_q;
logic [NumPll*EdgeCountWidth-1:0]  mul_d,    mul_q;
logic [NumPll*WindowSizeWidth-1:0] div_d,    div_q;
logic [SelWidth-1:0]               obs_sel_d, obs_sel_q;

logic _unused;
assign _unused = &{1'b0, s_axil_awprot, s_axil_arprot,
                   s_axil_awaddr[AddrWidth-1:AddrLsb+WordIdxWidth], s_axil_awaddr[AddrLsb-1:0],
                   s_axil_araddr[AddrWidth-1:AddrLsb+WordIdxWidth], s_axil_araddr[AddrLsb-1:0],
                   s_axil_wdata[31:1]};

// ---- write channel ----
logic       bvalid_d, bvalid_q;
wire        write_accept = s_axil_awvalid && s_axil_wvalid && (!bvalid_q || s_axil_bready);
wire [WordIdxWidth-1:0] write_word = s_axil_awaddr[AddrLsb +: WordIdxWidth];
wire [WordIdxWidth-1:0] write_pll  = write_word >> 2;          // word / 4 = PLL index
wire [1:0]              write_reg  = write_word[1:0];          // word % 4 = register
wire                    write_obs  = (write_pll >= NumPll[WordIdxWidth-1:0]);

always_comb begin
    bvalid_d = bvalid_q;
    if (write_accept)       bvalid_d = 1'b1;
    else if (s_axil_bready) bvalid_d = 1'b0;
end

always_comb begin
    enable_d  = enable_q;
    mul_d     = mul_q;
    div_d     = div_q;
    obs_sel_d = obs_sel_q;
    if (write_accept && s_axil_wstrb[0]) begin
        if (write_obs) begin
            obs_sel_d = s_axil_wdata[SelWidth-1:0];
        end else begin
            for (int unsigned i = 0; i < NumPll; i++) begin
                if (write_pll == i[WordIdxWidth-1:0]) begin
                    case (write_reg)
                        2'd0:    enable_d[i]                              = s_axil_wdata[0];
                        2'd1:    mul_d[i*EdgeCountWidth +: EdgeCountWidth] = s_axil_wdata[EdgeCountWidth-1:0];
                        2'd2:    div_d[i*WindowSizeWidth +: WindowSizeWidth] = s_axil_wdata[WindowSizeWidth-1:0];
                        default: ;   // STATUS is read-only
                    endcase
                end
            end
        end
    end
end

always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
        bvalid_q  <= 1'b0;
        enable_q  <= '0;
        mul_q     <= '0;
        div_q     <= '0;
        obs_sel_q <= '0;
    end else begin
        bvalid_q  <= bvalid_d;
        enable_q  <= enable_d;
        mul_q     <= mul_d;
        div_q     <= div_d;
        obs_sel_q <= obs_sel_d;
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
wire [WordIdxWidth-1:0] read_word = s_axil_araddr[AddrLsb +: WordIdxWidth];
wire [WordIdxWidth-1:0] read_pll  = read_word >> 2;
wire [1:0]              read_reg  = read_word[1:0];
wire                    read_obs  = (read_pll >= NumPll[WordIdxWidth-1:0]);

always_comb begin
    rvalid_d = rvalid_q;
    if (read_accept)        rvalid_d = 1'b1;
    else if (s_axil_rready) rvalid_d = 1'b0;
end

always_comb begin
    // Select the addressed PLL's fields with constant-index part-selects (loop unrolls).
    logic                      enable_sel;
    logic [EdgeCountWidth-1:0]  mul_sel;
    logic [WindowSizeWidth-1:0] div_sel;
    logic [NumTuneBits-1:0]     tune_sel;
    logic                       lock_sel;
    enable_sel = 1'b0;
    mul_sel    = '0;
    div_sel    = '0;
    tune_sel   = '0;
    lock_sel   = 1'b0;
    for (int unsigned i = 0; i < NumPll; i++) begin
        if (read_pll == i[WordIdxWidth-1:0]) begin
            enable_sel = enable_q[i];
            mul_sel    = mul_q[i*EdgeCountWidth +: EdgeCountWidth];
            div_sel    = div_q[i*WindowSizeWidth +: WindowSizeWidth];
            tune_sel   = tune_i[i*NumTuneBits +: NumTuneBits];
            lock_sel   = lock_i[i];
        end
    end

    rdata_d = rdata_q;
    if (read_accept) begin
        if (read_obs) begin
            rdata_d = {{(32-SelWidth){1'b0}}, obs_sel_q};
        end else begin
            case (read_reg)
                2'd0:    rdata_d = {31'b0, enable_sel};
                2'd1:    rdata_d = {{(32-EdgeCountWidth){1'b0}},  mul_sel};
                2'd2:    rdata_d = {{(32-WindowSizeWidth){1'b0}}, div_sel};
                default: rdata_d = {{(31-NumTuneBits){1'b0}}, tune_sel, lock_sel};
            endcase
        end
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

assign enable_o  = enable_q;
assign mul_o     = mul_q;
assign div_o     = div_q;
assign obs_sel_o = obs_sel_q;

endmodule
