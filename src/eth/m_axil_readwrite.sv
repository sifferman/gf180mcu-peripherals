// Single-beat AXI4-Lite master with two ready/valid channels.
//
//   Request channel  (sink):   present a read or write command.
//   Read channel     (source): returns the data of a *read* command.
//
// A write completes when request_ready_o rises again (the master returns to
// idle); it produces no read-channel beat.  A read drives read_valid_o with
// read_rdata_o until the consumer accepts it with read_ready_i.  Only one
// command is in flight at a time (request_ready_o is high only when idle).
//
// AXI port names are kept canonical (no _i/_o) so a block design infers the AXI
// interface; they are driven from internal _q registers.

module m_axil_readwrite #(
    parameter int unsigned AddrWidth = 32
) (
    input  wire                  clk_i,
    input  wire                  rst_ni,

    // request channel (accepted when request_valid_i && request_ready_o)
    input  wire                  request_valid_i,
    output wire                  request_ready_o,
    input  wire                  request_write_not_read_i,
    input  wire [AddrWidth-1:0]  request_addr_i,
    input  wire [31:0]           request_wdata_i,

    // read-data channel (valid only for read commands)
    output wire                  read_valid_o,
    input  wire                  read_ready_i,
    output wire [31:0]           read_rdata_o,

    output wire [AddrWidth-1:0]  m_axi_awaddr,
    output wire [2:0]            m_axi_awprot,
    output wire                  m_axi_awvalid,
    input  wire                  m_axi_awready,
    output wire [31:0]           m_axi_wdata,
    output wire [3:0]            m_axi_wstrb,
    output wire                  m_axi_wvalid,
    input  wire                  m_axi_wready,
    input  wire [1:0]            m_axi_bresp,
    input  wire                  m_axi_bvalid,
    output wire                  m_axi_bready,
    output wire [AddrWidth-1:0]  m_axi_araddr,
    output wire [2:0]            m_axi_arprot,
    output wire                  m_axi_arvalid,
    input  wire                  m_axi_arready,
    input  wire [31:0]           m_axi_rdata,
    input  wire [1:0]            m_axi_rresp,
    input  wire                  m_axi_rvalid,
    output wire                  m_axi_rready
);
    typedef enum logic [1:0] {
        S_IDLE,
        S_WRITE,
        S_READ,
        S_READ_RESP
    } state_e;
    state_e state_d, state_q;

    logic [AddrWidth-1:0] awaddr_d,  awaddr_q;
    logic                 awvalid_d, awvalid_q;
    logic [31:0]          wdata_d,   wdata_q;
    logic                 wvalid_d,  wvalid_q;
    logic                 bready_d,  bready_q;
    logic [AddrWidth-1:0] araddr_d,  araddr_q;
    logic                 arvalid_d, arvalid_q;
    logic                 rready_d,  rready_q;
    logic [31:0]          rdata_d,   rdata_q;

    always_comb begin
        state_d   = state_q;
        awaddr_d  = awaddr_q;
        awvalid_d = awvalid_q;
        wdata_d   = wdata_q;
        wvalid_d  = wvalid_q;
        bready_d  = bready_q;
        araddr_d  = araddr_q;
        arvalid_d = arvalid_q;
        rready_d  = rready_q;
        rdata_d   = rdata_q;

        unique case (state_q)
            S_IDLE: if (request_valid_i) begin
                if (request_write_not_read_i) begin
                    awaddr_d = request_addr_i; awvalid_d = 1'b1;
                    wdata_d  = request_wdata_i; wvalid_d = 1'b1;
                    bready_d = 1'b1;
                    state_d  = S_WRITE;
                end else begin
                    araddr_d = request_addr_i; arvalid_d = 1'b1;
                    rready_d = 1'b1;
                    state_d  = S_READ;
                end
            end
            S_WRITE: begin
                if (awvalid_q && m_axi_awready) awvalid_d = 1'b0;
                if (wvalid_q  && m_axi_wready ) wvalid_d  = 1'b0;
                if (m_axi_bvalid) begin
                    bready_d = 1'b0;
                    state_d  = S_IDLE;
                end
            end
            S_READ: begin
                if (arvalid_q && m_axi_arready) arvalid_d = 1'b0;
                if (m_axi_rvalid) begin
                    rdata_d  = m_axi_rdata;
                    rready_d = 1'b0;
                    state_d  = S_READ_RESP;
                end
            end
            S_READ_RESP: if (read_ready_i) state_d = S_IDLE;
            default: state_d = S_IDLE;
        endcase
    end

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            state_q   <= S_IDLE;
            awvalid_q <= 1'b0;
            wvalid_q  <= 1'b0;
            bready_q  <= 1'b0;
            arvalid_q <= 1'b0;
            rready_q  <= 1'b0;
        end else begin
            state_q   <= state_d;
            awvalid_q <= awvalid_d;
            wvalid_q  <= wvalid_d;
            bready_q  <= bready_d;
            arvalid_q <= arvalid_d;
            rready_q  <= rready_d;
        end
        // data-path: loaded before use, no reset
        awaddr_q <= awaddr_d;
        wdata_q  <= wdata_d;
        araddr_q <= araddr_d;
        rdata_q  <= rdata_d;
    end

    assign request_ready_o = (state_q == S_IDLE);
    assign read_valid_o    = (state_q == S_READ_RESP);
    assign read_rdata_o    = rdata_q;

    assign m_axi_awaddr  = awaddr_q;
    assign m_axi_awvalid = awvalid_q;
    assign m_axi_wdata   = wdata_q;
    assign m_axi_wvalid  = wvalid_q;
    assign m_axi_bready  = bready_q;
    assign m_axi_araddr  = araddr_q;
    assign m_axi_arvalid = arvalid_q;
    assign m_axi_rready  = rready_q;
    assign m_axi_wstrb   = 4'hf;
    assign m_axi_awprot  = 3'b000;
    assign m_axi_arprot  = 3'b000;
endmodule
