# SPDX-License-Identifier: Apache-2.0
#
# cocotb test: ultraembedded sdram_axi controller + open behavioral sdram_model.
# Writes two words over AXI4 and reads them back (functional check of the SDR
# command sequence: ACTIVE/READ/WRITE/PRECHARGE/REFRESH at CL2, burst 2).
#
#   make sim-sdram        # (delegates here; iverilog, no PDK)

import os
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

PROJ = Path(__file__).resolve().parent
ROOT = PROJ.parent.parent


async def _init(dut):
    """Start the 50 MHz clock, zero all AXI inputs, and release reset after the
    controller's power-up/init settles."""
    cocotb.start_soon(Clock(dut.clk, 20, units="ns").start())  # 50 MHz
    for sig in ("awvalid", "awaddr", "awid", "awlen", "wvalid", "wdata", "wstrb",
                "wlast", "bready", "arvalid", "araddr", "arid", "arlen", "rready"):
        getattr(dut, sig).value = 0
    dut.awburst.value = 1
    dut.arburst.value = 1
    dut.rst.value = 1
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    # let the controller finish its ~100 us power-up/init
    for _ in range(7000):
        await RisingEdge(dut.clk)


async def axi_write(dut, addr, data):
    # this controller accepts AW and W on the same cycle (sdram_axi_pmem)
    await RisingEdge(dut.clk)
    dut.awaddr.value = addr; dut.awid.value = 0; dut.awlen.value = 0
    dut.awburst.value = 1; dut.awvalid.value = 1
    dut.wdata.value = data; dut.wstrb.value = 0xF; dut.wlast.value = 1
    dut.wvalid.value = 1; dut.bready.value = 1
    await RisingEdge(dut.clk)
    while not (dut.awready.value and dut.wready.value):
        await RisingEdge(dut.clk)
    dut.awvalid.value = 0; dut.wvalid.value = 0
    while not dut.bvalid.value:
        await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.bready.value = 0


async def axi_read(dut, addr):
    await RisingEdge(dut.clk)
    dut.araddr.value = addr; dut.arid.value = 0; dut.arlen.value = 0
    dut.arburst.value = 1; dut.arvalid.value = 1; dut.rready.value = 1
    await RisingEdge(dut.clk)
    while not dut.arready.value:
        await RisingEdge(dut.clk)
    dut.arvalid.value = 0
    while not dut.rvalid.value:
        await RisingEdge(dut.clk)
    data = int(dut.rdata.value)
    await RisingEdge(dut.clk)
    dut.rready.value = 0
    return data


@cocotb.test(timeout_time=2, timeout_unit="ms")
async def sdram_write_readback(dut):
    log = dut._log
    await _init(dut)

    await axi_write(dut, 0x0000_0100, 0xDEAD_BEEF)
    await axi_write(dut, 0x0000_0104, 0xCAFE_F00D)

    got = await axi_read(dut, 0x0000_0100)
    assert got == 0xDEAD_BEEF, f"@0x100: got {got:08x} exp DEADBEEF"
    log.info("OK   @0x100 = %08x", got)

    got = await axi_read(dut, 0x0000_0104)
    assert got == 0xCAFE_F00D, f"@0x104: got {got:08x} exp CAFEF00D"
    log.info("OK   @0x104 = %08x", got)

    log.info("PASS: SDRAM write/read-back")


def test_runner():
    from cocotb_tools.runner import get_runner
    ctrl = ROOT / "third_party" / "ultraembedded_axi_sdram_controller" / "src_v"
    sources = [
        PROJ / "sdram_harness.sv",
        ctrl / "sdram_axi.v",
        ctrl / "sdram_axi_core.v",
        ctrl / "sdram_axi_pmem.v",
        PROJ / "sdram_model.v",
    ]
    runner = get_runner(os.getenv("SIM", "icarus"))
    runner.build(sources=sources, hdl_toplevel="sdram_harness",
                 build_dir=str(ROOT / "cocotb" / "sim_build"),
                 always=True, timescale=("1ns", "1ps"))
    runner.test(hdl_toplevel="sdram_harness", test_module="sdram_tb")


if __name__ == "__main__":
    test_runner()
