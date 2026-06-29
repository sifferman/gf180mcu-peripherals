"""

Copyright (c) 2020-2025 Alex Forencich

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

"""

import logging

import cocotb
from cocotb.queue import Queue, QueueFull
from cocotb.triggers import RisingEdge, Timer, First, Event
from cocotb.utils import get_sim_time, get_sim_steps

from .version import __version__
from .gmii import GmiiFrame
from .constants import EthPre
from .reset import Reset

# RMII transfers a byte as 4 di-bits, least-significant di-bit first, with
# RXD[0]/TXD[0] the lower-order bit of each di-bit (RMII Rev 1.2 Figure 5). At
# 100 Mb/s a di-bit occupies one REF_CLK cycle; at 10 Mb/s it is repeated 10x.


def _cycles_per_dibit(speed):
    if speed == 100e6:
        return 1
    elif speed == 10e6:
        return 10
    else:
        raise ValueError("Invalid speed selection")


class RmiiSource(Reset):

    def __init__(self, data, er, dv, clock, reset=None, enable=None, reset_active_level=True,
                 speed=100e6, *args, **kwargs):
        self.log = logging.getLogger(f"cocotb.{data._path}")
        self.data = data
        self.er = er
        self.dv = dv
        self.clock = clock
        self.reset = reset
        self.enable = enable

        self.log.info("RMII source")
        self.log.info("cocotbext-eth version %s", __version__)
        self.log.info("Copyright (c) 2020-2025 Alex Forencich")
        self.log.info("https://github.com/alexforencich/cocotbext-eth")

        super().__init__(*args, **kwargs)

        self.active = False
        self.queue = Queue()
        self.dequeue_event = Event()
        self.current_frame = None
        self.idle_event = Event()
        self.idle_event.set()
        self.active_event = Event()

        self.ifg = 12
        self.cycles_per_dibit = _cycles_per_dibit(speed)

        # When set, CRS_DV toggles at the di-bit rate over the last few di-bits of
        # a frame (deasserted on the first di-bit of a nibble, asserted on the
        # second), as a PHY does when carrier ends before the data FIFO drains
        # (RMII Rev 1.2 5.2). The data di-bits are still driven, so a conforming
        # MAC must keep capturing them.
        self.crs_dv_end_toggle = False
        self.crs_dv_toggle_dibits = 8

        self.queue_occupancy_bytes = 0
        self.queue_occupancy_frames = 0

        self.queue_occupancy_limit_bytes = -1
        self.queue_occupancy_limit_frames = -1

        self.width = 2
        self.byte_width = 1

        assert len(self.data) == 2
        self.data.setimmediatevalue(0)
        if self.er is not None:
            assert len(self.er) == 1
            self.er.setimmediatevalue(0)
        assert len(self.dv) == 1
        self.dv.setimmediatevalue(0)

        self._run_cr = None

        self._init_reset(reset, reset_active_level)

    async def send(self, frame):
        while self.full():
            self.dequeue_event.clear()
            await self.dequeue_event.wait()
        frame = GmiiFrame(frame)
        await self.queue.put(frame)
        self.idle_event.clear()
        self.active_event.set()
        self.queue_occupancy_bytes += len(frame)
        self.queue_occupancy_frames += 1

    def send_nowait(self, frame):
        if self.full():
            raise QueueFull()
        frame = GmiiFrame(frame)
        self.queue.put_nowait(frame)
        self.idle_event.clear()
        self.active_event.set()
        self.queue_occupancy_bytes += len(frame)
        self.queue_occupancy_frames += 1

    def count(self):
        return self.queue.qsize()

    def empty(self):
        return self.queue.empty()

    def full(self):
        if self.queue_occupancy_limit_bytes > 0 and self.queue_occupancy_bytes > self.queue_occupancy_limit_bytes:
            return True
        elif self.queue_occupancy_limit_frames > 0 and self.queue_occupancy_frames > self.queue_occupancy_limit_frames:
            return True
        else:
            return False

    def idle(self):
        return self.empty() and not self.active

    def clear(self):
        while not self.queue.empty():
            frame = self.queue.get_nowait()
            frame.sim_time_end = None
            frame.handle_tx_complete()
        self.dequeue_event.set()
        self.idle_event.set()
        self.active_event.clear()
        self.queue_occupancy_bytes = 0
        self.queue_occupancy_frames = 0

    async def wait(self):
        await self.idle_event.wait()

    def _handle_reset(self, state):
        if state:
            self.log.info("Reset asserted")
            if self._run_cr is not None:
                self._run_cr.kill()
                self._run_cr = None

            self.active = False
            self.data.value = 0
            if self.er is not None:
                self.er.value = 0
            self.dv.value = 0

            if self.current_frame:
                self.log.warning("Flushed transmit frame during reset: %s", self.current_frame)
                self.current_frame.handle_tx_complete()
                self.current_frame = None

            if self.queue.empty():
                self.idle_event.set()
                self.active_event.clear()
        else:
            self.log.info("Reset de-asserted")
            if self._run_cr is None:
                self._run_cr = cocotb.start_soon(self._run())

    async def _run(self):
        frame = None
        frame_offset = 0
        frame_data = None
        frame_error = None
        rep = 0
        ifg_cnt = 0
        self.active = False
        cpd = self.cycles_per_dibit

        clock_edge_event = RisingEdge(self.clock)

        enable_event = None
        if self.enable is not None:
            enable_event = RisingEdge(self.enable)

        while True:
            await clock_edge_event

            if self.enable is None or int(self.enable.value):
                if ifg_cnt > 0:
                    # in IFG
                    ifg_cnt -= 1

                elif frame is None and not self.queue.empty():
                    # send frame
                    frame = self.queue.get_nowait()
                    self.dequeue_event.set()
                    self.queue_occupancy_bytes -= len(frame)
                    self.queue_occupancy_frames -= 1
                    self.current_frame = frame
                    frame.sim_time_start = get_sim_time()
                    frame.sim_time_sfd = None
                    frame.sim_time_end = None
                    self.log.info("TX frame: %s", frame)
                    frame.normalize()

                    # convert to RMII di-bits, least-significant di-bit first
                    frame_data = []
                    frame_error = []
                    for b, e in zip(frame.data, frame.error):
                        frame_data.append(b & 0x3)
                        frame_data.append((b >> 2) & 0x3)
                        frame_data.append((b >> 4) & 0x3)
                        frame_data.append((b >> 6) & 0x3)
                        frame_error.extend([e, e, e, e])

                    self.active = True
                    frame_offset = 0
                    rep = 0

                if frame is not None:
                    d = frame_data[frame_offset]
                    # CRS_DV is normally asserted for the whole frame; optionally
                    # toggle it over the last di-bits (low on the first di-bit of a
                    # nibble, high on the second) to model end-of-carrier drain.
                    dv = 1
                    if self.crs_dv_end_toggle and frame_offset >= len(frame_data) - self.crs_dv_toggle_dibits:
                        dv = 1 if (frame_offset & 1) else 0
                    self.data.value = d
                    if self.er is not None:
                        self.er.value = frame_error[frame_offset]
                    self.dv.value = dv
                    rep += 1

                    if rep >= cpd:
                        rep = 0
                        frame_offset += 1
                        if frame_offset >= len(frame_data):
                            ifg_cnt = max(self.ifg, 1) * cpd
                            frame.sim_time_end = get_sim_time()
                            frame.handle_tx_complete()
                            frame = None
                            self.current_frame = None
                else:
                    self.data.value = 0
                    if self.er is not None:
                        self.er.value = 0
                    self.dv.value = 0
                    self.active = False

                    if ifg_cnt == 0 and self.queue.empty():
                        self.idle_event.set()
                        self.active_event.clear()
                        await self.active_event.wait()

            elif self.enable is not None and not self.enable.value:
                await enable_event


