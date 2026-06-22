# SPDX-FileCopyrightText: © 2025 gf180mcu-peripherals Authors
# SPDX-License-Identifier: Apache-2.0
#
# cocotb testbench for the chip's Ethernet UDP -> memory gold path (M1).
#
# Drives chip_top's RMII pins (broken out by cocotb/tb_top.sv) with a vendored,
# dependency-free subset of cocotbext-eth (cocotb/_eth) and exercises the real
# wire protocol over hand-built Ethernet frames (pure struct, no scapy / no
# cocotbext-axi), so it runs in CI with only `cocotb`:
#
#   * ARP   - host asks "who has 192.168.1.128?", expects the chip's MAC.
#   * WRITE - UDP command writes bytes into the on-chip RAM; expects an ack.
#   * READ  - UDP command reads them back; the returned datagram is checked
#             (this also verifies the WRITE, since the memory is internal).

import os
import sys
import struct
import logging
from pathlib import Path

import cocotb
from cocotb.triggers import RisingEdge, Timer, with_timeout

PROJ = Path(__file__).resolve().parent
sys.path.insert(0, str(PROJ))            # for the vendored _eth package
from _eth import RmiiPhy, GmiiFrame       # noqa: E402

# ---- environment / config ----
sim = os.getenv("SIM", "icarus")
gl = os.getenv("GL", False)
pdk_root = os.getenv("PDK_ROOT", str(PROJ / "../gf180mcu"))
pdk = os.getenv("PDK", "gf180mcuD")
scl = os.getenv("SCL", "gf180mcu_fd_sc_mcu7t5v0")
pad = os.getenv("PAD", "gf180mcu_fd_io")
sram = os.getenv("SRAM", "gf180mcu_fd_ip_sram")
slot = os.getenv("SLOT", "1x1")

hdl_toplevel = "tb_top"

# ---- design constants (match alexforencich_udp_memory_server defaults / docs/protocol.md) ----
FPGA_MAC = bytes.fromhex("02005E000102")
FPGA_IP = "192.168.1.128"
HOST_MAC = bytes.fromhex("DEADBEEF0001")
HOST_IP = "192.168.1.10"
UDP_PORT = 1234
HOST_PORT = 50000

MAGIC, OP_WRITE, OP_READ, RESP_BIT = 0xA5, 0x01, 0x02, 0x80
HDR = ">BBHIH"  # magic, opcode, len, addr, reserved (10 bytes)


# ---------------------------------------------------------------------------
# frame builders / parsers
# ---------------------------------------------------------------------------
def ip2b(s):
    return bytes(int(x) for x in s.split("."))


def checksum16(data):
    if len(data) & 1:
        data += b"\x00"
    s = sum(struct.unpack(f">{len(data) // 2}H", data))
    s = (s & 0xFFFF) + (s >> 16)
    s = (s & 0xFFFF) + (s >> 16)
    return (~s) & 0xFFFF


def eth(dst, src, ethertype, payload):
    return dst + src + struct.pack(">H", ethertype) + payload


def arp(oper, sha, spa, tha, tpa):
    return struct.pack(">HHBBH", 1, 0x0800, 6, 4, oper) + sha + ip2b(spa) + tha + ip2b(tpa)


def udp_frame(src_ip, dst_ip, sport, dport, payload):
    udp = struct.pack(">HHHH", sport, dport, 8 + len(payload), 0) + payload
    total = 20 + len(udp)
    ip = struct.pack(">BBHHHBBH", 0x45, 0, total, 0, 0, 64, 17, 0) + ip2b(src_ip) + ip2b(dst_ip)
    ip = ip[:10] + struct.pack(">H", checksum16(ip)) + ip[12:]
    return ip + udp


def parse_udp(payload):
    ihl = (payload[0] & 0x0F) * 4
    src_ip = ".".join(str(b) for b in payload[12:16])
    dst_ip = ".".join(str(b) for b in payload[16:20])
    udp = payload[ihl:]
    sport, dport, ulen, _ = struct.unpack(">HHHH", udp[:8])
    return src_ip, dst_ip, sport, dport, udp[8:ulen]


# ---------------------------------------------------------------------------
# DUT helpers
# ---------------------------------------------------------------------------
async def send_eth(phy, frame):
    await phy.rx.send(GmiiFrame.from_payload(frame))


