# SPDX-FileCopyrightText: © 2025 gf180mcu-peripherals Authors
# SPDX-License-Identifier: Apache-2.0
#
# Cocotb UDP-socket bridge: lets the UNMODIFIED host tool (ethernet-host/dma.py)
# drive the *simulated* chip. A real UDP socket on localhost is bridged into the
# simulated RMII MAC: datagrams from dma.py are wrapped in Ethernet/IP/UDP and
# injected via cocotbext-eth's RmiiPhy; the chip's UDP replies are unwrapped and
# sent back to dma.py. ARP requests the chip emits are answered automatically.
#
#   Terminal 1:  make sim-bridge          # prints "BRIDGE listening on 127.0.0.1:<port>"
#   Terminal 2:  python ethernet-host/dma.py --ip 127.0.0.1 --port <port> test --size 256
#
# This is wall-clock-slow (it's a gate-faithful RMII sim), so use small sizes.

import os
import sys
import socket
import struct
import logging
import threading
import queue
from pathlib import Path

import cocotb
from cocotb.triggers import RisingEdge, Timer, with_timeout

PROJ = Path(__file__).resolve().parent
sys.path.insert(0, str(PROJ))
from _eth import RmiiPhy, GmiiFrame  # noqa: E402
# Reuse the wire-format helpers from the main testbench.
from chip_top_tb import (  # noqa: E402
    eth, arp, udp_frame, parse_udp, FPGA_MAC, FPGA_IP, HOST_MAC, HOST_IP, UDP_PORT,
)

BRIDGE_IP = os.getenv("BRIDGE_IP", "127.0.0.1")
BRIDGE_PORT = int(os.getenv("BRIDGE_PORT", "0"))  # 0 = ephemeral


class UdpServer(threading.Thread):
    """Background UDP socket. Inbound datagrams -> rx queue; reply via send()."""

    def __init__(self):
        super().__init__(daemon=True)
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind((BRIDGE_IP, BRIDGE_PORT))
        self.sock.settimeout(0.2)
        self.rx = queue.Queue()
        self.client = None
        self._stop = threading.Event()

    @property
    def port(self):
        return self.sock.getsockname()[1]

    def run(self):
        while not self._stop.is_set():
            try:
                data, addr = self.sock.recvfrom(2048)
            except socket.timeout:
                continue
            except OSError:
                break
            self.client = addr
            self.rx.put(data)

    def send(self, data):
        if self.client:
            self.sock.sendto(data, self.client)

    def stop(self):
        self._stop.set()
        self.sock.close()


async def _answer_arp(phy, frame, log):
    ethertype = struct.unpack(">H", frame[12:14])[0]
    if ethertype == 0x0806:
        oper = struct.unpack(">H", frame[20:22])[0]
        tpa = ".".join(str(b) for b in frame[38:42])
        if oper == 1 and tpa == HOST_IP:
            await phy.rx.send(GmiiFrame.from_payload(
                eth(FPGA_MAC, HOST_MAC, 0x0806, arp(2, HOST_MAC, HOST_IP, FPGA_MAC, FPGA_IP))))
        return True
    return False


@cocotb.test()
async def bridge(dut):
    log = dut._log
    log.setLevel(logging.INFO)

    phy = RmiiPhy(dut.txd, dut.tx_en, dut.clk, dut.rxd, dut.rx_er, dut.crs_dv)
    dut.rst_n.value = 0
    for _ in range(20):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await Timer(3, "us")

    srv = UdpServer()
    srv.start()
    log.info("BRIDGE listening on %s:%d  (run: python ethernet-host/dma.py --ip %s --port %d ...)",
             BRIDGE_IP, srv.port, BRIDGE_IP, srv.port)

    # Resolve us once so the chip has our MAC cached for replies.
    await phy.rx.send(GmiiFrame.from_payload(
        eth(b"\xff" * 6, HOST_MAC, 0x0806, arp(1, HOST_MAC, HOST_IP, b"\x00" * 6, FPGA_IP))))

    idle = 0
    while idle < int(os.getenv("BRIDGE_IDLE_TICKS", "20000")):
        try:
            payload = srv.rx.get_nowait()
        except queue.Empty:
            await RisingEdge(dut.clk)
            idle += 1
            continue
        idle = 0
        # host datagram -> chip
        await phy.rx.send(GmiiFrame.from_payload(
            eth(FPGA_MAC, HOST_MAC, 0x0800,
                udp_frame(HOST_IP, FPGA_IP, 50000, UDP_PORT, payload))))
        # chip reply -> host (answer any ARP the chip emits first)
        while True:
            rx = await with_timeout(phy.tx.recv(), 400, "us")
            frame = bytes(rx.get_payload())
            if await _answer_arp(phy, frame, log):
                continue
            if struct.unpack(">H", frame[12:14])[0] == 0x0800 and frame[23] == 17:
                _, _, _, _, data = parse_udp(frame[14:])
                srv.send(data)
                break

    srv.stop()
    log.info("bridge idle timeout — exiting")
