// This project's UDP DMA command protocol (see docs/protocol.md).
// A 10-byte header in the UDP payload, then (for writes/read-replies) the data.
// Shared by both memory servers and the command bridge.
package dma_command_pkg;

    localparam logic [7:0] DmaMagic    = 8'hA5;
    localparam logic [7:0] DmaOpWrite  = 8'h01;
    localparam logic [7:0] DmaOpRead   = 8'h02;
    localparam logic [7:0] DmaRespFlag = 8'h80;   // OR'd into the opcode in replies

    localparam int unsigned DmaHeaderBytes = 10;

    // Header byte offsets within the UDP payload.
    localparam int unsigned DmaOffMagic  = 0;
    localparam int unsigned DmaOffOpcode = 1;
    localparam int unsigned DmaOffLength = 2;   // 2 bytes, big-endian
    localparam int unsigned DmaOffAddr   = 4;   // 4 bytes, big-endian

endpackage
