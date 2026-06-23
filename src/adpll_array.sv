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
// adpll_array
//
// The 12-PLL ADPLL subsystem: every controller x DCO macro (3 controllers x 4 DCOs) instantiated
// once and wired to adpll_array_csr, so a host programs each PLL independently over Ethernet
// (enable/mul/div) and reads its lock/tune. A CSR-selected observation mux routes one PLL's DCO
// clock + lock to the shared observation outputs (the chip has far fewer pads than 12 PLLs, so
// observation is multiplexed -- every PLL still runs and is read back over the CSR). The macros are
// frozen blocks with no parameters; this wrapper's widths (defaults) match their fixed 7/24/16 config.
//
// Parameters:
//   - NumTuneBits, MaxEdgesPerWindow, MaxWindowSize : widths shared by the CSR (must match the macros)
// Ports: AXI4-Lite slave (PLL control/status over the fabric) + obs_dco_clk_o / obs_lock_o

module adpll_array #(
    parameter  int unsigned AddrWidth         = 32,
    parameter  int unsigned NumTuneBits       = 7,
    parameter  int unsigned MaxEdgesPerWindow = (1 << 24) - 1,
    localparam int unsigned EdgeCountWidth    = $clog2(MaxEdgesPerWindow + 1),
    parameter  int unsigned MaxWindowSize     = (1 << 16) - 1,
    localparam int unsigned WindowSizeWidth   = $clog2(MaxWindowSize + 1),
    localparam int unsigned NumPll            = 12,
    localparam int unsigned SelWidth          = $clog2(NumPll)
) (
    input  wire                  clk_i,
    input  wire                  rst_ni,

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

    output wire                  obs_dco_clk_o,   // selected PLL's DCO clock (observation)
    output wire                  obs_lock_o       // selected PLL's lock flag (observation)
);

wire [NumPll-1:0]                 pll_enable;
wire [NumPll*EdgeCountWidth-1:0]  pll_mul;
wire [NumPll*WindowSizeWidth-1:0] pll_div;
wire [NumPll-1:0]                 pll_lock;
wire [NumPll*NumTuneBits-1:0]     pll_tune;
wire [NumPll-1:0]                 pll_dco_clk;
wire [SelWidth-1:0]               obs_sel;

adpll_array_csr #(
    .AddrWidth(AddrWidth),
    .NumPll(NumPll),
    .NumTuneBits(NumTuneBits),
    .MaxEdgesPerWindow(MaxEdgesPerWindow),
    .MaxWindowSize(MaxWindowSize)
) adpll_array_csr (
    .clk_i,
    .rst_ni,
    .s_axil_awaddr,
    .s_axil_awprot,
    .s_axil_awvalid,
    .s_axil_awready,
    .s_axil_wdata,
    .s_axil_wstrb,
    .s_axil_wvalid,
    .s_axil_wready,
    .s_axil_bresp,
    .s_axil_bvalid,
    .s_axil_bready,
    .s_axil_araddr,
    .s_axil_arprot,
    .s_axil_arvalid,
    .s_axil_arready,
    .s_axil_rdata,
    .s_axil_rresp,
    .s_axil_rvalid,
    .s_axil_rready,
    .enable_o (pll_enable),
    .mul_o    (pll_mul),
    .div_o    (pll_div),
    .lock_i   (pll_lock),
    .tune_i   (pll_tune),
    .obs_sel_o(obs_sel)
);

adpll_bangbang_binary adpll_bangbang_binary (
    .clk_i    (clk_i),
    .rst_ni   (rst_ni),
    .enable_i (pll_enable[0]),
    .mul_i    (pll_mul[0*EdgeCountWidth +: EdgeCountWidth]),
    .div_i    (pll_div[0*WindowSizeWidth +: WindowSizeWidth]),
    .lock_o   (pll_lock[0]),
    .tune_o   (pll_tune[0*NumTuneBits +: NumTuneBits]),
    .dco_clk_o(pll_dco_clk[0])
);

adpll_bangbang_thermometer adpll_bangbang_thermometer (
    .clk_i    (clk_i),
    .rst_ni   (rst_ni),
    .enable_i (pll_enable[1]),
    .mul_i    (pll_mul[1*EdgeCountWidth +: EdgeCountWidth]),
    .div_i    (pll_div[1*WindowSizeWidth +: WindowSizeWidth]),
    .lock_o   (pll_lock[1]),
    .tune_o   (pll_tune[1*NumTuneBits +: NumTuneBits]),
    .dco_clk_o(pll_dco_clk[1])
);

adpll_bangbang_muxtap adpll_bangbang_muxtap (
    .clk_i    (clk_i),
    .rst_ni   (rst_ni),
    .enable_i (pll_enable[2]),
    .mul_i    (pll_mul[2*EdgeCountWidth +: EdgeCountWidth]),
    .div_i    (pll_div[2*WindowSizeWidth +: WindowSizeWidth]),
    .lock_o   (pll_lock[2]),
    .tune_o   (pll_tune[2*NumTuneBits +: NumTuneBits]),
    .dco_clk_o(pll_dco_clk[2])
);