class RmiiSink(Reset):

    def __init__(self, data, er, dv, clock, reset=None, enable=None, reset_active_level=True,
                 speed=100e6, *args, **kwargs):
        self.log = logging.getLogger(f"cocotb.{data._path}")
        self.data = data
        self.er = er
        self.dv = dv
        self.clock = clock
        self.reset = reset
        self.enable = enable

        self.log.info("RMII sink")
        self.log.info("cocotbext-eth version %s", __version__)
        self.log.info("Copyright (c) 2020-2025 Alex Forencich")
        self.log.info("https://github.com/alexforencich/cocotbext-eth")

        super().__init__(*args, **kwargs)

        self.active = False
        self.queue = Queue()
        self.active_event = Event()

        self.cycles_per_dibit = _cycles_per_dibit(speed)

        self.queue_occupancy_bytes = 0
        self.queue_occupancy_frames = 0

        self.width = 2
        self.byte_width = 1

        assert len(self.data) == 2
        if self.er is not None:
            assert len(self.er) == 1
        if self.dv is not None:
            assert len(self.dv) == 1

        self._run_cr = None

        self._init_reset(reset, reset_active_level)

    def _recv(self, frame, compact=True):
        if self.queue.empty():
            self.active_event.clear()
        self.queue_occupancy_bytes -= len(frame)
        self.queue_occupancy_frames -= 1
        if compact:
            frame.compact()
        return frame

    async def recv(self, compact=True):
        frame = await self.queue.get()
        return self._recv(frame, compact)

    def recv_nowait(self, compact=True):
        frame = self.queue.get_nowait()
        return self._recv(frame, compact)

    def count(self):
        return self.queue.qsize()

    def empty(self):
        return self.queue.empty()

    def idle(self):
        return not self.active

    def clear(self):
        while not self.queue.empty():
            self.queue.get_nowait()
        self.active_event.clear()
        self.queue_occupancy_bytes = 0
        self.queue_occupancy_frames = 0

    async def wait(self, timeout=0, timeout_unit=None):
        if not self.empty():
            return
        if timeout:
            await First(self.active_event.wait(), Timer(timeout, timeout_unit))
        else:
            await self.active_event.wait()

    def _handle_reset(self, state):
        if state:
            self.log.info("Reset asserted")
            if self._run_cr is not None:
                self._run_cr.kill()
                self._run_cr = None

            self.active = False
        else:
            self.log.info("Reset de-asserted")
            if self._run_cr is None:
                self._run_cr = cocotb.start_soon(self._run())

    async def _run(self):
        frame = None
        self.active = False
        cpd = self.cycles_per_dibit
        cyc = 0
        started = False

        clock_edge_event = RisingEdge(self.clock)
        active_event = RisingEdge(self.dv)

        enable_event = None
        if self.enable is not None:
            enable_event = RisingEdge(self.enable)

        while True:
            await clock_edge_event

            if self.enable is None or int(self.enable.value):
                # align di-bit sampling to the first TX_EN cycle; at 10M each
                # di-bit is held for cpd cycles, so sample mid-window
                if not started:
                    # During reset the DUT's TX_EN output is X in gate-level sim
                    # (std-cell flops are unresolved until reset propagates); treat
                    # an unresolved TX_EN as idle rather than crashing on int(X).
                    dv = self.dv.value
                    if dv.is_resolvable and int(dv):
                        started = True
                        cyc = 0
                    else:
                        await active_event
                        continue

                if cyc == cpd // 2:
                    # Gate-level: when TX_EN is low, TXD is don't-care and the std-cell
                    # output can be X; an unresolved TXD must not crash int(). Resolve any
                    # X to 0 -- harmless while idle, and a genuine X inside a frame then
                    # shows up as a payload mismatch in the test (informative) rather than
                    # a monitor crash.
                    def _res(sig):
                        v = sig.value
                        return int(v) if v.is_resolvable else 0
                    d_val = _res(self.data)
                    dv_val = _res(self.dv)
                    er_val = 0 if self.er is None else _res(self.er)

                    if frame is None:
                        if dv_val:
                            frame = GmiiFrame(bytearray(), [])
                            frame.sim_time_start = get_sim_time()
                    else:
                        if not dv_val:
                            # end of frame: reassemble di-bits (LSB-first) into
                            # bytes, aligning byte boundaries on the SFD
                            b = 0
                            be = 0
                            cnt = 0
                            sync = False
                            data = bytearray()
                            error = []
                            for n, e in zip(frame.data, frame.error):
                                b = (n & 0x3) << 6 | b >> 2
                                be |= e
                                cnt += 1
                                if not sync and b == EthPre.SFD:
                                    cnt = 4
                                    sync = True
                                if cnt == 4:
                                    data.append(b)
                                    error.append(be)
                                    be = 0
                                    cnt = 0
                            frame.data = data
                            frame.error = error

                            frame.compact()
                            frame.sim_time_end = get_sim_time()
                            self.log.info("RX frame: %s", frame)

                            self.queue_occupancy_bytes += len(frame)
                            self.queue_occupancy_frames += 1

                            self.queue.put_nowait(frame)
                            self.active_event.set()

                            frame = None
                            started = False

                    if frame is not None:
                        frame.data.append(d_val)
                        frame.error.append(er_val)

                cyc = (cyc + 1) % cpd

            elif self.enable is not None and not self.enable.value:
                await enable_event


