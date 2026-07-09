# SPDX-License-Identifier: GPL-3.0-only
#
# cocotb test: src/sdcard/sdcard_file_to_led (ASIC split-IO reader) against
# WangXuan95's sd_fake model + a FAT32 image (sd_rom_image.vh). The reader must
# find example.txt and present its first two bytes 'H','e' on led = 0x4865.
#
#   make sim-sdcard        # (iverilog, no PDK)

import os
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

PROJ = Path(__file__).resolve().parent
ROOT = PROJ.parent.parent

EXPECTED = 0x4865   # 'H','e' (head of "Hello world!")


@cocotb.test(timeout_time=100, timeout_unit="ms")
async def sdcard_file_to_led(dut):
    log = dut._log
    cocotb.start_soon(Clock(dut.clk, 40, units="ns").start())  # 25 MHz (matches sd_fake)

    dut.rstn.value = 0
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rstn.value = 1

    log.info("SD: waiting for card init + 2-byte file read (SIMULATE=1)...")
    # coarse polling: the SD power-up/mount/read runs in HDL between samples
    while int(dut.led.value) != EXPECTED:
        await Timer(5, units="us")

    assert int(dut.led.value) == EXPECTED, f"SD led={int(dut.led.value):04x} expected {EXPECTED:04x}"
    log.info("PASS: SD reads example.txt head -> led=%04x ('H','e')", int(dut.led.value))


def test_runner():
    from cocotb_tools.runner import get_runner
    src = ROOT / "src" / "sdcard"
    sources = [
        PROJ / "sdcard_harness.sv",
        src / "sdcard_file_to_led.v",
        src / "sd_file_reader.sv",
        src / "sd_reader.sv",
        src / "sdcmd_ctrl.sv",
        ROOT / "third_party" / "wangxuan95_sdcard" / "SIM" / "sd_fake.v",
    ]
    runner = get_runner(os.getenv("SIM", "icarus"))
    runner.build(sources=sources, hdl_toplevel="sdcard_harness",
                 includes=[PROJ],   # sd_rom_image.vh
                 build_dir=str(ROOT / "cocotb" / "sim_build"),
                 always=True, timescale=("1ns", "1ps"))
    runner.test(hdl_toplevel="sdcard_harness", test_module="sdcard_tb")


if __name__ == "__main__":
    test_runner()
