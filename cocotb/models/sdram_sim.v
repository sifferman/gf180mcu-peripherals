// SPDX-License-Identifier: Apache-2.0
//
// Small open behavioral SDR-SDRAM model for Icarus/CI simulation of the
// ultraembedded sdram_axi controller (W9825G6KH geometry: 13-row/9-col/2-bank,
// x16). It is NOT timing-accurate — it implements just enough of the JEDEC SDR
// command set (ACTIVE / READ / WRITE / PRECHARGE / REFRESH / LOAD_MODE) for the
// controller's fixed mode (CAS latency 2, burst length 2, sequential) so a
// write-then-read-back over the AXI port verifies functionally.
//
// The cycle-accurate, sign-off model is the encrypted Winbond W9825G6KH .vp
// (VCS/Questa/NC only) under cocotb/sdram/ — use that with SIM=vcs.

`default_nettype none

module sdram_sim #(
    parameter ROW_W = 13,
    parameter COL_W = 9,
    parameter CAS   = 2,
    parameter IDX_W = 18           // backing array size = 2^IDX_W 16-bit words
) (
    input  wire        Clk,
    input  wire        Cke,
    input  wire        Cs_n,
    input  wire        Ras_n,
    input  wire        Cas_n,
    input  wire        We_n,
    input  wire [1:0]  Ba,
    input  wire [12:0] Addr,
    input  wire [1:0]  Dqm,
    inout  wire [15:0] Dq
);
    // JEDEC command encoding {Cs_n,Ras_n,Cas_n,We_n}
    localparam [3:0] CMD_LOAD_MODE = 4'b0000;
    localparam [3:0] CMD_REFRESH   = 4'b0001;
    localparam [3:0] CMD_PRECHARGE = 4'b0010;
    localparam [3:0] CMD_ACTIVE    = 4'b0011;
    localparam [3:0] CMD_WRITE     = 4'b0100;
    localparam [3:0] CMD_READ      = 4'b0101;
    localparam [3:0] CMD_NOP       = 4'b0111;

    wire [3:0] cmd = {Cs_n, Ras_n, Cas_n, We_n};
    wire       sel = Cke;

    reg [15:0] mem [0:(1<<IDX_W)-1];
    reg [ROW_W-1:0] open_row [0:3];

    // Map {bank,row,col} -> backing index (any 1:1-ish function works: the
    // controller presents the same decode for the same AXI address on wr & rd).
    function [IDX_W-1:0] idx;
        input [1:0]       ba;
        input [ROW_W-1:0] row;
        input [COL_W-1:0] col;
        idx = {ba, row, col} & ((1<<IDX_W)-1);
    endfunction

    // ---- write burst (beat0 coincident with CMD_WRITE, beat1 next cycle) ----
    reg               wr_active;
    reg [IDX_W-1:0]   wr_idx;
    reg [1:0]         wr_dqm;

    // ---- read burst pipeline (CAS latency, burst length 2) ----
    reg [15:0]        rd_d0, rd_d1;
    reg [CAS:0]       rd_pipe;     // rd_pipe[CAS-1] -> drive beat0, [CAS] -> beat1

    integer i;
    initial begin
        wr_active = 1'b0;
        rd_pipe   = 0;
        for (i = 0; i < 4; i = i + 1) open_row[i] = 0;
    end

    always @(posedge Clk) begin
        // default: advance read pipe
        rd_pipe <= {rd_pipe[CAS-1:0], 1'b0};

        if (sel) begin
            // ---- write burst continuation (NOP cycle after WRITE) ----
            if (wr_active) begin
                if (!Dqm[0]) mem[wr_idx][7:0]  <= Dq[7:0];
                if (!Dqm[1]) mem[wr_idx][15:8] <= Dq[15:8];
                wr_active <= 1'b0;
            end

            case (cmd)
                CMD_ACTIVE: open_row[Ba] <= Addr[ROW_W-1:0];

                CMD_WRITE: begin
                    // beat0 now, beat1 next cycle (col+1)
                    if (!Dqm[0]) mem[idx(Ba, open_row[Ba], Addr[COL_W-1:0])][7:0]  <= Dq[7:0];
                    if (!Dqm[1]) mem[idx(Ba, open_row[Ba], Addr[COL_W-1:0])][15:8] <= Dq[15:8];
                    wr_idx    <= idx(Ba, open_row[Ba], Addr[COL_W-1:0]) + 1'b1;
                    wr_active <= 1'b1;
                end

                CMD_READ: begin
                    rd_d0      <= mem[idx(Ba, open_row[Ba], Addr[COL_W-1:0])];
                    rd_d1      <= mem[idx(Ba, open_row[Ba], Addr[COL_W-1:0]) + 1'b1];
                    rd_pipe[0] <= 1'b1;
                end
                default: ; // NOP / REFRESH / PRECHARGE / LOAD_MODE: no array effect
            endcase
        end
    end

    // Drive Dq during the two read-data beats (CAS=2: beat0 at rd_pipe[CAS-1],
    // beat1 one cycle later at rd_pipe[CAS]).
    wire drive_b0 = rd_pipe[CAS-1];
    wire drive_b1 = rd_pipe[CAS];
    assign Dq = drive_b0 ? rd_d0 : (drive_b1 ? rd_d1 : 16'hzzzz);

endmodule

`default_nettype wire