class RmiiPhy:
    def __init__(self, txd, tx_en, ref_clk, rxd, rx_er, crs_dv, reset=None,
            reset_active_level=True, speed=100e6, *args, **kwargs):

        self.ref_clk = ref_clk

        super().__init__(*args, **kwargs)

        # PHY drives RX into the MAC, monitors TX out of the MAC; all on ref_clk.
        # RMII has no TX_ER, so the TX sink takes no error signal.
        self.tx = RmiiSink(txd, None, tx_en, ref_clk, reset, reset_active_level=reset_active_level, speed=speed)
        self.rx = RmiiSource(rxd, rx_er, crs_dv, ref_clk, reset, reset_active_level=reset_active_level, speed=speed)

        self.ref_clk.setimmediatevalue(0)

        self._clock_cr = None
        self.set_speed(speed)

    def set_speed(self, speed):
        self.speed = speed
        self.tx.cycles_per_dibit = _cycles_per_dibit(speed)
        self.rx.cycles_per_dibit = _cycles_per_dibit(speed)

        if self._clock_cr is not None:
            self._clock_cr.kill()

        # RMII reference clock is a fixed 50 MHz regardless of 10/100 mode
        self._clock_cr = cocotb.start_soon(self._run_clock(20.0))

    async def _run_clock(self, period_ns):
        half_period = get_sim_steps(period_ns / 2.0, 'ns')
        t = Timer(half_period)
        while True:
            await t
            self.ref_clk.value = 1
            await t
            self.ref_clk.value = 0