adpll_bangbang_coarsefine adpll_bangbang_coarsefine (
    .clk_i    (clk_i),
    .rst_ni   (rst_ni),
    .enable_i (pll_enable[3]),
    .mul_i    (pll_mul[3*EdgeCountWidth +: EdgeCountWidth]),
    .div_i    (pll_div[3*WindowSizeWidth +: WindowSizeWidth]),
    .lock_o   (pll_lock[3]),
    .tune_o   (pll_tune[3*NumTuneBits +: NumTuneBits]),
    .dco_clk_o(pll_dco_clk[3])
);

adpll_linear_binary adpll_linear_binary (
    .clk_i    (clk_i),
    .rst_ni   (rst_ni),
    .enable_i (pll_enable[4]),
    .mul_i    (pll_mul[4*EdgeCountWidth +: EdgeCountWidth]),
    .div_i    (pll_div[4*WindowSizeWidth +: WindowSizeWidth]),
    .lock_o   (pll_lock[4]),
    .tune_o   (pll_tune[4*NumTuneBits +: NumTuneBits]),
    .dco_clk_o(pll_dco_clk[4])
);

adpll_linear_thermometer adpll_linear_thermometer (
    .clk_i    (clk_i),
    .rst_ni   (rst_ni),
    .enable_i (pll_enable[5]),
    .mul_i    (pll_mul[5*EdgeCountWidth +: EdgeCountWidth]),
    .div_i    (pll_div[5*WindowSizeWidth +: WindowSizeWidth]),
    .lock_o   (pll_lock[5]),
    .tune_o   (pll_tune[5*NumTuneBits +: NumTuneBits]),
    .dco_clk_o(pll_dco_clk[5])
);

adpll_linear_muxtap adpll_linear_muxtap (
    .clk_i    (clk_i),
    .rst_ni   (rst_ni),
    .enable_i (pll_enable[6]),
    .mul_i    (pll_mul[6*EdgeCountWidth +: EdgeCountWidth]),
    .div_i    (pll_div[6*WindowSizeWidth +: WindowSizeWidth]),
    .lock_o   (pll_lock[6]),
    .tune_o   (pll_tune[6*NumTuneBits +: NumTuneBits]),
    .dco_clk_o(pll_dco_clk[6])
);

adpll_linear_coarsefine adpll_linear_coarsefine (
    .clk_i    (clk_i),
    .rst_ni   (rst_ni),
    .enable_i (pll_enable[7]),
    .mul_i    (pll_mul[7*EdgeCountWidth +: EdgeCountWidth]),
    .div_i    (pll_div[7*WindowSizeWidth +: WindowSizeWidth]),
    .lock_o   (pll_lock[7]),
    .tune_o   (pll_tune[7*NumTuneBits +: NumTuneBits]),
    .dco_clk_o(pll_dco_clk[7])
);

adpll_gearshift_binary adpll_gearshift_binary (
    .clk_i    (clk_i),
    .rst_ni   (rst_ni),
    .enable_i (pll_enable[8]),
    .mul_i    (pll_mul[8*EdgeCountWidth +: EdgeCountWidth]),
    .div_i    (pll_div[8*WindowSizeWidth +: WindowSizeWidth]),
    .lock_o   (pll_lock[8]),
    .tune_o   (pll_tune[8*NumTuneBits +: NumTuneBits]),
    .dco_clk_o(pll_dco_clk[8])
);

adpll_gearshift_thermometer adpll_gearshift_thermometer (
    .clk_i    (clk_i),
    .rst_ni   (rst_ni),
    .enable_i (pll_enable[9]),
    .mul_i    (pll_mul[9*EdgeCountWidth +: EdgeCountWidth]),
    .div_i    (pll_div[9*WindowSizeWidth +: WindowSizeWidth]),
    .lock_o   (pll_lock[9]),
    .tune_o   (pll_tune[9*NumTuneBits +: NumTuneBits]),
    .dco_clk_o(pll_dco_clk[9])
);

adpll_gearshift_muxtap adpll_gearshift_muxtap (
    .clk_i    (clk_i),
    .rst_ni   (rst_ni),
    .enable_i (pll_enable[10]),
    .mul_i    (pll_mul[10*EdgeCountWidth +: EdgeCountWidth]),
    .div_i    (pll_div[10*WindowSizeWidth +: WindowSizeWidth]),
    .lock_o   (pll_lock[10]),
    .tune_o   (pll_tune[10*NumTuneBits +: NumTuneBits]),
    .dco_clk_o(pll_dco_clk[10])
);

adpll_gearshift_coarsefine adpll_gearshift_coarsefine (
    .clk_i    (clk_i),
    .rst_ni   (rst_ni),
    .enable_i (pll_enable[11]),
    .mul_i    (pll_mul[11*EdgeCountWidth +: EdgeCountWidth]),
    .div_i    (pll_div[11*WindowSizeWidth +: WindowSizeWidth]),
    .lock_o   (pll_lock[11]),
    .tune_o   (pll_tune[11*NumTuneBits +: NumTuneBits]),
    .dco_clk_o(pll_dco_clk[11])
);

// Observation mux: route the CSR-selected PLL's DCO clock + lock to the shared observation pins.
assign obs_dco_clk_o = pll_dco_clk[obs_sel];
assign obs_lock_o    = pll_lock[obs_sel];

endmodule
