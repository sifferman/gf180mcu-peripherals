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

// adpll_config
//
// One ADPLL instance whose loop filter and DCO are chosen by parameter, with every loop-filter gain
// and lock criterion exposed. This is the single elaborated building block adpll_array stamps out N
// times -- one per row of a config table -- so a chip can carry many genuinely distinct ADPLLs
// (different filter, different DCO, different gains/tune-resolution/lock band) behind one uniform CSR
// interface. It composes the generic third_party/adpll blocks directly (detector -> loop filter ->
// DCO + lock detect + post divider), the same assembly the submodule's per-config wrappers use, but
// FilterKind/DcoKind select the modules via generate and the gains come from parameters instead of
// each combination being its own hand-written module.
//
// FilterSel : 0 = bangbang, 1 = proportionalintegral, 2 = gearshift
// DcoSel    : 0 = binary,   1 = thermometer,          2 = muxtap, 3 = coarsefine
// (integer selects, not strings, so a parent can drive them from a genvar-indexed localparam table)
// The frequency-detector ratio (ref_mul_i / ref_div_i) and output divide (post_div_i) are runtime
// CSR inputs, identical across every config so one CSR drives them all; the parameters are the
// silicon-fixed personality of this instance.

module adpll_config #(
    parameter int unsigned  FilterSel                     = 0,
    parameter int unsigned  DcoSel                        = 0,

    parameter int unsigned  DcoNumTuneBits                = 7,
    parameter int unsigned  DcoNumFineBits                = 3,    // coarsefine DCO only

    // loop-filter gains (only the selected filter's are used)
    parameter int unsigned  BangbangIntegralGain          = 1,
    parameter int unsigned  BangbangProportionalGain      = 1,
    parameter int unsigned  ProportionalIntegralAccWidth  = 19,
    parameter int unsigned  ProportionalIntegralAlphaShift = 10,
    parameter int unsigned  ProportionalIntegralBetaShift = 8,
    parameter int unsigned  GearshiftMaxGear              = (DcoNumTuneBits >= 2) ? 2 : 0,
    parameter int unsigned  GearshiftUpshiftAfter         = 4,

    // lock criterion
    parameter int unsigned  LockMinSamplesForLock         = 8,
    parameter int unsigned  LockBandRadius                = 1,

    // detector / divider sizing (kept at the full-rate widths so the CSR fields are uniform)
    parameter int unsigned  FreqDetectorMaxEdgesPerWindow = (1 << 24) - 1,
    parameter int unsigned  FreqDetectorMaxWindowSize     = (1 << 16) - 1,
    parameter int unsigned  PostDividerMaxDivide          = 255,

    localparam int unsigned FreqDetectorEdgeCountWidth    = $clog2(FreqDetectorMaxEdgesPerWindow + 1),
    localparam int unsigned FreqDetectorWindowSizeWidth   = $clog2(FreqDetectorMaxWindowSize + 1),
    localparam int unsigned LoopFilterErrorWidth          = FreqDetectorEdgeCountWidth + 2,
    localparam int unsigned PostDividerDivideWidth        = $clog2(PostDividerMaxDivide + 1)
) (
    input  logic                                  clk_i,
    input  logic                                  rst_ni,

    input  logic                                  enable_i,
    input  logic [FreqDetectorEdgeCountWidth-1:0] ref_mul_i,   // target edge count N (set over CSR)
    input  logic [FreqDetectorWindowSizeWidth-1:0] ref_div_i,  // window length M, ref cycles (CSR)
    input  logic [PostDividerDivideWidth-1:0]     post_div_i,  // output divide K (set over CSR)

    output logic                                  clk_o,       // synthesized output = F_DCO / K
    output logic                                  lock_o,

    output logic [DcoNumTuneBits-1:0]             debug_dco_tune_o,
    output logic                                  debug_dco_clk_o
);

  wire signed [LoopFilterErrorWidth-1:0] loop_filter_error;
  wire                                   loop_filter_error_valid;
  wire [DcoNumTuneBits-1:0]              dco_tune;
  wire [DcoNumTuneBits-1:0]              lock_detector_sample;
  wire                                   dco_clk;

  adpll_freq_detector #(
      .MaxEdgesPerWindow(FreqDetectorMaxEdgesPerWindow),
      .MaxWindowSize    (FreqDetectorMaxWindowSize)
  ) adpll_freq_detector (
      .clk_i          (clk_i),
      .rst_ni         (rst_ni),
      .enable_i       (enable_i),
      .target_i       (ref_mul_i),
      .window_length_i(ref_div_i),
      .dco_clk_i      (dco_clk),
      .error_o        (loop_filter_error),
      .valid_o        (loop_filter_error_valid)
  );

  // loop filter: FilterKind selects the implementation; each uses its own gain parameters.
  generate
    if (FilterSel == 0) begin : loop_filter
      adpll_loop_filter_bangbang #(
          .NumTuneBits     (DcoNumTuneBits),
          .ErrorWidth      (LoopFilterErrorWidth),
          .IntegralGain    (BangbangIntegralGain),
          .ProportionalGain(BangbangProportionalGain)
      ) adpll_loop_filter (
          .clk_i        (clk_i),
          .rst_ni       (rst_ni),
          .enable_i     (enable_i),
          .valid_i      (loop_filter_error_valid),
          .error_i      (loop_filter_error),
          .tune_o       (dco_tune),
          .lock_sample_o(lock_detector_sample)
      );
    end else if (FilterSel == 1) begin : loop_filter
      adpll_loop_filter_proportionalintegral #(
          .NumTuneBits(DcoNumTuneBits),
          .ErrorWidth (LoopFilterErrorWidth),
          .AccWidth   (ProportionalIntegralAccWidth),
          .AlphaShift (ProportionalIntegralAlphaShift),
          .BetaShift  (ProportionalIntegralBetaShift)
      ) adpll_loop_filter (
          .clk_i        (clk_i),
          .rst_ni       (rst_ni),
          .enable_i     (enable_i),
          .valid_i      (loop_filter_error_valid),
          .error_i      (loop_filter_error),
          .tune_o       (dco_tune),
          .lock_sample_o(lock_detector_sample)
      );
    end else begin : loop_filter   // "gearshift"
      adpll_loop_filter_gearshift #(
          .NumTuneBits (DcoNumTuneBits),
          .ErrorWidth  (LoopFilterErrorWidth),
          .MaxGear     (GearshiftMaxGear),
          .UpshiftAfter(GearshiftUpshiftAfter)
      ) adpll_loop_filter (
          .clk_i        (clk_i),
          .rst_ni       (rst_ni),
          .enable_i     (enable_i),
          .valid_i      (loop_filter_error_valid),
          .error_i      (loop_filter_error),
          .tune_o       (dco_tune),
          .lock_sample_o(lock_detector_sample)
      );
    end
  endgenerate

  adpll_lock_detector #(
      .SampleWidth      (DcoNumTuneBits),
      .MinSamplesForLock(LockMinSamplesForLock),
      .BandRadius       (LockBandRadius)
  ) adpll_lock_detector (
      .clk_i          (clk_i),
      .rst_ni         (rst_ni),
      .enable_i       (enable_i),
      .sample_valid_i (loop_filter_error_valid),
      .tuning_sample_i(lock_detector_sample),
      .lock_o         (lock_o)
  );

  // DCO: DcoKind selects the ring topology. All are structural gf180 cells (Target) with the ring
  // kept/dont_touch inside the module, so the free-running oscillator survives synthesis.
  generate
    if (DcoSel == 1) begin : dco
      ring_dco_thermometer #(.NumTuneBits(DcoNumTuneBits), .Target("gf180mcu_as_sc_mcu7t3v3"))
          ring_dco (.enable_i(enable_i), .tune_i(dco_tune), .clk_o(dco_clk));
    end else if (DcoSel == 2) begin : dco
      ring_dco_muxtap #(.NumTuneBits(DcoNumTuneBits), .Target("gf180mcu_as_sc_mcu7t3v3"))
          ring_dco (.enable_i(enable_i), .tune_i(dco_tune), .clk_o(dco_clk));
    end else if (DcoSel == 3) begin : dco
      ring_dco_coarsefine #(.NumTuneBits(DcoNumTuneBits), .NumFineBits(DcoNumFineBits),
          .Target("gf180mcu_as_sc_mcu7t3v3"))
          ring_dco (.enable_i(enable_i), .tune_i(dco_tune), .clk_o(dco_clk));
    end else begin : dco   // "binary"
      ring_dco_binary #(.NumTuneBits(DcoNumTuneBits), .Target("gf180mcu_as_sc_mcu7t3v3"))
          ring_dco (.enable_i(enable_i), .tune_i(dco_tune), .clk_o(dco_clk));
    end
  endgenerate

  adpll_post_divider #(
      .DivisorWidth(PostDividerDivideWidth)
  ) adpll_post_divider (
      .clk_i    (dco_clk),
      .rst_ni   (rst_ni),
      .enable_i (enable_i),
      .divisor_i(post_div_i),
      .clk_o    (clk_o)
  );

  assign debug_dco_tune_o = dco_tune;
  assign debug_dco_clk_o  = dco_clk;

endmodule
