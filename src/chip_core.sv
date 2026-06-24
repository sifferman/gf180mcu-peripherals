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

// chip_core
//
// Peripheral integration (Ethernet + SDRAM + ADPLL). The RMII MAC + UDP stack exposes a
// UDP->memory AXI4-Lite master. A top split on addr[29] routes it to the memory subsystem
// (low region) or the ADPLL CSR (high region, 0x2000_0000). The memory subsystem decodes
// addr[28] to slave 0 (on-chip scratch RAM, 0x0) or slave 1 (external SDRAM via sdram_wrap,
// 0x1000_0000), so a host writes/reads SDRAM over plain UDP. The ADPLL is observe-only:
// its CSR sets enable/mul/div, and the DCO clock + lock go to the analog pads. Single 50 MHz
// core domain (clk = clk_PAD, forwarded to the PHY as the RMII reference clock); the DCO runs
// in its own free-running domain and does not clock the core. The clk/rst_n and pad-vector
// ports are the wafer.space slot template's chip_core contract.
//
// Address map (over Ethernet): 0x0000_0000 scratch RAM · 0x1000_0000 SDRAM · 0x2000_0000 ADPLL CSR.
//
// Pad map (1x1 slot, retyped to NUM_BIDIR=47 / NUM_INPUT=5):
//   input_in[0]=rmii_crs_dv [1]=rmii_rx_er [2]=rmii_rxd0 [3]=rmii_rxd1 [4]=mode_strap
//   bidir[0]=tx_en [1]=txd0 [2]=txd1 [3]=ref_clk [4..7]=eth LEDs
//   bidir[8..23]=SDRAM DQ[15:0] (bidirectional)   bidir[24]=sdram_clk [25]=cke
//   [26]=cs [27]=ras [28]=cas [29]=we [30]=dqm0 [31]=dqm1 [32..44]=A[12:0] [45]=ba0 [46]=ba1

