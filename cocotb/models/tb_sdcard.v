// SPDX-License-Identifier: GPL-3.0-only
// Block-level functional test of src/sdcard/sdcard_file_to_led (the ASIC split-IO version): drive it
// against WangXuan95's sd_fake SD-card model (GPLv3) backed by a FAT32 image (sd_rom_image.vh). The
// reader must find example.txt and present its first two bytes 'H','e' on led_o = 16'h4865. The split
// CMD (o/oe/i) is recombined into the inout the model expects, exactly as the chip's gf180 pad does.
`timescale 1ns/1ps
module tb_sdcard;
    reg clk = 1'b0, rstn = 1'b0;
    always #20 clk = ~clk;                 // 25 MHz (matches sd_fake)
    initial begin repeat (4) @(posedge clk); rstn <= 1'b1; end

    tri         sdcmd;
    wire [3:0]  sddat;
    wire [15:0] led;
    wire        sdclk, sd_cmd_o, sd_cmd_oe;

    assign sdcmd = sd_cmd_oe ? sd_cmd_o : 1'bz;   // chip drives CMD when oe (the pad resolves this)
    sdcard_file_to_led #(.SIMULATE(1'b1), .CLK_DIV(3'd2)) dut (
        .clk_i(clk), .rstn_i(rstn), .sd_reset_o(),
        .sd_sck_o(sdclk), .sd_cmd_o(sd_cmd_o), .sd_cmd_oe(sd_cmd_oe), .sd_cmd_i(sdcmd),
        .sd_dat0_i(sddat[0]), .sd_cd_i(1'b0), .led_o(led));

    wire        rom_req;
    wire [39:0] rom_addr;
    reg  [15:0] rom_data;
    sd_fake sd_fake_i (
        .rstn_async(rstn), .sdclk(sdclk), .sdcmd(sdcmd), .sddat(sddat),
        .rdreq(rom_req), .rdaddr(rom_addr), .rddata(rom_data),
        .show_status_bits(), .show_sdcmd_en(), .show_sdcmd_cmd(), .show_sdcmd_arg());
    always @(posedge sdclk)
        if (rom_req)
            case (rom_addr)
                `include "sd_rom_image.vh"
            endcase

    localparam [15:0] EXPECTED = 16'h4865;   // 'H','e' (head of "Hello world!")
    integer i;
    initial begin
        $display("SD: waiting for card init + 2-byte file read...");
        for (i = 0; i < 8_000_000 && led !== EXPECTED; i = i + 1) @(posedge clk);
        if (led !== EXPECTED) $display("FAIL: SD led=%04h expected %04h", led, EXPECTED);
        else                  $display("PASS: SD reads example.txt head -> led=%04h ('H','e')", led);
        $finish;
    end
endmodule
