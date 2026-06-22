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

// udp_command_memory_bridge
//
// Bridges a udp_complete UDP interface to AXI4-Lite: it parses the DMA command
// protocol (docs/protocol.md) out of the RX UDP payload, performs the reads/writes
// through m_axil_readwrite, and streams the reply back out the TX UDP payload. UDP/IP
// checksums are produced upstream, so this only sets tx_udp_length and the payload
// bytes; the first payload byte is memory byte 0 (AXI wdata[7:0]). The rx_udp_*/tx_udp_*
// names are the fixed udp_complete interface contract, so they stay canonical.

`default_nettype none

module udp_command_memory_bridge #(
    parameter logic [15:0] UdpPort = 16'd1234
) (
    input  wire        clk_i,
    input  wire        rst_ni,

    // ---- RX UDP (from udp_complete) ----
    input  wire        rx_udp_hdr_valid,
    output wire        rx_udp_hdr_ready,
    input  wire [31:0] rx_udp_ip_source_ip,
    input  wire [15:0] rx_udp_source_port,
    input  wire [15:0] rx_udp_dest_port,
    input  wire [15:0] rx_udp_length,
    input  wire [7:0]  rx_udp_payload_axis_tdata,
    input  wire        rx_udp_payload_axis_tvalid,
    output wire        rx_udp_payload_axis_tready,
    input  wire        rx_udp_payload_axis_tlast,
    input  wire        rx_udp_payload_axis_tuser,

    // ---- TX UDP (to udp_complete) ----
    output wire        tx_udp_hdr_valid,
    input  wire        tx_udp_hdr_ready,
    output wire [5:0]  tx_udp_ip_dscp,
    output wire [1:0]  tx_udp_ip_ecn,
    output wire [7:0]  tx_udp_ip_ttl,
    output wire [31:0] tx_udp_ip_dest_ip,
    output wire [15:0] tx_udp_source_port,
    output wire [15:0] tx_udp_dest_port,
    output wire [15:0] tx_udp_length,
    output wire [15:0] tx_udp_checksum,
    output wire [7:0]  tx_udp_payload_axis_tdata,
    output wire        tx_udp_payload_axis_tvalid,
    input  wire        tx_udp_payload_axis_tready,
    output wire        tx_udp_payload_axis_tlast,
    output wire        tx_udp_payload_axis_tuser,

    // ---- AXI4-Lite master to memory ----
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
    output wire        m_axil_rready
);
// DMA command protocol constants (was dma_command_pkg; inlined so the design
// needs no SystemVerilog package — keeps the default yosys frontend happy).
localparam logic [7:0]  DmaMagic       = 8'hA5;
localparam logic [7:0]  DmaOpWrite     = 8'h01;
localparam logic [7:0]  DmaOpRead      = 8'h02;
localparam logic [7:0]  DmaRespFlag    = 8'h80;   // OR'd into the opcode in replies
localparam int unsigned DmaHeaderBytes = 10;

// ---- command / reply state ----
logic [7:0]  opcode_d, opcode_q;
logic [15:0] cmd_len_d, cmd_len_q;
logic [31:0] cmd_addr_d, cmd_addr_q;
logic [3:0]  hdr_cnt_d, hdr_cnt_q;       // RX header byte counter (0..9)
logic [15:0] byte_cnt_d, byte_cnt_q;     // data byte counter
logic [1:0]  lane_d, lane_q;             // byte lane within a word (0..3)
logic [31:0] word_d, word_q;             // assembling / holding word
logic [3:0]  tx_cnt_d, tx_cnt_q;         // TX header byte counter

// Registered interface outputs (interface contract -> canonical port names).
logic        rx_hdr_ready_d, rx_hdr_ready_q;
logic        rx_ready_d, rx_ready_q;
logic        tx_hdr_valid_d, tx_hdr_valid_q;
logic        tx_valid_d, tx_valid_q;
logic        tx_last_d, tx_last_q;
logic [7:0]  tx_data_d, tx_data_q;
logic [31:0] dest_ip_d, dest_ip_q;
logic [15:0] src_port_d, src_port_q;
logic [15:0] dst_port_d, dst_port_q;
logic [15:0] udp_len_d, udp_len_q;

typedef enum logic [3:0] {
    S_IDLE,
    S_HDR,
    S_WDATA,
    S_WMEM,
    S_WWAIT,
    S_DRAIN,
    S_THDR,
    S_TXH,
    S_RREQ,
    S_RWAIT,
    S_TXD
} state_e;
state_e state_d, state_q;

// ---- memory master (m_axil_readwrite request/read channels) ----
logic        mem_request_ready, mem_read_valid;
logic [31:0] mem_read_rdata;
logic        mem_request_valid, mem_request_write, mem_read_ready;
logic [31:0] mem_request_addr;

always_comb begin
    mem_request_valid = (state_q == S_WMEM) || (state_q == S_RREQ);
    mem_request_write = (state_q == S_WMEM);
    mem_request_addr  = (state_q == S_WMEM) ? cmd_addr_q + {16'h0, byte_cnt_q - 16'd4}
                                            : cmd_addr_q + {16'h0, byte_cnt_q};
    mem_read_ready    = (state_q == S_RWAIT);
end

m_axil_readwrite #(
    .AddrWidth(32)
) u_mem (
    .clk_i,
    .rst_ni,
    .request_valid_i(mem_request_valid),
    .request_ready_o(mem_request_ready),
    .request_write_not_read_i(mem_request_write),
    .request_addr_i(mem_request_addr),
    .request_wdata_i(word_q),
    .read_valid_o(mem_read_valid),
    .read_ready_i(mem_read_ready),
    .read_rdata_o(mem_read_rdata),
    .m_axil_awaddr(m_axil_awaddr),
    .m_axil_awprot(m_axil_awprot),
    .m_axil_awvalid(m_axil_awvalid),
    .m_axil_awready(m_axil_awready),
    .m_axil_wdata(m_axil_wdata),
    .m_axil_wstrb(m_axil_wstrb),
    .m_axil_wvalid(m_axil_wvalid),
    .m_axil_wready(m_axil_wready),
    .m_axil_bresp(m_axil_bresp),
    .m_axil_bvalid(m_axil_bvalid),
    .m_axil_bready(m_axil_bready),
    .m_axil_araddr(m_axil_araddr),
    .m_axil_arprot(m_axil_arprot),
    .m_axil_arvalid(m_axil_arvalid),
    .m_axil_arready(m_axil_arready),
    .m_axil_rdata(m_axil_rdata),
    .m_axil_rresp(m_axil_rresp),
    .m_axil_rvalid(m_axil_rvalid),
    .m_axil_rready(m_axil_rready)
);

wire is_rd = (opcode_q == DmaOpRead);
wire [15:0] reply_paylen = 16'(DmaHeaderBytes) + (is_rd ? cmd_len_q : 16'd0);

// Reply header byte at TX position t (0..9).
function automatic logic [7:0] reply_byte(logic [3:0] t);
    case (t)
        4'd0: reply_byte = DmaMagic;
        4'd1: reply_byte = opcode_q | DmaRespFlag;
        4'd2: reply_byte = cmd_len_q[15:8];   4'd3: reply_byte = cmd_len_q[7:0];
        4'd4: reply_byte = cmd_addr_q[31:24]; 4'd5: reply_byte = cmd_addr_q[23:16];
        4'd6: reply_byte = cmd_addr_q[15:8];  4'd7: reply_byte = cmd_addr_q[7:0];
        default: reply_byte = 8'h00;          // reserved
    endcase
endfunction

always_comb begin
    state_d        = state_q;
    opcode_d       = opcode_q;
    cmd_len_d      = cmd_len_q;
    cmd_addr_d     = cmd_addr_q;
    hdr_cnt_d      = hdr_cnt_q;
    byte_cnt_d     = byte_cnt_q;
    lane_d         = lane_q;
    word_d         = word_q;
    tx_cnt_d       = tx_cnt_q;
    rx_hdr_ready_d = rx_hdr_ready_q;
    rx_ready_d     = rx_ready_q;
    tx_hdr_valid_d = tx_hdr_valid_q;
    tx_valid_d     = tx_valid_q;
    tx_last_d      = tx_last_q;
    tx_data_d      = tx_data_q;
    dest_ip_d      = dest_ip_q;
    src_port_d     = src_port_q;
    dst_port_d     = dst_port_q;
    udp_len_d      = udp_len_q;

    unique case (state_q)
        S_IDLE: begin
            tx_valid_d = 1'b0;
            tx_last_d  = 1'b0;
            if (rx_udp_hdr_valid) begin
                rx_hdr_ready_d = 1'b1;            // accept header (1 cycle)
                dest_ip_d      = rx_udp_ip_source_ip;
                src_port_d     = rx_udp_dest_port;
                dst_port_d     = rx_udp_source_port;
                hdr_cnt_d      = '0;
                byte_cnt_d     = '0;
                lane_d         = '0;
                rx_ready_d     = 1'b1;
                if (rx_udp_dest_port == UdpPort) state_d = S_HDR;
                else                             state_d = S_DRAIN;
            end
        end
        S_HDR: begin
            rx_hdr_ready_d = 1'b0;
            if (rx_udp_payload_axis_tvalid && rx_ready_q) begin
                case (hdr_cnt_q)
                    4'd1: opcode_d         = rx_udp_payload_axis_tdata;
                    4'd2: cmd_len_d[15:8]  = rx_udp_payload_axis_tdata;
                    4'd3: cmd_len_d[7:0]   = rx_udp_payload_axis_tdata;
                    4'd4: cmd_addr_d[31:24]= rx_udp_payload_axis_tdata;
                    4'd5: cmd_addr_d[23:16]= rx_udp_payload_axis_tdata;
                    4'd6: cmd_addr_d[15:8] = rx_udp_payload_axis_tdata;
                    4'd7: cmd_addr_d[7:0]  = rx_udp_payload_axis_tdata;
                    default: ; // 0 magic, 8/9 reserved
                endcase
                if (rx_udp_payload_axis_tlast) begin
                    rx_ready_d = 1'b0; state_d = S_THDR;       // no data -> READ/short
                end else if (hdr_cnt_q == 4'd9) begin
                    if (opcode_q == DmaOpWrite) begin
                        byte_cnt_d = '0; lane_d = '0; state_d = S_WDATA;
                    end else begin
                        rx_ready_d = 1'b0; state_d = S_THDR;
                    end
                end else begin
                    hdr_cnt_d = hdr_cnt_q + 1'b1;
                end
            end
        end
        // ---- WRITE: stream payload bytes into memory words ----
        S_WDATA: if (rx_udp_payload_axis_tvalid && rx_ready_q) begin
            word_d[{lane_q, 3'b000} +: 8] = rx_udp_payload_axis_tdata;
            if (lane_q == 2'd3) begin
                rx_ready_d = 1'b0;                 // pause stream to write
                state_d    = S_WMEM;
            end
            lane_d     = lane_q + 1'b1;
            byte_cnt_d = byte_cnt_q + 1'b1;
        end
        S_WMEM:  if (mem_request_ready) state_d = S_WWAIT;   // write accepted
        S_WWAIT: if (mem_request_ready) begin                // write done
            if (byte_cnt_q >= cmd_len_q) begin
                state_d = S_THDR;
            end else begin
                rx_ready_d = 1'b1; state_d = S_WDATA;
            end
        end
        S_DRAIN: begin   // consume remaining bytes to tlast, then reply/ignore
            rx_ready_d = 1'b1;
            if (rx_udp_payload_axis_tvalid && rx_udp_payload_axis_tlast) begin
                rx_ready_d = 1'b0;
                if (dst_port_q == UdpPort) state_d = S_THDR;
                else                       state_d = S_IDLE;
            end
        end
        // ---- build reply ----
        S_THDR: begin
            udp_len_d      = 16'd8 + reply_paylen;   // UDP hdr + payload
            tx_hdr_valid_d = 1'b1;
            if (tx_hdr_valid_q && tx_udp_hdr_ready) begin
                tx_hdr_valid_d = 1'b0;
                tx_cnt_d       = '0;
                lane_d         = '0;
                byte_cnt_d     = '0;
                tx_data_d      = reply_byte(4'd0);
                tx_valid_d     = 1'b1;
                tx_last_d      = (reply_paylen == 16'd1);
                state_d        = S_TXH;
            end
        end
        S_TXH: if (tx_udp_payload_axis_tready) begin
            if (tx_cnt_q == 4'd9) begin
                tx_valid_d = 1'b0;
                if (is_rd) begin
                    state_d = S_RREQ;
                end else begin
                    tx_last_d = 1'b0; state_d = S_IDLE;
                end
            end else begin
                tx_cnt_d   = tx_cnt_q + 1'b1;
                tx_data_d  = reply_byte(tx_cnt_q + 4'd1);
                tx_valid_d = 1'b1;
                // header-only reply (write ack): byte 9 is the last byte
                if (!is_rd && tx_cnt_q == 4'd8) tx_last_d = 1'b1;
            end
        end
        // ---- READ data: fetch word, stream 4 bytes ----
        S_RREQ:  if (mem_request_ready) state_d = S_RWAIT;   // read accepted
        S_RWAIT: if (mem_read_valid) begin
            word_d     = mem_read_rdata;
            lane_d     = '0;
            tx_data_d  = mem_read_rdata[7:0];
            tx_valid_d = 1'b1;
            tx_last_d  = (byte_cnt_q + 16'd1 >= cmd_len_q);
            state_d    = S_TXD;
        end
        S_TXD: if (tx_udp_payload_axis_tready) begin
            byte_cnt_d = byte_cnt_q + 1'b1;
            if (byte_cnt_q + 16'd1 >= cmd_len_q) begin   // last byte just sent
                tx_valid_d = 1'b0; tx_last_d = 1'b0; state_d = S_IDLE;
            end else if (lane_q == 2'd3) begin
                tx_valid_d = 1'b0; state_d = S_RREQ;     // next word
            end else begin
                lane_d    = lane_q + 1'b1;
                tx_data_d = word_q[{(lane_q + 2'd1), 3'b000} +: 8];
                tx_last_d = (byte_cnt_q + 16'd2 >= cmd_len_q);
            end
        end
        default: state_d = S_IDLE;
    endcase
end

always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
        state_q        <= S_IDLE;
        rx_hdr_ready_q <= 1'b0;
        rx_ready_q     <= 1'b0;
        tx_hdr_valid_q <= 1'b0;
        tx_valid_q     <= 1'b0;
        tx_last_q      <= 1'b0;
        hdr_cnt_q      <= '0;
        byte_cnt_q     <= '0;
        lane_q         <= '0;
        tx_cnt_q       <= '0;
    end else begin
        state_q        <= state_d;
        rx_hdr_ready_q <= rx_hdr_ready_d;
        rx_ready_q     <= rx_ready_d;
        tx_hdr_valid_q <= tx_hdr_valid_d;
        tx_valid_q     <= tx_valid_d;
        tx_last_q      <= tx_last_d;
        hdr_cnt_q      <= hdr_cnt_d;
        byte_cnt_q     <= byte_cnt_d;
        lane_q         <= lane_d;
        tx_cnt_q       <= tx_cnt_d;
    end
    // data-path registers: loaded before use, no reset
    opcode_q   <= opcode_d;
    cmd_len_q  <= cmd_len_d;
    cmd_addr_q <= cmd_addr_d;
    word_q     <= word_d;
    tx_data_q  <= tx_data_d;
    dest_ip_q  <= dest_ip_d;
    src_port_q <= src_port_d;
    dst_port_q <= dst_port_d;
    udp_len_q  <= udp_len_d;
end

assign rx_udp_hdr_ready           = rx_hdr_ready_q;
assign rx_udp_payload_axis_tready = rx_ready_q;
assign tx_udp_hdr_valid           = tx_hdr_valid_q;
assign tx_udp_payload_axis_tvalid = tx_valid_q;
assign tx_udp_payload_axis_tlast  = tx_last_q;
assign tx_udp_payload_axis_tdata  = tx_data_q;
assign tx_udp_ip_dest_ip          = dest_ip_q;
assign tx_udp_source_port         = src_port_q;
assign tx_udp_dest_port           = dst_port_q;
assign tx_udp_length              = udp_len_q;

assign tx_udp_ip_dscp            = 6'd0;
assign tx_udp_ip_ecn             = 2'd0;
assign tx_udp_ip_ttl             = 8'd64;
assign tx_udp_checksum           = 16'd0;   // UDP checksum disabled (legal IPv4)
assign tx_udp_payload_axis_tuser = 1'b0;
endmodule


`default_nettype wire
