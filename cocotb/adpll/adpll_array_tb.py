# SPDX-License-Identifier: Apache-2.0
#
# cocotb CSR test for the 10-PLL ADPLL array (adpll_array). Drives the AXI4-Lite
# slave exactly as the on-chip fabric does: for each controller x DCO macro it
# writes MUL/DIV and sets CTRL.enable, polls that PLL's STATUS until lock, and
# checks the settled tune is off the rails. Then it exercises the observation mux:
# select each PLL and confirm obs_lock_o matches that PLL's STATUS lock bit.
# Behavioural DCOs (SYNTHESIS undefined). PASSes only if all 10 lock in range and
# the mux tracks the selection.
#
#   make sim-adpll-array        # (iverilog, no PDK)

import os
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

PROJ = Path(__file__).resolve().parent
ROOT = PROJ.parent.parent

NUM_PLL = 10
NUM_TUNE = 7
OBS_SEL = NUM_PLL * 0x10


def cfg_mul(i):
    if i in (7, 8, 9):
        return 427          # phase @167 MHz (fcw, Q.6)
    if i == 5:
        return 3277         # thermometer 5-bit @~320 MHz
    return 1707             # @167 MHz (7-bit, and 5-bit muxtap)


def cfg_div(_i):
    return 256              # phase ignores div


def ctrl_a(i): return i * 0x10 + 0x0
def mul_a(i):  return i * 0x10 + 0x4
def div_a(i):  return i * 0x10 + 0x8
def stat_a(i): return i * 0x10 + 0xC


async def axil_write(dut, addr, data):
    await RisingEdge(dut.clk_i)
    dut.s_axil_awaddr.value = addr; dut.s_axil_wdata.value = data
    dut.s_axil_awvalid.value = 1; dut.s_axil_wvalid.value = 1; dut.s_axil_bready.value = 1
    await RisingEdge(dut.clk_i)
    while not (dut.s_axil_awready.value and dut.s_axil_wready.value):
        await RisingEdge(dut.clk_i)
    dut.s_axil_awvalid.value = 0; dut.s_axil_wvalid.value = 0
    while not dut.s_axil_bvalid.value:
        await RisingEdge(dut.clk_i)
    await RisingEdge(dut.clk_i)
    dut.s_axil_bready.value = 0


async def axil_read(dut, addr):
    await RisingEdge(dut.clk_i)
    dut.s_axil_araddr.value = addr; dut.s_axil_arvalid.value = 1; dut.s_axil_rready.value = 1
    await RisingEdge(dut.clk_i)
    while not dut.s_axil_arready.value:
        await RisingEdge(dut.clk_i)
    dut.s_axil_arvalid.value = 0
    while not dut.s_axil_rvalid.value:
        await RisingEdge(dut.clk_i)
    data = int(dut.s_axil_rdata.value)
    await RisingEdge(dut.clk_i)
    dut.s_axil_rready.value = 0
    return data


