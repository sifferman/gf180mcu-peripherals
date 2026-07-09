// SPDX-License-Identifier: Apache-2.0
//
// Simulation wrapper: breaks the RMII / LED signals out of chip_top's pad vectors
// so cocotb (cocotbext-eth RmiiPhy) can drive them. Used for RTL (`make sim`) and
// gate-level (`make sim-gl`). Pad map must match src/chip_core.sv (M2: 5 input,
// 47 bidir). The SDRAM pads (bidir[8..46]) are left unconnected here — the gold-path
// test exercises the on-chip scratch RAM region; the SDRAM datapath is covered by
// cocotb/models/tb_m2_fabric.v.

`default_nettype none

module tb_top (
    input  wire        clk,      // = clk_PAD (50 MHz RMII ref / core clock)
    input  wire        rst_n,    // = rst_n_PAD
    input  wire        crs_dv,
    input  wire        rx_er,
    input  wire [1:0]  rxd,
    input  wire        mode_strap,  // 0 = normal (Ethernet/SDRAM datapath); 1 = SD-card file-to-LED
    output wire        tx_en,
    output wire [1:0]  txd,
    output wire        ref_clk,
    output wire [3:0]  leds,
    output wire [15:0] sd_led_obs   // SD mode: reconstructed 16-bit file value on the muxed pads
);
    wire [4:0]  input_PAD;
    wire [46:0] bidir_PAD;
    wire [1:0]  analog_PAD;

    // Drive DUT input pads. input_PAD[4]=mode strap; input_PAD[0]=RMII crs_dv (normal) / SD card-detect
    // (SD mode: 0 = card present, matching sd_cd_i convention).
    assign input_PAD[0]   = mode_strap ? 1'b0 : crs_dv;
    assign input_PAD[1]   = rx_er;
    assign input_PAD[3:2] = rxd;
    assign input_PAD[4]   = mode_strap;

    // Observe DUT bidir pads.
    assign tx_en   = bidir_PAD[0];
    assign txd     = bidir_PAD[2:1];
    assign ref_clk = bidir_PAD[3];
    assign leds    = bidir_PAD[7:4];
    // SD mode: the 16-bit file value is split across the muxed pads (chip_core):
    //   sd_led[3:0] -> bidir_PAD[7:4],  sd_led[15:4] -> bidir_PAD[19:8].  Reconstruct it.
    assign sd_led_obs = {bidir_PAD[19:8], bidir_PAD[7:4]};

`ifdef USE_POWER_PINS
    wire VDD, VSS, DVDD, DVSS;
    assign VDD  = 1'b1;
    assign DVDD = 1'b1;
    assign VSS  = 1'b0;
    assign DVSS = 1'b0;
`endif

    chip_top dut (
`ifdef USE_POWER_PINS
        .VDD   (VDD),
        .VSS   (VSS),
        .DVDD  (DVDD),
        .DVSS  (DVSS),
`endif
        .clk_PAD    (clk),
        .rst_n_PAD  (rst_n),
        .input_PAD  (input_PAD),
        .bidir_PAD  (bidir_PAD),
        .analog_PAD (analog_PAD)
    );

    // Open behavioural SDRAM on the SDRAM pads (bidir[8..46]) so a chip-top test can write/read
    // external SDRAM (0x1000_0000) over Ethernet. Pad map matches src/chip_core.sv: DQ[23:8],
    // clk[24], cke[25], cs[26], ras[27], cas[28], we[29], dqm[31:30], addr[44:32], ba[46:45].
`ifndef GL
    sdram_sim sdram_model (
        .Clk  (bidir_PAD[24]),
        .Cke  (bidir_PAD[25]),
        .Cs_n (bidir_PAD[26]),
        .Ras_n(bidir_PAD[27]),
        .Cas_n(bidir_PAD[28]),
        .We_n (bidir_PAD[29]),
        .Dqm  (bidir_PAD[31:30]),
        .Ba   (bidir_PAD[46:45]),
        .Addr (bidir_PAD[44:32]),
        .Dq   (bidir_PAD[23:8])
    );
`endif

    // --- SD-card model on the muxed SD pads (WangXuan95 sd_fake + FAT32 ROM image) ----------------
    // Active ONLY in SD mode: rstn_async = mode_strap, so in normal mode sd_fake is held in reset and
    // its sdcmd/sddat outputs are tri-stated (sdcmdoe/sddatoe=0) -> fully inert, no contention with the
    // Ethernet/SDRAM datapath on the shared pads. SD pads (chip_core map): bidir[0]=SCK, [1]=CMD
    // (bidir; chip drives when sd_cmd_oe, model otherwise), [2]=DAT0 (chip OE off in SD mode -> model
    // drives it). ROM backing: sd_fake requests 16-bit words, served from sd_rom_image.vh on SCK.
    wire [3:0]  sd_dat_bus;
    wire        sd_rom_req;
    wire [39:0] sd_rom_addr;
    reg  [15:0] rom_data;   // name fixed by sd_rom_image.vh case items ("rom_data <= ...")
    sd_fake sd_fake_i (
        .rstn_async (mode_strap),
        .sdclk      (bidir_PAD[0]),
        .sdcmd      (bidir_PAD[1]),
        .sddat      (sd_dat_bus),
        .rdreq      (sd_rom_req),
        .rdaddr     (sd_rom_addr),
        .rddata     (rom_data),
        .show_status_bits (),
        .show_sdcmd_en    (),
        .show_sdcmd_cmd   (),
        .show_sdcmd_arg   ()
    );
    // DAT0: model drives in SD mode (sd_dat_bus[0]); tri-z in normal mode -> chip's pad drives it.
    assign bidir_PAD[2] = sd_dat_bus[0];
    always @(posedge bidir_PAD[0])
        if (sd_rom_req)
            case (sd_rom_addr)
                `include "sd_rom_image.vh"
            endcase

endmodule

`default_nettype wire
