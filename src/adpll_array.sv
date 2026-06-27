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
// A fabric of NumPll genuinely-distinct ADPLLs that fill the chip's spare area as a silicon
// characterization vehicle. Every PLL is one adpll_config -- a (loop-filter x DCO) combination with
// its own loop gains and lock criterion -- stamped out across NumFilters (3) x NumDcos (4) x
// NumVariants gain/lock profiles, so each instance is a different design point. All share one uniform
// CSR interface (adpll_array_csr at 0x2000_0000): a host enables/programs each PLL (mul/div) over
// Ethernet and reads its lock/tune; a CSR-selected observation mux routes one PLL's DCO clock + lock
// to the shared observation outputs (far fewer pads than PLLs, so observation is multiplexed -- every
// PLL still runs and is read back over the CSR). PLL 0 is bangbang x binary at the default profile,
// keeping the original single-PLL CSR offsets valid.
//
// NumVariants scales the count (NumPll = 12 * NumVariants) to fill available area; the tune-code width
// is uniform across all configs so the CSR's tune readback field is one fixed width.

module adpll_array #(
    parameter  int unsigned AddrWidth         = 32,
    parameter  int unsigned NumTuneBits       = 7,
    // Number of distinct PLLs to instantiate. The dont_touch ring DCOs are routing-congestion-heavy
    // (all 5 metals used), so the placeable ceiling on this 1x1 die is ~12-16 PLLs (~48% util);
    // 24/36/48 overflow detailed placement. PLLs are ordered base-profile-first: indices 0..11 are
    // the 12 (filter x DCO) combos at gain/lock profile 0, then 12..23 add profile 1, etc., so any
    // NumPll keeps a balanced filter/DCO spread and index 0 = bangbang x binary (original CSR offsets).
    parameter  int unsigned NumPll            = 16,
    parameter  int unsigned MaxEdgesPerWindow = (1 << 24) - 1,
    localparam int unsigned EdgeCountWidth    = $clog2(MaxEdgesPerWindow + 1),
    parameter  int unsigned MaxWindowSize     = (1 << 16) - 1,
    localparam int unsigned WindowSizeWidth   = $clog2(MaxWindowSize + 1),
    localparam int unsigned NumFilters        = 3,
    localparam int unsigned NumDcos           = 4,
    localparam int unsigned NumProfiles       = 4,    // gain/lock profiles available (cycled by index)
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

// Per-variant loop-filter gains + lock criterion. Each profile is a distinct loop personality; the
// selected filter inside adpll_config uses only its own knobs (the others are ignored). Profiles
// cycle every 4 variants, so NumVariants in 1..4 yields all-distinct (filter x DCO x profile) configs.
// NB: the bang-bang lock sample (the integral) dithers by +-IntegralGain at lock, so a profile's
// IntegralGain must be <= its LockBandRadius or the lock detector never sees its band satisfied.
// (profile 3 uses gain 2, and profile 3's band is 2 -- see lock_band_radius.)
function automatic int unsigned bangbang_integral_gain(int unsigned v);
    case (v % 4) 0: return 1; 1: return 1; 2: return 1; default: return 2; endcase
endfunction
function automatic int unsigned bangbang_proportional_gain(int unsigned v);
    case (v % 4) 0: return 1; 1: return 2; 2: return 1; default: return 2; endcase
endfunction
function automatic int unsigned pi_alpha_shift(int unsigned v);
    case (v % 4) 0: return 10; 1: return 8; 2: return 12; default: return 9; endcase
endfunction
function automatic int unsigned pi_beta_shift(int unsigned v);
    case (v % 4) 0: return 8; 1: return 6; 2: return 10; default: return 7; endcase
endfunction
function automatic int unsigned gearshift_max_gear(int unsigned v);
    case (v % 4) 0: return 2; 1: return 3; 2: return 2; default: return 3; endcase
endfunction
function automatic int unsigned gearshift_upshift_after(int unsigned v);
    case (v % 4) 0: return 4; 1: return 4; 2: return 8; default: return 8; endcase
endfunction
function automatic int unsigned lock_band_radius(int unsigned v);
    case (v % 4) 0: return 1; 1: return 2; 2: return 1; default: return 2; endcase
endfunction
function automatic int unsigned lock_min_samples(int unsigned v);
    case (v % 4) 0: return 8; 1: return 8; 2: return 16; default: return 4; endcase
endfunction

// One adpll_config per PLL index. Index maps base-profile-first: idx % 12 picks the (filter, DCO)
// combo and idx / 12 picks the gain/lock profile, so the first 12 indices are the 12 combos at
// profile 0 (index 0 = bangbang x binary x profile 0 -> original CSR offsets), and higher NumPll add
// further profiles while keeping a balanced filter/DCO spread.
generate
    for (genvar idx_GEN = 0; idx_GEN < NumPll; idx_GEN++) begin : pll
        localparam int unsigned FilterDco = idx_GEN % (NumFilters * NumDcos);
        localparam int unsigned Profile   = idx_GEN / (NumFilters * NumDcos);
        localparam int unsigned FilterSel = FilterDco / NumDcos;
        localparam int unsigned DcoSel    = FilterDco % NumDcos;
        adpll_config #(
            .FilterSel                     (FilterSel),
            .DcoSel                        (DcoSel),
            .DcoNumTuneBits                (NumTuneBits),
            .BangbangIntegralGain          (bangbang_integral_gain(Profile)),
            .BangbangProportionalGain      (bangbang_proportional_gain(Profile)),
            .ProportionalIntegralAlphaShift(pi_alpha_shift(Profile)),
            .ProportionalIntegralBetaShift (pi_beta_shift(Profile)),
            .GearshiftMaxGear              (gearshift_max_gear(Profile)),
            .GearshiftUpshiftAfter         (gearshift_upshift_after(Profile)),
            .LockMinSamplesForLock         (lock_min_samples(Profile)),
            .LockBandRadius                (lock_band_radius(Profile)),
            .FreqDetectorMaxEdgesPerWindow (MaxEdgesPerWindow),
            .FreqDetectorMaxWindowSize     (MaxWindowSize)
        ) adpll_config (
            .clk_i           (clk_i),
            .rst_ni          (rst_ni),
            .enable_i        (pll_enable[idx_GEN]),
            .ref_mul_i       (pll_mul[idx_GEN*EdgeCountWidth +: EdgeCountWidth]),
            .ref_div_i       (pll_div[idx_GEN*WindowSizeWidth +: WindowSizeWidth]),
            .post_div_i      (8'd1),
            .clk_o           (),   // synthesized /K output unused; observe the DCO below
            .lock_o          (pll_lock[idx_GEN]),
            .debug_dco_tune_o(pll_tune[idx_GEN*NumTuneBits +: NumTuneBits]),
            .debug_dco_clk_o (pll_dco_clk[idx_GEN])
        );
    end
endgenerate

// Observation mux: route the CSR-selected PLL's DCO clock + lock to the shared observation pins.
assign obs_dco_clk_o = pll_dco_clk[obs_sel];
assign obs_lock_o    = pll_lock[obs_sel];

endmodule
