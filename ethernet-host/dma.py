#!/usr/bin/env python3
"""Host-side UDP DMA tool for the Nexys A7 Ethernet memory bridge.

Run on the machine whose NIC is cabled to the board (on this setup: Windows,
with a static IP 192.168.1.10/24).  Works against both FPGA designs.

Examples:
    python dma.py ping
    python dma.py write 0x0 deadbeefcafef00d
    python dma.py read  0x0 16
    python dma.py test --size 8192            # write random, read back, verify

See ../docs/protocol.md for the wire format.
"""
import argparse, socket, struct, sys, os, random

MAGIC      = 0xA5
OP_WRITE   = 0x01
OP_READ    = 0x02
RESP_BIT   = 0x80

DEF_IP   = "192.168.1.128"
DEF_PORT = 1234
CHUNK    = 1024          # max data bytes per datagram
TIMEOUT  = 1.0


class Dma:
    def __init__(self, ip=DEF_IP, port=DEF_PORT, timeout=TIMEOUT):
        self.addr = (ip, port)
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.settimeout(timeout)

    def _xfer(self, pkt):
        self.sock.sendto(pkt, self.addr)
        resp, _ = self.sock.recvfrom(2048)
        return resp

    # 10-byte header: magic, opcode, len, addr, 2 reserved bytes.
    # The 2 reserved bytes make the payload data word-aligned in the frame.
    HDR = ">BBHIH"
    HDR_LEN = 10

    def _hdr(self, opcode, length, addr):
        return struct.pack(self.HDR, MAGIC, opcode, length, addr, 0)

    def write(self, addr, data):
        """Write bytes (len multiple of 4) at byte address; splits into chunks."""
        assert len(data) % 4 == 0, "length must be a multiple of 4"
        off = 0
        while off < len(data):
            piece = data[off:off + CHUNK]
            pkt = self._hdr(OP_WRITE, len(piece), addr + off) + piece
            resp = self._xfer(pkt)
            magic, op, length, raddr, _ = struct.unpack(self.HDR, resp[:self.HDR_LEN])
            if magic != MAGIC or op != (OP_WRITE | RESP_BIT) or raddr != addr + off:
                raise IOError(f"bad write ack: {resp[:self.HDR_LEN].hex()}")
            off += len(piece)

    def read(self, addr, length):
        """Read `length` bytes (multiple of 4) starting at byte address."""
        assert length % 4 == 0, "length must be a multiple of 4"
        out = bytearray()
        off = 0
        while off < length:
            n = min(CHUNK, length - off)
            pkt = self._hdr(OP_READ, n, addr + off)
            resp = self._xfer(pkt)
            magic, op, rlen, raddr, _ = struct.unpack(self.HDR, resp[:self.HDR_LEN])
            if magic != MAGIC or op != (OP_READ | RESP_BIT) or raddr != addr + off:
                raise IOError(f"bad read resp: {resp[:self.HDR_LEN].hex()}")
            out += resp[self.HDR_LEN:self.HDR_LEN + rlen]
            off += n
        return bytes(out)


def cmd_ping(d, a):
    # ARP/UDP round-trip sanity: read 4 bytes from addr 0.
    try:
        d.read(0, 4); print("OK: FPGA responded")
    except socket.timeout:
        print("TIMEOUT: no reply (check link / static IP / arp -a)"); sys.exit(1)

def cmd_write(d, a):
    data = bytes.fromhex(a.hexdata)
    if len(data) % 4: sys.exit("hex data must be a multiple of 4 bytes")
    d.write(a.addr, data); print(f"wrote {len(data)} bytes @ {a.addr:#010x}")

def cmd_read(d, a):
    data = d.read(a.addr, a.length)
    print(data.hex())

def cmd_test(d, a):
    size = a.size
    if size % 4: sys.exit("--size must be a multiple of 4")
    rnd = random.Random(a.seed)
    ref = bytes(rnd.getrandbits(8) for _ in range(size))
    print(f"writing {size} random bytes @ {a.base:#x} ...")
    d.write(a.base, ref)
    print("reading back ...")
    got = d.read(a.base, size)
    if got == ref:
        print(f"PASS: {size} bytes match")
    else:
        nbad = sum(1 for x, y in zip(got, ref) if x != y)
        i = next(i for i in range(size) if got[i] != ref[i])
        print(f"FAIL: {nbad}/{size} bytes differ; first @ +{i}: "
              f"got {got[i]:02x} exp {ref[i]:02x}")
        sys.exit(1)


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--ip", default=DEF_IP)
    p.add_argument("--port", type=int, default=DEF_PORT)
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("ping")

    w = sub.add_parser("write"); w.add_argument("addr", type=lambda x: int(x, 0))
    w.add_argument("hexdata")

    r = sub.add_parser("read"); r.add_argument("addr", type=lambda x: int(x, 0))
    r.add_argument("length", type=lambda x: int(x, 0))

    t = sub.add_parser("test")
    t.add_argument("--size", type=lambda x: int(x, 0), default=8192)
    t.add_argument("--base", type=lambda x: int(x, 0), default=0)
    t.add_argument("--seed", type=int, default=1)

    a = p.parse_args()
    d = Dma(a.ip, a.port)
    {"ping": cmd_ping, "write": cmd_write, "read": cmd_read, "test": cmd_test}[a.cmd](d, a)


if __name__ == "__main__":
    main()
