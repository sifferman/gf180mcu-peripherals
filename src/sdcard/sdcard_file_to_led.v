// SPDX-License-Identifier: BSD-3-Clause
//
// sdcard_file_to_led: read the first two bytes of a file off a FAT16/FAT32 SD
// card and present them on the 16 LEDs ({byte0, byte1}) -- e.g. a file starting
// with "EF" lights 0x4546.
//
// Wraps WangXuan95's GPLv3 sd_file_reader (third_party/wangxuan95_sdcard), so the
// synthesized design is a GPL combined work (see the sdcard-branch NOTICE). This
// file is BSD-3-Clause and stays individually reusable.
//
// Nexys A7 SD slot notes:
//  - SD_RESET held low keeps the slot powered (P-FET Q8).
//  - DAT3/2/1 are driven high to keep the card in SD native (not SPI) mode
//    (per WangXuan95's own Nexys4-DDR demo).
//  - The CMD line is bidirectional: the block design MUST be synthesized
//    in-context (vivado.tcl sets synth_checkpoint_mode None) so SD_CMD infers a
//    bidirectional IOBUF, not an always-driving OBUF. With an OBUF the FPGA holds
//    the line and the card can never send its response.

module sdcard_file_to_led #(
    parameter       SIMULATE = 0,      // 1 in sim: skip the card power-up wait
    parameter [2:0] CLK_DIV  = 3'd2    // clk = 50 MHz -> CLK_DIV = 2
) (
    input  wire        clk_i,          // 50 MHz
    input  wire        rstn_i,         // active-low reset (CPU_RESETN)

    output wire        sd_reset_o,     // low = slot powered
    output wire        sd_sck_o,
    inout  wire        sd_cmd_io,
    inout  wire [3:0]  sd_dat_io,      // DAT0 = data in; DAT3/2/1 driven high
    input  wire        sd_cd_i,        // card-detect (low = card present)

    output wire [15:0] led_o
);

    // Keep the card in SD native mode, and power the slot.
    assign sd_dat_io[3:1] = 3'b111;
    assign sd_dat_io[0]   = 1'bz;
    wire   sddat0         = sd_dat_io[0];
    assign sd_reset_o     = 1'b0;

    // Release the reader once a card is present and stable (~84 ms @ 50 MHz);
    // re-init automatically on (re)insertion.
    wire       card_present = ~sd_cd_i;
    reg [22:0] settle = 23'd0;
    always @(posedge clk_i) begin
        if (!rstn_i || !card_present) settle <= 23'd0;
        else if (!settle[22])         settle <= settle + 23'd1;
    end
    wire rstn = rstn_i & (SIMULATE ? 1'b1 : (card_present & settle[22]));

    // SD file reader (GPLv3).
    wire       outen;
    wire [7:0] outbyte;
    sd_file_reader #(
        .FILE_NAME_LEN ( 11            ),
        .FILE_NAME     ( "example.txt" ),
        .CLK_DIV       ( CLK_DIV       ),
        .SIMULATE      ( SIMULATE      )
    ) u_reader (
        .rstn            ( rstn      ),
        .clk             ( clk_i     ),
        .sdclk           ( sd_sck_o  ),
        .sdcmd           ( sd_cmd_io ),
        .sddat0          ( sddat0    ),
        .card_stat       (           ),
        .card_type       (           ),
        .filesystem_type (           ),
        .file_found      (           ),
        .outen           ( outen     ),
        .outbyte         ( outbyte   )
    );

    // Latch the file's first two bytes.
    reg [7:0] byte0 = 8'h0;
    reg [7:0] byte1 = 8'h0;
    reg [1:0] idx   = 2'd0;
    always @(posedge clk_i) begin
        if (!rstn) begin
            byte0 <= 8'h0; byte1 <= 8'h0; idx <= 2'd0;
        end else if (outen && idx != 2'd2) begin
            if (idx == 2'd0) byte0 <= outbyte;
            else             byte1 <= outbyte;
            idx <= idx + 2'd1;
        end
    end

    assign led_o = {byte0, byte1};  // byte0 -> LED[15:8], byte1 -> LED[7:0]

endmodule