async def recv_udp(phy, log, timeout_us=400):
    """Pull TX frames until a UDP datagram for the host arrives, answering any
    ARP request the stack emits for HOST_IP inline."""
    while True:
        rx = await with_timeout(phy.tx.recv(), timeout_us, "us")
        frame = bytes(rx.get_payload())
        ethertype = struct.unpack(">H", frame[12:14])[0]
        if ethertype == 0x0806:  # ARP from the DUT
            oper = struct.unpack(">H", frame[20:22])[0]
            tpa = ".".join(str(b) for b in frame[38:42])
            if oper == 1 and tpa == HOST_IP:
                log.info("answering DUT ARP request for %s", HOST_IP)
                await send_eth(phy, eth(FPGA_MAC, HOST_MAC, 0x0806,
                                        arp(2, HOST_MAC, HOST_IP, FPGA_MAC, FPGA_IP)))
            continue
        if ethertype == 0x0800 and frame[23] == 17:  # IPv4 + UDP
            return parse_udp(frame[14:])
        log.info("ignoring frame ethertype=%#06x", ethertype)


async def udp_write(phy, addr, data):
    hdr = struct.pack(HDR, MAGIC, OP_WRITE, len(data), addr, 0)
    await send_eth(phy, eth(FPGA_MAC, HOST_MAC, 0x0800,
                            udp_frame(HOST_IP, FPGA_IP, HOST_PORT, UDP_PORT, hdr + data)))


async def udp_read(phy, addr, length):
    hdr = struct.pack(HDR, MAGIC, OP_READ, length, addr, 0)
    await send_eth(phy, eth(FPGA_MAC, HOST_MAC, 0x0800,
                            udp_frame(HOST_IP, FPGA_IP, HOST_PORT, UDP_PORT, hdr + b"")))


@cocotb.test()
async def test_arp_write_read(dut):
    log = dut._log
    log.setLevel(logging.INFO)

    # RmiiPhy drives the 50 MHz reference clock onto clk (= clk_PAD); the chip
    # uses it for both the RMII and the core/AXI domain.
    phy = RmiiPhy(dut.txd, dut.tx_en, dut.clk, dut.rxd, dut.rx_er, dut.crs_dv)

    # reset (active low)
    dut.rst_n.value = 0
    for _ in range(20):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await Timer(3, "us")  # let the MAC/stack come out of reset

    # ---- 1) ARP : resolve the chip ----
    log.info("ARP: who-has %s", FPGA_IP)
    await send_eth(phy, eth(b"\xff" * 6, HOST_MAC, 0x0806,
                            arp(1, HOST_MAC, HOST_IP, b"\x00" * 6, FPGA_IP)))
    rx = await with_timeout(phy.tx.recv(), 400, "us")
    reply = bytes(rx.get_payload())
    assert struct.unpack(">H", reply[12:14])[0] == 0x0806, "expected ARP reply"
    oper = struct.unpack(">H", reply[20:22])[0]
    sha = reply[22:28]
    spa = ".".join(str(b) for b in reply[28:32])
    assert oper == 2 and sha == FPGA_MAC and spa == FPGA_IP, \
        f"bad ARP reply oper={oper} sha={sha.hex()} spa={spa}"
    log.info("ARP reply OK: %s is at %s", FPGA_IP, sha.hex(":"))

    # ---- 2) UDP WRITE then READ-back (verifies the whole datapath) ----
    addr = 0x40
    data = bytes((i * 7 + 3) & 0xFF for i in range(64))  # 64 bytes, word-aligned
    log.info("WRITE %d bytes @ %#x", len(data), addr)
    await udp_write(phy, addr, data)
    src_ip, _, sport, dport, ack = await recv_udp(phy, log)
    amagic, aop, alen, aaddr, _ = struct.unpack(HDR, ack[:10])
    assert (amagic, aop, aaddr) == (MAGIC, OP_WRITE | RESP_BIT, addr), \
        f"bad write ack: {ack[:10].hex()}"
    assert src_ip == FPGA_IP and sport == UDP_PORT and dport == HOST_PORT
    log.info("WRITE ack OK")

    log.info("READ %d bytes @ %#x", len(data), addr)
    await udp_read(phy, addr, len(data))
    _, _, _, _, resp = await recv_udp(phy, log)
    rmagic, rop, rlen, rraddr, _ = struct.unpack(HDR, resp[:10])
    assert (rmagic, rop, rraddr) == (MAGIC, OP_READ | RESP_BIT, addr), \
        f"bad read resp: {resp[:10].hex()}"
    assert resp[10:10 + rlen] == data, \
        f"READ-back mismatch:\n got={resp[10:10 + rlen].hex()}\n exp={data.hex()}"
    log.info("READ-back verified (%d bytes) — write+read datapath OK", rlen)

    await Timer(1, "us")
    log.info("PASS: ARP + UDP WRITE + UDP READ over RMII")


