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
    parameter  int unsigned NumPll            = 12,
    parameter  int unsigned MaxEdgesPerWindow = (1 << 24) - 1,
    localparam int unsigned EdgeCountWidth    = $clog2(MaxEdgesPerWindow + 1),
    parameter  int unsigned MaxWindowSize     = (1 << 16) - 1,
    localparam int unsigned WindowSizeWidth   = $clog2(MaxWindowSize + 1),
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

// Curated set of NumPll genuinely-distinct ADPLLs -- each a different design-point tradeoff, so the
// chip characterizes the space rather than replicating one design. Index 0 is FLL bang-bang x binary
// (original CSR offsets, keeps the Ethernet UDP test valid). Per-index rationale (tradeoff captured):
//   0  FLL bb     x binary      x7  fast lock, widest range, non-monotonic ring (lock-risk)
//   1  FLL pi     x thermometer x7  most reliable: monotonic ring + low-jitter PI, larger area
//   2  FLL gear   x muxtap      x5  fastest acquire, steep ring, small/high-freq (5-bit)
//   3  FLL pi     x coarsefine  x7  wide range + fine resolution (two-scale ring)
//   4  FLL bb     x muxtap      x5  smallest area, highest freq, coarse (5-bit)
//   5  FLL gear   x binary      x7  fast acquire over the wide non-monotonic range
//   6  FLL pi     x muxtap      x5  low jitter, steep ring, small
//   7  FLL bb     x thermometer x5  monotonic + fast + small
//   8  FLL gear   x coarsefine  x7  fast acquire, wide + fine
//   9  PHASE pi   x thermometer x7  true phase lock, lowest jitter, reliable ring
//   10 PHASE pi   x muxtap      x5  phase lock, small/high-freq
//   11 PHASE pi   x binary      x7  phase lock over the wide range
// domain 0=FLL(mul/div) 1=phase(fcw); filter 0=bb 1=pi 2=gear; dco 0=bin 1=therm 2=mux 3=cf;
// tune = DCO tune bits (zero-extended to the uniform CSR field). Loop gains use adpll_config's
// proven defaults; diversity here is the filter/DCO/domain/resolution axes.
// The table is expressed as constant case-functions (iverilog has no unpacked-array parameters).
function automatic int unsigned cfg_domain(int unsigned i);            // 0=FLL 1=phase
    case (i) 9, 10, 11: return 1; default: return 0; endcase
endfunction
function automatic int unsigned cfg_filter(int unsigned i);            // 0=bb 1=pi 2=gear
    case (i) 0, 4, 7: return 0; 2, 5, 8: return 2; default: return 1; endcase
endfunction
function automatic int unsigned cfg_dco(int unsigned i);               // 0=bin 1=therm 2=mux 3=cf
    case (i) 0, 5, 11: return 0; 1, 7, 9: return 1; 2, 4, 6, 10: return 2; default: return 3; endcase
endfunction
function automatic int unsigned cfg_tune(int unsigned i);              // DCO tune bits
    case (i) 2, 4, 6, 7, 10: return 5; default: return 7; endcase
endfunction

generate
    for (genvar idx_GEN = 0; idx_GEN < NumPll; idx_GEN++) begin : pll
        localparam int unsigned Dom  = cfg_domain(idx_GEN);
        localparam int unsigned Fsel = cfg_filter(idx_GEN);
        localparam int unsigned Dsel = cfg_dco(idx_GEN);
        localparam int unsigned Tb   = cfg_tune(idx_GEN);
        wire [Tb-1:0] tune_bits;
        adpll_config #(
            .Domain                       (Dom),
            .FilterSel                    (Fsel),
            .DcoSel                       (Dsel),
            .DcoNumTuneBits               (Tb),
            .FreqDetectorMaxEdgesPerWindow(MaxEdgesPerWindow),
            .FreqDetectorMaxWindowSize    (MaxWindowSize)
        ) adpll_config (
            .clk_i           (clk_i),
            .rst_ni          (rst_ni),
            .enable_i        (pll_enable[idx_GEN]),
            .ref_mul_i       (pll_mul[idx_GEN*EdgeCountWidth +: EdgeCountWidth]),  // = fcw if phase
            .ref_div_i       (pll_div[idx_GEN*WindowSizeWidth +: WindowSizeWidth]),
            .post_div_i      (8'd1),
            .clk_o           (),   // synthesized /K output unused; observe the DCO below
            .lock_o          (pll_lock[idx_GEN]),
            .debug_dco_tune_o(tune_bits),
            .debug_dco_clk_o (pll_dco_clk[idx_GEN])
        );
        // zero-extend this config's tune (Tb bits) into the CSR's uniform NumTuneBits field
        assign pll_tune[idx_GEN*NumTuneBits +: NumTuneBits] = {{(NumTuneBits-Tb){1'b0}}, tune_bits};
    end
endgenerate

// Observation mux: route the CSR-selected PLL's DCO clock + lock to the shared observation pins.
assign obs_dco_clk_o = pll_dco_clk[obs_sel];
assign obs_lock_o    = pll_lock[obs_sel];

endmodule
