# SPDX-License-Identifier: Apache-2.0
#
# cocotb test: M2 on-chip fabric -- AXI4-Lite master -> axil_interconnect ->
# { axil_ram (slave0, low region), sdram_wrap -> sdram_axi -> sdram_model
# (slave1, addr bit 28 = 1) }. Verifies address decode, the AXI4-Lite<->AXI4
# adapter, and the SDRAM path.
#
#   make sim-fabric        # (iverilog, no PDK)

import os
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

PROJ = Path(__file__).resolve().parent
ROOT = PROJ.parent.parent


async def _init(dut):
    cocotb.start_soon(Clock(dut.clk, 20, units="ns").start())  # 50 MHz
    for sig in ("awaddr", "awvalid", "wdata", "wstrb", "wvalid", "bready",
                "araddr", "arvalid", "rready"):
        getattr(dut, sig).value = 0
    dut.rst_n.value = 0
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    for _ in range(7000):   # SDRAM power-up/init
        await RisingEdge(dut.clk)


async def wr(dut, addr, data):
    await RisingEdge(dut.clk)
    dut.awaddr.value = addr; dut.awvalid.value = 1
    dut.wdata.value = data; dut.wstrb.value = 0xF; dut.wvalid.value = 1; dut.bready.value = 1
    await RisingEdge(dut.clk)
    while not (dut.awready.value and dut.wready.value):
        await RisingEdge(dut.clk)
    dut.awvalid.value = 0; dut.wvalid.value = 0
    while not dut.bvalid.value:
        await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.bready.value = 0


async def rd(dut, addr):
    await RisingEdge(dut.clk)
    dut.araddr.value = addr; dut.arvalid.value = 1; dut.rready.value = 1
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


@cocotb.test(timeout_time=3, timeout_unit="ms")
async def fabric_decode_and_datapath(dut):
    log = dut._log
    await _init(dut)

    # slave0: scratch RAM (sel bit 28 = 0)
    await wr(dut, 0x0000_0040, 0x1234_5678)
    got = await rd(dut, 0x0000_0040)
    assert got == 0x1234_5678, f"SRAM @0x40: {got:08x}"
    log.info("OK SRAM  @0x40 = %08x", got)

    # slave1: SDRAM (addr bit 28 = 1)
    await wr(dut, 0x1000_0040, 0xCAFE_BABE)
    await wr(dut, 0x1000_0044, 0xDEAD_BEEF)
    got = await rd(dut, 0x1000_0040)
    assert got == 0xCAFE_BABE, f"SDRAM @0x40: {got:08x}"
    log.info("OK SDRAM @0x40 = %08x", got)
    got = await rd(dut, 0x1000_0044)
    assert got == 0xDEAD_BEEF, f"SDRAM @0x44: {got:08x}"
    log.info("OK SDRAM @0x44 = %08x", got)

    log.info("PASS: M2 fabric (interconnect + SRAM + SDRAM)")


def test_runner():
    from cocotb_tools.runner import get_runner
    ctrl = ROOT / "third_party" / "ultraembedded_axi_sdram_controller" / "src_v"
    sources = [
        PROJ / "fabric_harness.sv",
        ROOT / "src" / "axi" / "axil_ram.sv",
        ROOT / "src" / "axi" / "axil_to_axi4.sv",
        ROOT / "src" / "axi" / "axil_interconnect.sv",
        ROOT / "src" / "sdram" / "sdram_wrap.sv",
        ctrl / "sdram_axi.v",
        ctrl / "sdram_axi_core.v",
        ctrl / "sdram_axi_pmem.v",
        ROOT / "cocotb" / "sdram" / "sdram_model.v",
    ]
    runner = get_runner(os.getenv("SIM", "icarus"))
    runner.build(sources=sources, hdl_toplevel="fabric_harness",
                 build_dir=str(ROOT / "cocotb" / "sim_build"),
                 always=True, timescale=("1ns", "1ps"))
    runner.test(hdl_toplevel="fabric_harness", test_module="fabric_tb")


if __name__ == "__main__":
    test_runner()