# ---------------------------------------------------------------------------
# runner
# ---------------------------------------------------------------------------
def chip_top_runner():
    from cocotb_tools.runner import get_runner

    tp = PROJ / "../third_party/alexforencich_ethernet"

    sources = [PROJ / "tb_top.sv"]
    defines = {f"SLOT_{slot.upper()}": True}
    includes = [PROJ / "../src/"]

    defines[f"PDK_{pdk.replace('-', '_')}"] = True
    defines[f"SCL_{scl}"] = True
    defines[f"PAD_{pad}"] = True
    defines[f"SRAM_{sram}"] = True

    if gl:
        sources.append(Path(pdk_root) / pdk / "libs.ref" / scl / "verilog" / f"{scl}.v")
        if scl != "gf180mcu_as_sc_mcu7t3v3":
            sources.append(Path(pdk_root) / pdk / "libs.ref" / scl / "verilog" / "primitives.v")
        sources.append(PROJ / "../final/pnl/chip_top.pnl.v")
        defines.update({"FUNCTIONAL": True, "USE_POWER_PINS": True})
    else:
        sources.append(PROJ / "../src/chip_top.sv")
        sources.append(PROJ / "../src/chip_core.sv")
        # Ethernet datapath
        sources.append(PROJ / "../src/eth/delay_to_negedge.sv")
        sources.append(PROJ / "../src/eth/m_axil_readwrite.sv")
        sources.append(PROJ / "../src/eth/udp_command_memory_bridge.sv")
        sources.append(PROJ / "../src/eth/alexforencich_udp_memory_server.sv")
        sources.append(PROJ / "../src/axi/axil_ram.sv")
        sources.append(PROJ / "../src/axi/axil_to_axi4.sv")
        sources.append(PROJ / "../src/axi/axil_interconnect.sv")
        sources.append(PROJ / "../src/sdram/sdram_wrap.sv")
        sources.append(PROJ / "../src/csr/adpll_csr.sv")
        sources.append(PROJ / "../src/adpll/adpll_freq_meas.sv")
        sources.append(PROJ / "../src/adpll/adpll_lock_detect.sv")
        sources.append(PROJ / "../src/adpll/adpll_ctrl.sv")
        sources.append(PROJ / "../src/adpll/dco/ring_dco.sv")
        _sdc = PROJ / "../third_party/ultraembedded_axi_sdram_controller/src_v"
        sources += [_sdc / "sdram_axi.v", _sdc / "sdram_axi_core.v", _sdc / "sdram_axi_pmem.v"]
        # verilog-ethernet: only modules reachable from chip_top
        sources.append(PROJ / "../third_party/alexforencich_ethernet/lib/axis/rtl/arbiter.v")
        sources.append(PROJ / "../third_party/alexforencich_ethernet/lib/axis/rtl/axis_adapter.v")
        sources.append(PROJ / "../third_party/alexforencich_ethernet/lib/axis/rtl/axis_async_fifo.v")
        sources.append(PROJ / "../third_party/alexforencich_ethernet/lib/axis/rtl/axis_async_fifo_adapter.v")
        sources.append(PROJ / "../third_party/alexforencich_ethernet/lib/axis/rtl/axis_fifo.v")
        sources.append(PROJ / "../third_party/alexforencich_ethernet/lib/axis/rtl/priority_encoder.v")
        sources.append(PROJ / "../third_party/alexforencich_ethernet/rtl/arp.v")
        sources.append(PROJ / "../third_party/alexforencich_ethernet/rtl/arp_cache.v")
        sources.append(PROJ / "../third_party/alexforencich_ethernet/rtl/arp_eth_rx.v")
        sources.append(PROJ / "../third_party/alexforencich_ethernet/rtl/arp_eth_tx.v")
        sources.append(PROJ / "../third_party/alexforencich_ethernet/rtl/axis_gmii_rx.v")
        sources.append(PROJ / "../third_party/alexforencich_ethernet/rtl/axis_gmii_tx.v")
        sources.append(PROJ / "../third_party/alexforencich_ethernet/rtl/eth_arb_mux.v")
        sources.append(PROJ / "../third_party/alexforencich_ethernet/rtl/eth_axis_rx.v")
        sources.append(PROJ / "../third_party/alexforencich_ethernet/rtl/eth_axis_tx.v")
        sources.append(PROJ / "../third_party/alexforencich_ethernet/rtl/eth_mac_1g.v")
        sources.append(PROJ / "../third_party/alexforencich_ethernet/rtl/eth_mac_rmii.v")
        sources.append(PROJ / "../third_party/alexforencich_ethernet/rtl/eth_mac_rmii_fifo.v")
        sources.append(PROJ / "../third_party/alexforencich_ethernet/rtl/ip.v")
        sources.append(PROJ / "../third_party/alexforencich_ethernet/rtl/ip_arb_mux.v")
        sources.append(PROJ / "../third_party/alexforencich_ethernet/rtl/ip_complete.v")
        sources.append(PROJ / "../third_party/alexforencich_ethernet/rtl/ip_eth_rx.v")
        sources.append(PROJ / "../third_party/alexforencich_ethernet/rtl/ip_eth_tx.v")
        sources.append(PROJ / "../third_party/alexforencich_ethernet/rtl/lfsr.v")
        sources.append(PROJ / "../third_party/alexforencich_ethernet/rtl/mac_ctrl_rx.v")
        sources.append(PROJ / "../third_party/alexforencich_ethernet/rtl/mac_ctrl_tx.v")
        sources.append(PROJ / "../third_party/alexforencich_ethernet/rtl/mac_pause_ctrl_rx.v")
        sources.append(PROJ / "../third_party/alexforencich_ethernet/rtl/mac_pause_ctrl_tx.v")
        sources.append(PROJ / "../third_party/alexforencich_ethernet/rtl/rmii_phy_if.v")
        sources.append(PROJ / "../third_party/alexforencich_ethernet/rtl/udp.v")
        sources.append(PROJ / "../third_party/alexforencich_ethernet/rtl/udp_checksum_gen.v")
        sources.append(PROJ / "../third_party/alexforencich_ethernet/rtl/udp_complete.v")
        sources.append(PROJ / "../third_party/alexforencich_ethernet/rtl/udp_ip_rx.v")
        sources.append(PROJ / "../third_party/alexforencich_ethernet/rtl/udp_ip_tx.v")

    sources += [
        Path(pdk_root) / pdk / f"libs.ref/{pad}/verilog/{pad}.v",
        PROJ / "../ip/gf180mcu_ws_ip__logo/vh/gf180mcu_ws_ip__logo.v",
        PROJ / "../ip/gf180mcu_ws_ip__marker/vh/gf180mcu_ws_ip__marker.v",
        PROJ / "../ip/gf180mcu_ws_ip__qrcode_id/vh/gf180mcu_ws_ip__qrcode_id.v",
        PROJ / "../ip/gf180mcu_ws_ip__shuttle_id/vh/gf180mcu_ws_ip__shuttle_id.v",
        PROJ / "../ip/gf180mcu_ws_ip__project_id/vh/gf180mcu_ws_ip__project_id.v",
    ]

    build_args = []
    if sim == "icarus":
        build_args = ["-g2012"]
    if sim == "verilator":
        build_args = ["--timing", "--trace", "--trace-fst", "--trace-structs"]

    runner = get_runner(sim)
    runner.build(
        sources=sources,
        hdl_toplevel=hdl_toplevel,
        defines=defines,
        always=True,
        includes=includes,
        build_args=build_args,
        waves=True,
    )
    runner.test(hdl_toplevel=hdl_toplevel,
                test_module=os.getenv("TEST_MODULE", "chip_top_tb"), waves=True)


if __name__ == "__main__":
    chip_top_runner()