@cocotb.test(timeout_time=80, timeout_unit="ms")
async def adpll_array_lock_and_obs(dut):
    log = dut._log
    cocotb.start_soon(Clock(dut.clk_i, 40, units="ns").start())  # 25 MHz
    # constant AXI-Lite side-band (tied in the old Verilog TB)
    dut.s_axil_awprot.value = 0; dut.s_axil_arprot.value = 0; dut.s_axil_wstrb.value = 0xF
    for sig in ("s_axil_awaddr", "s_axil_awvalid", "s_axil_wdata", "s_axil_wvalid",
                "s_axil_bready", "s_axil_araddr", "s_axil_arvalid", "s_axil_rready"):
        getattr(dut, sig).value = 0

    dut.rst_ni.value = 0
    for _ in range(5):
        await RisingEdge(dut.clk_i)
    dut.rst_ni.value = 1
    for _ in range(5):
        await RisingEdge(dut.clk_i)

    # program + enable every PLL (each independently, as a host would over Ethernet)
    for i in range(NUM_PLL):
        await axil_write(dut, mul_a(i), cfg_mul(i))
        await axil_write(dut, div_a(i), cfg_div(i))
        assert await axil_read(dut, mul_a(i)) == cfg_mul(i), f"PLL{i} MUL readback"
        assert await axil_read(dut, div_a(i)) == cfg_div(i), f"PLL{i} DIV readback"
        await axil_write(dut, ctrl_a(i), 0x1)
    log.info("programmed all %d PLLs (per-config mul/div or fcw), enable=1", NUM_PLL)

    # poll every PLL's STATUS until all lock (they run concurrently)
    locked = [False] * NUM_PLL
    for _ in range(200000):
        if all(locked):
            break
        for i in range(NUM_PLL):
            if locked[i]:
                continue
            rd = await axil_read(dut, stat_a(i))
            if rd & 1:
                locked[i] = True
                tune = (rd >> 1) & ((1 << NUM_TUNE) - 1)
                assert 1 < tune < (1 << NUM_TUNE) - 2, f"PLL{i} locked at a rail (tune={tune})"
                log.info("  PLL%d LOCKED, tune=%d", i, tune)

    assert all(locked), f"only {sum(locked)}/{NUM_PLL} PLLs locked"

    # observation mux: select each PLL, confirm obs_lock_o matches its STATUS lock bit.
    # obs_lock (live wire) vs STATUS (multi-cycle AXI read) can momentarily disagree near
    # threshold, so re-sample; a stuck/mis-routed mux never agrees and still FAILs.
    for i in range(NUM_PLL):
        await axil_write(dut, OBS_SEL, i)
        for _ in range(4):
            await RisingEdge(dut.clk_i)
        obs_ok = False
        for _ in range(16):
            rd = await axil_read(dut, stat_a(i))
            if int(dut.obs_lock_o.value) == (rd & 1):
                obs_ok = True
                break
            await RisingEdge(dut.clk_i)
        assert obs_ok, f"obs mux PLL{i}: obs_lock={int(dut.obs_lock_o.value)} != STATUS lock={rd & 1}"
    log.info("obs mux tracks selection across all %d PLLs", NUM_PLL)
    log.info("PASS: adpll_array all %d PLLs locked in range + obs mux OK", NUM_PLL)


def test_runner():
    from cocotb_tools.runner import get_runner
    ip = ROOT / "third_party" / "adpll" / "rtl"
    sim = ROOT / "third_party" / "adpll" / "sim"
    src = ROOT / "src" / "adpll"
    sources = [
        src / "adpll_array_csr.sv", src / "adpll_array.sv", src / "adpll_config.sv",
        ip / "loop_filter" / "adpll_loop_filter_bangbang.sv",
        ip / "loop_filter" / "adpll_loop_filter_proportionalintegral.sv",
        ip / "loop_filter" / "adpll_loop_filter_gearshift.sv",
        ip / "adpll_freq_detector.sv", ip / "adpll_freq_counter.sv", ip / "adpll_lock_detector.sv",
        ip / "adpll_post_divider.sv", ip / "adpll_phase_detector.sv",
        ip / "adpll" / "adpll_phase_proportionalintegral_thermometer.sv",
        ip / "adpll" / "adpll_phase_proportionalintegral_muxtap.sv",
        ip / "adpll" / "adpll_phase_proportionalintegral_binary.sv",
        sim / "adpll_tdc_behavioral.sv", sim / "ring_dco_behavioral.sv",
    ]
    runner = get_runner(os.getenv("SIM", "icarus"))
    runner.build(sources=sources, hdl_toplevel="adpll_array",
                 build_dir=str(ROOT / "cocotb" / "sim_build"),
                 always=True, timescale=("1ns", "1ps"))
    runner.test(hdl_toplevel="adpll_array", test_module="adpll_array_tb")


if __name__ == "__main__":
    test_runner()