`default_nettype none

module chip_core #(
    parameter NUM_INPUT_PADS,
    parameter NUM_BIDIR_PADS,
    parameter NUM_ANALOG_PADS
) (
    `ifdef USE_POWER_PINS
    inout  wire VDD,
    inout  wire VSS,
    `endif

    input  wire clk,
    input  wire rst_n,

    input  wire [NUM_INPUT_PADS-1:0] input_in,
    output wire [NUM_INPUT_PADS-1:0] input_pu,
    output wire [NUM_INPUT_PADS-1:0] input_pd,

    input  wire [NUM_BIDIR_PADS-1:0] bidir_in,
    output wire [NUM_BIDIR_PADS-1:0] bidir_out,
    output wire [NUM_BIDIR_PADS-1:0] bidir_oe,
    output wire [NUM_BIDIR_PADS-1:0] bidir_cs,
    output wire [NUM_BIDIR_PADS-1:0] bidir_sl,
    output wire [NUM_BIDIR_PADS-1:0] bidir_ie,
    output wire [NUM_BIDIR_PADS-1:0] bidir_pu,
    output wire [NUM_BIDIR_PADS-1:0] bidir_pd,

    inout  wire [NUM_ANALOG_PADS-1:0] analog
);

wire       rmii_crs_dv = input_in[0];
wire       rmii_rx_er  = input_in[1];
wire [1:0] rmii_rxd    = input_in[3:2];

wire       rmii_tx_en;
wire [1:0] rmii_txd;
wire [7:0] led;

// Ethernet UDP -> memory master (AXI4-Lite)
wire [31:0] eth_axil_awaddr, eth_axil_wdata, eth_axil_araddr, eth_axil_rdata;
wire [2:0]  eth_axil_awprot, eth_axil_arprot;
wire [3:0]  eth_axil_wstrb;
wire [1:0]  eth_axil_bresp, eth_axil_rresp;
wire        eth_axil_awvalid, eth_axil_awready, eth_axil_wvalid, eth_axil_wready,
            eth_axil_bvalid, eth_axil_bready, eth_axil_arvalid, eth_axil_arready,
            eth_axil_rvalid, eth_axil_rready;

alexforencich_udp_memory_server #(
    .Target("GENERIC")
) i_eth (
    .clk_i (clk),
    .rst_ni(rst_n),
    .phy_rmii_ref_clk_i(clk),
    .phy_rmii_crsdv_i  (rmii_crs_dv),
    .phy_rmii_rxer_i   (rmii_rx_er),
    .phy_rmii_rxd_i    (rmii_rxd),
    .phy_rmii_txen_o   (rmii_tx_en),
    .phy_rmii_txd_o    (rmii_txd),
    .m_axil_awaddr (eth_axil_awaddr),
    .m_axil_awprot (eth_axil_awprot),
    .m_axil_awvalid(eth_axil_awvalid),
    .m_axil_awready(eth_axil_awready),
    .m_axil_wdata  (eth_axil_wdata),
    .m_axil_wstrb  (eth_axil_wstrb),
    .m_axil_wvalid (eth_axil_wvalid),
    .m_axil_wready (eth_axil_wready),
    .m_axil_bresp  (eth_axil_bresp),
    .m_axil_bvalid (eth_axil_bvalid),
    .m_axil_bready (eth_axil_bready),
    .m_axil_araddr (eth_axil_araddr),
    .m_axil_arprot (eth_axil_arprot),
    .m_axil_arvalid(eth_axil_arvalid),
    .m_axil_arready(eth_axil_arready),
    .m_axil_rdata  (eth_axil_rdata),
    .m_axil_rresp  (eth_axil_rresp),
    .m_axil_rvalid (eth_axil_rvalid),
    .m_axil_rready (eth_axil_rready),
    .led_o(led)
);

// Top split (addr[29]): low region -> RAM/SDRAM subsystem, high region (0x2000_0000) -> ADPLL CSR.
// RAM (0x0) and SDRAM (0x1000_0000) keep addr[29]=0, so their addresses are unchanged.
wire [31:0] mem_axil_awaddr, mem_axil_wdata, mem_axil_araddr, mem_axil_rdata;
wire [2:0]  mem_axil_awprot, mem_axil_arprot;
wire [3:0]  mem_axil_wstrb;
wire [1:0]  mem_axil_bresp, mem_axil_rresp;
wire        mem_axil_awvalid, mem_axil_awready, mem_axil_wvalid, mem_axil_wready,
            mem_axil_bvalid, mem_axil_bready, mem_axil_arvalid, mem_axil_arready,
            mem_axil_rvalid, mem_axil_rready;

wire [31:0] csr_axil_awaddr, csr_axil_wdata, csr_axil_araddr, csr_axil_rdata;
wire [2:0]  csr_axil_awprot, csr_axil_arprot;
wire [3:0]  csr_axil_wstrb;
wire [1:0]  csr_axil_bresp, csr_axil_rresp;
wire        csr_axil_awvalid, csr_axil_awready, csr_axil_wvalid, csr_axil_wready,
            csr_axil_bvalid, csr_axil_bready, csr_axil_arvalid, csr_axil_arready,
            csr_axil_rvalid, csr_axil_rready;

axil_interconnect #(
    .SelBit(29)
) i_ic_top (
    .s_axil_awaddr (eth_axil_awaddr),
    .s_axil_awprot (eth_axil_awprot),
    .s_axil_awvalid(eth_axil_awvalid),
    .s_axil_awready(eth_axil_awready),
    .s_axil_wdata  (eth_axil_wdata),
    .s_axil_wstrb  (eth_axil_wstrb),
    .s_axil_wvalid (eth_axil_wvalid),
    .s_axil_wready (eth_axil_wready),
    .s_axil_bresp  (eth_axil_bresp),
    .s_axil_bvalid (eth_axil_bvalid),
    .s_axil_bready (eth_axil_bready),
    .s_axil_araddr (eth_axil_araddr),
    .s_axil_arprot (eth_axil_arprot),
    .s_axil_arvalid(eth_axil_arvalid),
    .s_axil_arready(eth_axil_arready),
    .s_axil_rdata  (eth_axil_rdata),
    .s_axil_rresp  (eth_axil_rresp),
    .s_axil_rvalid (eth_axil_rvalid),
    .s_axil_rready (eth_axil_rready),
    .m0_axil_awaddr (mem_axil_awaddr),
    .m0_axil_awprot (mem_axil_awprot),
    .m0_axil_awvalid(mem_axil_awvalid),
    .m0_axil_awready(mem_axil_awready),
    .m0_axil_wdata  (mem_axil_wdata),
    .m0_axil_wstrb  (mem_axil_wstrb),
    .m0_axil_wvalid (mem_axil_wvalid),
    .m0_axil_wready (mem_axil_wready),
    .m0_axil_bresp  (mem_axil_bresp),
    .m0_axil_bvalid (mem_axil_bvalid),
    .m0_axil_bready (mem_axil_bready),
    .m0_axil_araddr (mem_axil_araddr),
    .m0_axil_arprot (mem_axil_arprot),
    .m0_axil_arvalid(mem_axil_arvalid),
    .m0_axil_arready(mem_axil_arready),
    .m0_axil_rdata  (mem_axil_rdata),
    .m0_axil_rresp  (mem_axil_rresp),
    .m0_axil_rvalid (mem_axil_rvalid),
    .m0_axil_rready (mem_axil_rready),
    .m1_axil_awaddr (csr_axil_awaddr),
    .m1_axil_awprot (csr_axil_awprot),
    .m1_axil_awvalid(csr_axil_awvalid),
    .m1_axil_awready(csr_axil_awready),
    .m1_axil_wdata  (csr_axil_wdata),
    .m1_axil_wstrb  (csr_axil_wstrb),
    .m1_axil_wvalid (csr_axil_wvalid),
    .m1_axil_wready (csr_axil_wready),
    .m1_axil_bresp  (csr_axil_bresp),
    .m1_axil_bvalid (csr_axil_bvalid),
    .m1_axil_bready (csr_axil_bready),
    .m1_axil_araddr (csr_axil_araddr),
    .m1_axil_arprot (csr_axil_arprot),
    .m1_axil_arvalid(csr_axil_arvalid),
    .m1_axil_arready(csr_axil_arready),
    .m1_axil_rdata  (csr_axil_rdata),
    .m1_axil_rresp  (csr_axil_rresp),
    .m1_axil_rvalid (csr_axil_rvalid),
    .m1_axil_rready (csr_axil_rready)
);

// Interconnect: mem master -> {slave 0 scratch RAM, slave 1 SDRAM}
wire [31:0] ram_axil_awaddr, ram_axil_wdata, ram_axil_araddr, ram_axil_rdata;
wire [2:0]  ram_axil_awprot, ram_axil_arprot;
wire [3:0]  ram_axil_wstrb;
wire [1:0]  ram_axil_bresp, ram_axil_rresp;
wire        ram_axil_awvalid, ram_axil_awready, ram_axil_wvalid, ram_axil_wready,
            ram_axil_bvalid, ram_axil_bready, ram_axil_arvalid, ram_axil_arready,
            ram_axil_rvalid, ram_axil_rready;

wire [31:0] sdram_axil_awaddr, sdram_axil_wdata, sdram_axil_araddr, sdram_axil_rdata;
wire [2:0]  sdram_axil_awprot, sdram_axil_arprot;
wire [3:0]  sdram_axil_wstrb;
wire [1:0]  sdram_axil_bresp, sdram_axil_rresp;
wire        sdram_axil_awvalid, sdram_axil_awready, sdram_axil_wvalid, sdram_axil_wready,
            sdram_axil_bvalid, sdram_axil_bready, sdram_axil_arvalid, sdram_axil_arready,
            sdram_axil_rvalid, sdram_axil_rready;

axil_interconnect #(
    .SelBit(28)
) i_ic (
    .s_axil_awaddr (mem_axil_awaddr),
    .s_axil_awprot (mem_axil_awprot),
    .s_axil_awvalid(mem_axil_awvalid),
    .s_axil_awready(mem_axil_awready),
    .s_axil_wdata  (mem_axil_wdata),
    .s_axil_wstrb  (mem_axil_wstrb),
    .s_axil_wvalid (mem_axil_wvalid),
    .s_axil_wready (mem_axil_wready),
    .s_axil_bresp  (mem_axil_bresp),
    .s_axil_bvalid (mem_axil_bvalid),
    .s_axil_bready (mem_axil_bready),
    .s_axil_araddr (mem_axil_araddr),
    .s_axil_arprot (mem_axil_arprot),
    .s_axil_arvalid(mem_axil_arvalid),
    .s_axil_arready(mem_axil_arready),
    .s_axil_rdata  (mem_axil_rdata),
    .s_axil_rresp  (mem_axil_rresp),
    .s_axil_rvalid (mem_axil_rvalid),
    .s_axil_rready (mem_axil_rready),
    .m0_axil_awaddr (ram_axil_awaddr),
    .m0_axil_awprot (ram_axil_awprot),
    .m0_axil_awvalid(ram_axil_awvalid),
    .m0_axil_awready(ram_axil_awready),
    .m0_axil_wdata  (ram_axil_wdata),
    .m0_axil_wstrb  (ram_axil_wstrb),
    .m0_axil_wvalid (ram_axil_wvalid),
    .m0_axil_wready (ram_axil_wready),
    .m0_axil_bresp  (ram_axil_bresp),
    .m0_axil_bvalid (ram_axil_bvalid),
    .m0_axil_bready (ram_axil_bready),
    .m0_axil_araddr (ram_axil_araddr),
    .m0_axil_arprot (ram_axil_arprot),
    .m0_axil_arvalid(ram_axil_arvalid),
    .m0_axil_arready(ram_axil_arready),
    .m0_axil_rdata  (ram_axil_rdata),
    .m0_axil_rresp  (ram_axil_rresp),
    .m0_axil_rvalid (ram_axil_rvalid),
    .m0_axil_rready (ram_axil_rready),
    .m1_axil_awaddr (sdram_axil_awaddr),
    .m1_axil_awprot (sdram_axil_awprot),
    .m1_axil_awvalid(sdram_axil_awvalid),
    .m1_axil_awready(sdram_axil_awready),
    .m1_axil_wdata  (sdram_axil_wdata),
    .m1_axil_wstrb  (sdram_axil_wstrb),
    .m1_axil_wvalid (sdram_axil_wvalid),
    .m1_axil_wready (sdram_axil_wready),
    .m1_axil_bresp  (sdram_axil_bresp),
    .m1_axil_bvalid (sdram_axil_bvalid),
    .m1_axil_bready (sdram_axil_bready),
    .m1_axil_araddr (sdram_axil_araddr),
    .m1_axil_arprot (sdram_axil_arprot),
    .m1_axil_arvalid(sdram_axil_arvalid),
    .m1_axil_arready(sdram_axil_arready),
    .m1_axil_rdata  (sdram_axil_rdata),
    .m1_axil_rresp  (sdram_axil_rresp),
    .m1_axil_rvalid (sdram_axil_rvalid),
    .m1_axil_rready (sdram_axil_rready)
);

axil_ram #(
    .Words(256)
) i_mem (
    .clk_i (clk),
    .rst_ni(rst_n),
    .s_axil_awaddr (ram_axil_awaddr),
    .s_axil_awprot (ram_axil_awprot),
    .s_axil_awvalid(ram_axil_awvalid),
    .s_axil_awready(ram_axil_awready),
    .s_axil_wdata  (ram_axil_wdata),
    .s_axil_wstrb  (ram_axil_wstrb),
    .s_axil_wvalid (ram_axil_wvalid),
    .s_axil_wready (ram_axil_wready),
    .s_axil_bresp  (ram_axil_bresp),
    .s_axil_bvalid (ram_axil_bvalid),
    .s_axil_bready (ram_axil_bready),
    .s_axil_araddr (ram_axil_araddr),
    .s_axil_arprot (ram_axil_arprot),
    .s_axil_arvalid(ram_axil_arvalid),
    .s_axil_arready(ram_axil_arready),
    .s_axil_rdata  (ram_axil_rdata),
    .s_axil_rresp  (ram_axil_rresp),
    .s_axil_rvalid (ram_axil_rvalid),
    .s_axil_rready (ram_axil_rready)
);

// External SDRAM
wire        sdram_clk, sdram_cke, sdram_cs, sdram_ras, sdram_cas, sdram_we, sdram_dq_oe;
wire [1:0]  sdram_dqm, sdram_ba;
wire [12:0] sdram_addr;
wire [15:0] sdram_dq_out, sdram_dq_in;

sdram_wrap i_sdram (
    .clk_i (clk),
    .rst_ni(rst_n),
    .s_axil_awaddr (sdram_axil_awaddr),
    .s_axil_awprot (sdram_axil_awprot),
    .s_axil_awvalid(sdram_axil_awvalid),
    .s_axil_awready(sdram_axil_awready),
    .s_axil_wdata  (sdram_axil_wdata),
    .s_axil_wstrb  (sdram_axil_wstrb),
    .s_axil_wvalid (sdram_axil_wvalid),
    .s_axil_wready (sdram_axil_wready),
    .s_axil_bresp  (sdram_axil_bresp),
    .s_axil_bvalid (sdram_axil_bvalid),
    .s_axil_bready (sdram_axil_bready),
    .s_axil_araddr (sdram_axil_araddr),
    .s_axil_arprot (sdram_axil_arprot),
    .s_axil_arvalid(sdram_axil_arvalid),
    .s_axil_arready(sdram_axil_arready),
    .s_axil_rdata  (sdram_axil_rdata),
    .s_axil_rresp  (sdram_axil_rresp),
    .s_axil_rvalid (sdram_axil_rvalid),
    .s_axil_rready (sdram_axil_rready),
    .sdram_clk_o (sdram_clk),
    .sdram_cke_o (sdram_cke),
    .sdram_cs_o  (sdram_cs),
    .sdram_ras_o (sdram_ras),
    .sdram_cas_o (sdram_cas),
    .sdram_we_o  (sdram_we),
    .sdram_dqm_o (sdram_dqm),
    .sdram_addr_o(sdram_addr),
    .sdram_ba_o  (sdram_ba),
    .sdram_dq_o  (sdram_dq_out),
    .sdram_dq_oe_o(sdram_dq_oe),
    .sdram_dq_i  (sdram_dq_in)
);

// On-chip ADPLL array (observe-only): 12 loop-filter x DCO macros (adpll_array), each programmed
// independently over Ethernet through adpll_array_csr at 0x2000_0000 (enable/mul/div) and read
// back (lock/tune). It does NOT clock the core. Observability at the chip level is the per-PLL
// CSR STATUS over Ethernet: the gf180 analog pads (asig_5p0) cannot carry routed digital signals
// (driving a DCO clock onto them leaves the internal sink open -> LVS), so the CSR-selected
// observation mux (obs_dco_clk/obs_lock) is not brought to a pad. The 12 ring DCOs survive
// synthesis via (* keep *)/(* dont_touch *) inside each macro.
wire obs_dco_clk;
wire obs_lock;

adpll_array #(
    .NumTuneBits(7)
) i_pll_array (
    .clk_i (clk),
    .rst_ni(rst_n),
    .s_axil_awaddr (csr_axil_awaddr),
    .s_axil_awprot (csr_axil_awprot),
    .s_axil_awvalid(csr_axil_awvalid),
    .s_axil_awready(csr_axil_awready),
    .s_axil_wdata  (csr_axil_wdata),
    .s_axil_wstrb  (csr_axil_wstrb),
    .s_axil_wvalid (csr_axil_wvalid),
    .s_axil_wready (csr_axil_wready),
    .s_axil_bresp  (csr_axil_bresp),
    .s_axil_bvalid (csr_axil_bvalid),
    .s_axil_bready (csr_axil_bready),
    .s_axil_araddr (csr_axil_araddr),
    .s_axil_arprot (csr_axil_arprot),
    .s_axil_arvalid(csr_axil_arvalid),
    .s_axil_arready(csr_axil_arready),
    .s_axil_rdata  (csr_axil_rdata),
    .s_axil_rresp  (csr_axil_rresp),
    .s_axil_rvalid (csr_axil_rvalid),
    .s_axil_rready (csr_axil_rready),
    .obs_dco_clk_o (obs_dco_clk),
    .obs_lock_o    (obs_lock)
);

// Bidir pad outputs (see pad map above)
assign bidir_out[0]     = rmii_tx_en;
assign bidir_out[2:1]   = rmii_txd;
assign bidir_out[3]     = clk;            // RMII ref_clk to PHY
assign bidir_out[7:4]   = led[3:0];
assign bidir_out[23:8]  = sdram_dq_out;
assign bidir_out[24]    = sdram_clk;
assign bidir_out[25]    = sdram_cke;
assign bidir_out[26]    = sdram_cs;
assign bidir_out[27]    = sdram_ras;
assign bidir_out[28]    = sdram_cas;
assign bidir_out[29]    = sdram_we;
assign bidir_out[31:30] = sdram_dqm;
assign bidir_out[44:32] = sdram_addr;
assign bidir_out[46:45] = sdram_ba;

// Output enables: the SDRAM DQ bus is tri-stated by the controller, everything else drives.
assign bidir_oe[7:0]    = 8'hFF;
assign bidir_oe[23:8]   = {16{sdram_dq_oe}};
assign bidir_oe[46:24]  = {23{1'b1}};

assign sdram_dq_in      = bidir_in[23:8];

assign bidir_cs = '0;
assign bidir_sl = '0;
assign bidir_ie = ~bidir_oe;
assign bidir_pu = '0;
assign bidir_pd = '0;

assign input_pu = '0;
assign input_pd = '0;

logic _unused;
assign _unused = &{1'b0, led[7:4], input_in[NUM_INPUT_PADS-1:4],
                   bidir_in[7:0], bidir_in[NUM_BIDIR_PADS-1:24], analog,
                   obs_dco_clk, obs_lock};

endmodule

`default_nettype wire
