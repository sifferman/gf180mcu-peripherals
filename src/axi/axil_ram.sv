// SPDX-License-Identifier: Apache-2.0
//
// Simple AXI4-Lite slave RAM (flip-flop backed).
//
// A small, dependency-free 32-bit memory used as the on-chip target for the
// Ethernet UDP->memory datapath bring-up (M1).  The large/real memory is the
// external SDRAM reached through sdram_axi; this block exists so the gold path
// is provable without any macro placement.  Single outstanding transaction,
// which matches m_axil_readwrite (the only master that drives it).

`default_nettype none

module axil_ram #(
    parameter int unsigned AddrWidth = 32,
    // Depth in 32-bit words; address bits above the decoded range are ignored.
    parameter int unsigned Words     = 256
) (
    input  wire                  clk_i,
    input  wire                  rst_ni,

    input  wire [AddrWidth-1:0]  s_awaddr_i,
    input  wire [2:0]            s_awprot_i,
    input  wire                  s_awvalid_i,
    output wire                  s_awready_o,
    input  wire [31:0]           s_wdata_i,
    input  wire [3:0]            s_wstrb_i,
    input  wire                  s_wvalid_i,
    output wire                  s_wready_o,
    output wire [1:0]            s_bresp_o,
    output wire                  s_bvalid_o,
    input  wire                  s_bready_i,

    input  wire [AddrWidth-1:0]  s_araddr_i,
    input  wire [2:0]            s_arprot_i,
    input  wire                  s_arvalid_i,
    output wire                  s_arready_o,
    output wire [31:0]           s_rdata_o,
    output wire [1:0]            s_rresp_o,
    output wire                  s_rvalid_o,
    input  wire                  s_rready_i
);
    localparam int unsigned AddrLsb  = 2;
    localparam int unsigned IndexW   = $clog2(Words);

    logic [31:0] mem_q [Words];

    // Unused signals (prot, upper address bits) — tie off cleanly.
    logic _unused;
    assign _unused = &{1'b0, s_awprot_i, s_arprot_i,
                       s_awaddr_i[AddrWidth-1:AddrLsb+IndexW],
                       s_araddr_i[AddrWidth-1:AddrLsb+IndexW]};

    // ---- write channel ----
    logic        bvalid_q;
    wire         write_accept = s_awvalid_i && s_wvalid_i && (!bvalid_q || s_bready_i);
    wire [IndexW-1:0] waddr   = s_awaddr_i[AddrLsb +: IndexW];

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            bvalid_q <= 1'b0;
        end else begin
            if (write_accept)      bvalid_q <= 1'b1;
            else if (s_bready_i)   bvalid_q <= 1'b0;
        end
    end

    always_ff @(posedge clk_i) begin
        if (write_accept) begin
            for (int unsigned b_GEN = 0; b_GEN < 4; b_GEN++) begin
                if (s_wstrb_i[b_GEN]) mem_q[waddr][b_GEN*8 +: 8] <= s_wdata_i[b_GEN*8 +: 8];
            end
        end
    end

    assign s_awready_o = write_accept;
    assign s_wready_o  = write_accept;
    assign s_bvalid_o  = bvalid_q;
    assign s_bresp_o   = 2'b00; // OKAY

    // ---- read channel ----
    logic        rvalid_q;
    logic [31:0] rdata_q;
    wire         read_accept = s_arvalid_i && (!rvalid_q || s_rready_i);
    wire [IndexW-1:0] raddr   = s_araddr_i[AddrLsb +: IndexW];

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            rvalid_q <= 1'b0;
        end else begin
            if (read_accept)     rvalid_q <= 1'b1;
            else if (s_rready_i) rvalid_q <= 1'b0;
        end
        if (read_accept) rdata_q <= mem_q[raddr];
    end

    assign s_arready_o = read_accept;
    assign s_rdata_o   = rdata_q;
    assign s_rvalid_o  = rvalid_q;
    assign s_rresp_o   = 2'b00; // OKAY
endmodule

`default_nettype wire
