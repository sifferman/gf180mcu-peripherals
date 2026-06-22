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

// alexforencich_udp_memory_server
//
// verilog-ethernet UDP stack + udp_command_memory_bridge, presented to the board as a
// raw RMII PHY interface. Adapted from alexforencich's Arty UDP example: the native
// RMII MAC (eth_mac_rmii_fifo) drives the LAN8720 pins directly with a falling-edge TX
// retime, and the echo loop is replaced by the command bridge. Everything runs on
// clk_i; the MAC FIFO crosses to the RMII reference clock internally. Submodule and AXI
// port names are kept canonical to match the verilog-ethernet interface contract.

`default_nettype none

module alexforencich_udp_memory_server #(
    parameter              Target    = "GENERIC",
    parameter logic [47:0] LocalMac  = 48'h02_00_5E_00_01_02,
    parameter logic [31:0] LocalIp   = {8'd192, 8'd168, 8'd1, 8'd128},
    parameter logic [31:0] GatewayIp = {8'd192, 8'd168, 8'd1, 8'd1},
    parameter logic [31:0] SubnetMask= {8'd255, 8'd255, 8'd255, 8'd0},
    parameter logic [15:0] UdpPort   = 16'd1234
) (
    input  wire        clk_i,
    input  wire        rst_ni,

    // RMII PHY side (the FPGA forwards phy_rmii_ref_clk_i to the PHY)
    input  wire        phy_rmii_ref_clk_i,
    input  wire        phy_rmii_crsdv_i,
    input  wire        phy_rmii_rxer_i,
    input  wire [1:0]  phy_rmii_rxd_i,
    output wire        phy_rmii_txen_o,
    output wire [1:0]  phy_rmii_txd_o,

    // AXI4-Lite master to memory
    output wire [31:0] m_axil_awaddr,
    output wire [2:0]  m_axil_awprot,
    output wire        m_axil_awvalid,
    input  wire        m_axil_awready,
    output wire [31:0] m_axil_wdata,
    output wire [3:0]  m_axil_wstrb,
    output wire        m_axil_wvalid,
    input  wire        m_axil_wready,
    input  wire [1:0]  m_axil_bresp,
    input  wire        m_axil_bvalid,
    output wire        m_axil_bready,
    output wire [31:0] m_axil_araddr,
    output wire [2:0]  m_axil_arprot,
    output wire        m_axil_arvalid,
    input  wire        m_axil_arready,
    input  wire [31:0] m_axil_rdata,
    input  wire [1:0]  m_axil_rresp,
    input  wire        m_axil_rvalid,
    output wire        m_axil_rready,

    output wire [7:0]  led_o
);
wire rst = ~rst_ni;   // active-high reset for the imported verilog-ethernet blocks

// Native RMII MAC (eth_mac_rmii_fifo) drives the LAN8720 RMII pins directly.
// The FPGA forwards phy_rmii_ref_clk_i to the PHY, so TX is source-synchronous;
// the TX di-bits are relaunched on the falling edge of REF_CLK to meet the PHY
// setup/hold (see constraints/rmii_io_timing.xdc).
wire       rmii_txen_pre;
wire [1:0] rmii_txd_pre;

// MAC <-> AXIS
logic [7:0] rx_axis_tdata, tx_axis_tdata;
logic rx_axis_tvalid, rx_axis_tready, rx_axis_tlast, rx_axis_tuser;
logic tx_axis_tvalid, tx_axis_tready, tx_axis_tlast, tx_axis_tuser;

// AXIS <-> stack (ethernet frame)
logic rx_eth_hdr_valid, rx_eth_hdr_ready, tx_eth_hdr_valid, tx_eth_hdr_ready;
logic [47:0] rx_eth_dest_mac, rx_eth_src_mac, tx_eth_dest_mac, tx_eth_src_mac;
logic [15:0] rx_eth_type, tx_eth_type;
logic [7:0] rx_eth_payload_axis_tdata, tx_eth_payload_axis_tdata;
logic rx_eth_payload_axis_tvalid, rx_eth_payload_axis_tready, rx_eth_payload_axis_tlast, rx_eth_payload_axis_tuser;
logic tx_eth_payload_axis_tvalid, tx_eth_payload_axis_tready, tx_eth_payload_axis_tlast, tx_eth_payload_axis_tuser;

// UDP interface (stack <-> bridge)
logic rx_udp_hdr_valid, rx_udp_hdr_ready, tx_udp_hdr_valid, tx_udp_hdr_ready;
logic [47:0] rx_udp_eth_dest_mac, rx_udp_eth_src_mac;
logic [15:0] rx_udp_eth_type;
logic [3:0] rx_udp_ip_version, rx_udp_ip_ihl;
logic [5:0] rx_udp_ip_dscp, tx_udp_ip_dscp;
logic [1:0] rx_udp_ip_ecn, tx_udp_ip_ecn;
logic [15:0] rx_udp_ip_length, rx_udp_ip_identification;
logic [2:0] rx_udp_ip_flags;
logic [12:0] rx_udp_ip_fragment_offset;
logic [7:0] rx_udp_ip_ttl, tx_udp_ip_ttl, rx_udp_ip_protocol;
logic [15:0] rx_udp_ip_header_checksum;
logic [31:0] rx_udp_ip_source_ip, rx_udp_ip_dest_ip, tx_udp_ip_source_ip, tx_udp_ip_dest_ip;
logic [15:0] rx_udp_source_port, rx_udp_dest_port, rx_udp_length, rx_udp_checksum;
logic [15:0] tx_udp_source_port, tx_udp_dest_port, tx_udp_length, tx_udp_checksum;
logic [7:0] rx_udp_payload_axis_tdata, tx_udp_payload_axis_tdata;
logic rx_udp_payload_axis_tvalid, rx_udp_payload_axis_tready, rx_udp_payload_axis_tlast, rx_udp_payload_axis_tuser;
logic tx_udp_payload_axis_tvalid, tx_udp_payload_axis_tready, tx_udp_payload_axis_tlast, tx_udp_payload_axis_tuser;

// MAC status flags wired to the diagnostics below
logic rx_err_bad_frame, rx_err_bad_fcs, rx_fifo_good_frame, rx_fifo_bad_frame;
logic tx_fifo_good_frame;

eth_mac_rmii_fifo #(
    .TARGET(Target),
    .CLOCK_INPUT_STYLE("BUFG"),
    .ENABLE_PADDING(1),
    .MIN_FRAME_LENGTH(64),
    .TX_FIFO_DEPTH(1024),   // ASIC: flop-based FIFO; 4096 was ~82K FFs (FPGA BRAM).
    .TX_FRAME_FIFO(1),       // 1024 holds ~960B frames (store-and-forward).
    .RX_FIFO_DEPTH(1024),
    .RX_FRAME_FIFO(1)
) eth_mac_inst (
    .rst(rst),
    .logic_clk(clk_i),
    .logic_rst(rst),
    .tx_axis_tdata(tx_axis_tdata),
    .tx_axis_tvalid(tx_axis_tvalid),
    .tx_axis_tready(tx_axis_tready),
    .tx_axis_tlast(tx_axis_tlast),
    .tx_axis_tuser(tx_axis_tuser),
    .rx_axis_tdata(rx_axis_tdata),
    .rx_axis_tvalid(rx_axis_tvalid),
    .rx_axis_tready(rx_axis_tready),
    .rx_axis_tlast(rx_axis_tlast),
    .rx_axis_tuser(rx_axis_tuser),
    .rmii_ref_clk(phy_rmii_ref_clk_i),
    .rmii_crs_dv(phy_rmii_crsdv_i),
    .rmii_rxd(phy_rmii_rxd_i),
    .rmii_rx_er(phy_rmii_rxer_i),
    .rmii_txd(rmii_txd_pre),
    .rmii_tx_en(rmii_txen_pre),
    .tx_fifo_overflow(),
    .tx_fifo_bad_frame(),
    .tx_fifo_good_frame(tx_fifo_good_frame),
    .rx_error_bad_frame(rx_err_bad_frame),
    .rx_error_bad_fcs(rx_err_bad_fcs),
    .rx_fifo_overflow(),
    .rx_fifo_bad_frame(rx_fifo_bad_frame),
    .rx_fifo_good_frame(rx_fifo_good_frame),
    .cfg_ifg(8'd12),
    .cfg_tx_enable(1'b1),
    .cfg_rx_enable(1'b1),
    .speed(2'b01)                      // 100 Mb/s (LAN8720A links at 100M FD)
);

// TX di-bits relaunched on the falling edge of REF_CLK (board source-sync timing)
delay_to_negedge #(.Width(3)) u_tx_negedge (
    .clk_i(phy_rmii_ref_clk_i),
    .d_i({rmii_txen_pre, rmii_txd_pre}),
    .q_o({phy_rmii_txen_o, phy_rmii_txd_o})
);

eth_axis_rx eth_axis_rx_inst (
    .clk(clk_i),
    .rst(rst),
    .s_axis_tdata(rx_axis_tdata),
    .s_axis_tvalid(rx_axis_tvalid),
    .s_axis_tready(rx_axis_tready),
    .s_axis_tlast(rx_axis_tlast),
    .s_axis_tuser(rx_axis_tuser),
    .m_eth_hdr_valid(rx_eth_hdr_valid),
    .m_eth_hdr_ready(rx_eth_hdr_ready),
    .m_eth_dest_mac(rx_eth_dest_mac),
    .m_eth_src_mac(rx_eth_src_mac),
    .m_eth_type(rx_eth_type),
    .m_eth_payload_axis_tdata(rx_eth_payload_axis_tdata),
    .m_eth_payload_axis_tvalid(rx_eth_payload_axis_tvalid),
    .m_eth_payload_axis_tready(rx_eth_payload_axis_tready),
    .m_eth_payload_axis_tlast(rx_eth_payload_axis_tlast),
    .m_eth_payload_axis_tuser(rx_eth_payload_axis_tuser),
    .busy(),
    .error_header_early_termination()
);

eth_axis_tx eth_axis_tx_inst (
    .clk(clk_i),
    .rst(rst),
    .s_eth_hdr_valid(tx_eth_hdr_valid),
    .s_eth_hdr_ready(tx_eth_hdr_ready),
    .s_eth_dest_mac(tx_eth_dest_mac),
    .s_eth_src_mac(tx_eth_src_mac),
    .s_eth_type(tx_eth_type),
    .s_eth_payload_axis_tdata(tx_eth_payload_axis_tdata),
    .s_eth_payload_axis_tvalid(tx_eth_payload_axis_tvalid),
    .s_eth_payload_axis_tready(tx_eth_payload_axis_tready),
    .s_eth_payload_axis_tlast(tx_eth_payload_axis_tlast),
    .s_eth_payload_axis_tuser(tx_eth_payload_axis_tuser),
    .m_axis_tdata(tx_axis_tdata),
    .m_axis_tvalid(tx_axis_tvalid),
    .m_axis_tready(tx_axis_tready),
    .m_axis_tlast(tx_axis_tlast),
    .m_axis_tuser(tx_axis_tuser),
    .busy()
);

// UDP TX checksum is left 0 (disabled, legal IPv4) by udp_command_memory_bridge, so the
// checksum generator (a 2048-deep payload FIFO) is not needed.
// ARP_CACHE_ADDR_WIDTH=2 (4 entries): a test chip talks to ~1 host; the default
// 512-entry cache was ~41K flip-flops. (Also the wide arp hash; see arp_cache patch.)
udp_complete #(
    .UDP_CHECKSUM_GEN_ENABLE(0),
    .ARP_CACHE_ADDR_WIDTH   (2)
) udp_complete_inst (
    .clk(clk_i),
    .rst(rst),
    .s_eth_hdr_valid(rx_eth_hdr_valid),
    .s_eth_hdr_ready(rx_eth_hdr_ready),
    .s_eth_dest_mac(rx_eth_dest_mac),
    .s_eth_src_mac(rx_eth_src_mac),
    .s_eth_type(rx_eth_type),
    .s_eth_payload_axis_tdata(rx_eth_payload_axis_tdata),
    .s_eth_payload_axis_tvalid(rx_eth_payload_axis_tvalid),
    .s_eth_payload_axis_tready(rx_eth_payload_axis_tready),
    .s_eth_payload_axis_tlast(rx_eth_payload_axis_tlast),
    .s_eth_payload_axis_tuser(rx_eth_payload_axis_tuser),
    .m_eth_hdr_valid(tx_eth_hdr_valid),
    .m_eth_hdr_ready(tx_eth_hdr_ready),
    .m_eth_dest_mac(tx_eth_dest_mac),
    .m_eth_src_mac(tx_eth_src_mac),
    .m_eth_type(tx_eth_type),
    .m_eth_payload_axis_tdata(tx_eth_payload_axis_tdata),
    .m_eth_payload_axis_tvalid(tx_eth_payload_axis_tvalid),
    .m_eth_payload_axis_tready(tx_eth_payload_axis_tready),
    .m_eth_payload_axis_tlast(tx_eth_payload_axis_tlast),
    .m_eth_payload_axis_tuser(tx_eth_payload_axis_tuser),
    .s_ip_hdr_valid(1'b0),
    .s_ip_dscp(0),
    .s_ip_ecn(0),
    .s_ip_length(0),
    .s_ip_ttl(0),
    .s_ip_protocol(0),
    .s_ip_source_ip(0),
    .s_ip_dest_ip(0),
    .s_ip_payload_axis_tdata(0),
    .s_ip_payload_axis_tvalid(1'b0),
    .s_ip_payload_axis_tlast(1'b0),
    .s_ip_payload_axis_tuser(1'b0),
    .m_ip_hdr_ready(1'b1),
    .m_ip_payload_axis_tready(1'b1),
    .m_udp_hdr_valid(rx_udp_hdr_valid),
    .m_udp_hdr_ready(rx_udp_hdr_ready),
    .m_udp_eth_dest_mac(rx_udp_eth_dest_mac),
    .m_udp_eth_src_mac(rx_udp_eth_src_mac),
    .m_udp_eth_type(rx_udp_eth_type),
    .m_udp_ip_version(rx_udp_ip_version),
    .m_udp_ip_ihl(rx_udp_ip_ihl),
    .m_udp_ip_dscp(rx_udp_ip_dscp),
    .m_udp_ip_ecn(rx_udp_ip_ecn),
    .m_udp_ip_length(rx_udp_ip_length),
    .m_udp_ip_identification(rx_udp_ip_identification),
    .m_udp_ip_flags(rx_udp_ip_flags),
    .m_udp_ip_fragment_offset(rx_udp_ip_fragment_offset),
    .m_udp_ip_ttl(rx_udp_ip_ttl),
    .m_udp_ip_protocol(rx_udp_ip_protocol),
    .m_udp_ip_header_checksum(rx_udp_ip_header_checksum),
    .m_udp_ip_source_ip(rx_udp_ip_source_ip),
    .m_udp_ip_dest_ip(rx_udp_ip_dest_ip),
    .m_udp_source_port(rx_udp_source_port),
    .m_udp_dest_port(rx_udp_dest_port),
    .m_udp_length(rx_udp_length),
    .m_udp_checksum(rx_udp_checksum),
    .m_udp_payload_axis_tdata(rx_udp_payload_axis_tdata),
    .m_udp_payload_axis_tvalid(rx_udp_payload_axis_tvalid),
    .m_udp_payload_axis_tready(rx_udp_payload_axis_tready),
    .m_udp_payload_axis_tlast(rx_udp_payload_axis_tlast),
    .m_udp_payload_axis_tuser(rx_udp_payload_axis_tuser),
    .s_udp_hdr_valid(tx_udp_hdr_valid),
    .s_udp_hdr_ready(tx_udp_hdr_ready),
    .s_udp_ip_dscp(tx_udp_ip_dscp),
    .s_udp_ip_ecn(tx_udp_ip_ecn),
    .s_udp_ip_ttl(tx_udp_ip_ttl),
    .s_udp_ip_source_ip(tx_udp_ip_source_ip),
    .s_udp_ip_dest_ip(tx_udp_ip_dest_ip),
    .s_udp_source_port(tx_udp_source_port),
    .s_udp_dest_port(tx_udp_dest_port),
    .s_udp_length(tx_udp_length),
    .s_udp_checksum(tx_udp_checksum),
    .s_udp_payload_axis_tdata(tx_udp_payload_axis_tdata),
    .s_udp_payload_axis_tvalid(tx_udp_payload_axis_tvalid),
    .s_udp_payload_axis_tready(tx_udp_payload_axis_tready),
    .s_udp_payload_axis_tlast(tx_udp_payload_axis_tlast),
    .s_udp_payload_axis_tuser(tx_udp_payload_axis_tuser),
    .ip_rx_busy(),
    .ip_tx_busy(),
    .udp_rx_busy(),
    .udp_tx_busy(),
    .ip_rx_error_header_early_termination(),
    .ip_rx_error_payload_early_termination(),
    .ip_rx_error_invalid_header(),
    .ip_rx_error_invalid_checksum(),
    .ip_tx_error_payload_early_termination(),
    .ip_tx_error_arp_failed(),
    .udp_rx_error_header_early_termination(),
    .udp_rx_error_payload_early_termination(),
    .udp_tx_error_payload_early_termination(),
    .local_mac(LocalMac),
    .local_ip(LocalIp),
    .gateway_ip(GatewayIp),
    .subnet_mask(SubnetMask),
    .clear_arp_cache(1'b0)
);

assign tx_udp_ip_source_ip = LocalIp;

udp_command_memory_bridge #(.UdpPort(UdpPort)) bridge_inst (
    .clk_i,
    .rst_ni(rst_ni),
    .rx_udp_hdr_valid(rx_udp_hdr_valid),
    .rx_udp_hdr_ready(rx_udp_hdr_ready),
    .rx_udp_ip_source_ip(rx_udp_ip_source_ip),
    .rx_udp_source_port(rx_udp_source_port),
    .rx_udp_dest_port(rx_udp_dest_port),
    .rx_udp_length(rx_udp_length),
    .rx_udp_payload_axis_tdata(rx_udp_payload_axis_tdata),
    .rx_udp_payload_axis_tvalid(rx_udp_payload_axis_tvalid),
    .rx_udp_payload_axis_tready(rx_udp_payload_axis_tready),
    .rx_udp_payload_axis_tlast(rx_udp_payload_axis_tlast),
    .rx_udp_payload_axis_tuser(rx_udp_payload_axis_tuser),
    .tx_udp_hdr_valid(tx_udp_hdr_valid),
    .tx_udp_hdr_ready(tx_udp_hdr_ready),
    .tx_udp_ip_dscp(tx_udp_ip_dscp),
    .tx_udp_ip_ecn(tx_udp_ip_ecn),
    .tx_udp_ip_ttl(tx_udp_ip_ttl),
    .tx_udp_ip_dest_ip(tx_udp_ip_dest_ip),
    .tx_udp_source_port(tx_udp_source_port),
    .tx_udp_dest_port(tx_udp_dest_port),
    .tx_udp_length(tx_udp_length),
    .tx_udp_checksum(tx_udp_checksum),
    .tx_udp_payload_axis_tdata(tx_udp_payload_axis_tdata),
    .tx_udp_payload_axis_tvalid(tx_udp_payload_axis_tvalid),
    .tx_udp_payload_axis_tready(tx_udp_payload_axis_tready),
    .tx_udp_payload_axis_tlast(tx_udp_payload_axis_tlast),
    .tx_udp_payload_axis_tuser(tx_udp_payload_axis_tuser),
    .m_axil_awaddr,
    .m_axil_awprot,
    .m_axil_awvalid,
    .m_axil_awready,
    .m_axil_wdata,
    .m_axil_wstrb,
    .m_axil_wvalid,
    .m_axil_wready,
    .m_axil_bresp,
    .m_axil_bvalid,
    .m_axil_bready,
    .m_axil_araddr,
    .m_axil_arprot,
    .m_axil_arvalid,
    .m_axil_arready,
    .m_axil_rdata,
    .m_axil_rresp,
    .m_axil_rvalid,
    .m_axil_rready
);

// ---- bring-up diagnostics ----
// LD0 heartbeat (board alive); LD1..LD4 sticky event latches that localize
// an RX/TX problem.  Each latch is set in its source clock domain and read
// asynchronously for the LED (metastability is fine for a light).
logic [25:0] hb_d, hb_q;
always_comb hb_d = hb_q + 1'b1;
always_ff @(posedge clk_i) begin
    if (!rst_ni) hb_q <= '0;
    else         hb_q <= hb_d;
end

// Sticky event latches: each is set-and-hold (q | event). rx_err_bad_fcs is the RMII-timing
// tell, synced to clk_i by the MAC FIFO.
logic rx_good_sticky_d,   rx_good_sticky_q;    // good frame reached the stack
logic rx_drop_sticky_d,   rx_drop_sticky_q;    // frame dropped
logic tx_good_sticky_d,   tx_good_sticky_q;    // we sent a good frame
logic rx_badfcs_sticky_d, rx_badfcs_sticky_q;  // bad FCS seen
always_comb begin
    rx_good_sticky_d   = rx_good_sticky_q   | rx_fifo_good_frame;
    rx_drop_sticky_d   = rx_drop_sticky_q   | rx_fifo_bad_frame;
    tx_good_sticky_d   = tx_good_sticky_q   | tx_fifo_good_frame;
    rx_badfcs_sticky_d = rx_badfcs_sticky_q | rx_err_bad_fcs;
end
always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
        rx_good_sticky_q   <= 1'b0;
        rx_drop_sticky_q   <= 1'b0;
        tx_good_sticky_q   <= 1'b0;
        rx_badfcs_sticky_q <= 1'b0;
    end else begin
        rx_good_sticky_q   <= rx_good_sticky_d;
        rx_drop_sticky_q   <= rx_drop_sticky_d;
        tx_good_sticky_q   <= tx_good_sticky_d;
        rx_badfcs_sticky_q <= rx_badfcs_sticky_d;
    end
end

// LD0 heartbeat | LD1 good RX | LD2 bad-FCS RX | LD3 dropped RX | LD4 good TX
assign led_o = {3'b0, tx_good_sticky_q, rx_drop_sticky_q, rx_badfcs_sticky_q,
                rx_good_sticky_q, hb_q[25]};
endmodule


`default_nettype wire
