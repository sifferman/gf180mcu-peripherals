#!/usr/bin/env python3
# SPDX-FileCopyrightText: © 2026 gf180mcu-peripherals Authors
# SPDX-License-Identifier: Apache-2.0
"""
Generate a SPICE deck for the ring_dco (binary-weighted DCO) from the gf180mcu 3v3
standard cells, and (optionally) sweep the tune code with ngspice to extract the
frequency-vs-code curve.

The ring mirrors src/adpll/dco/ring_dco_binary.sv exactly:
    node0          = NAND2(enable, feedback)              # gate + the single inversion
    node[i+1]      = MUX2(A=node[i], B=delay_2^i(node[i]), S=tune[i])
    feedback,clk_o = node[NumTuneBits]
where delay_2^i is a chain of 2**i non-inverting inverter pairs.

gf180 3v3 cell subckt pin orders (from the PDK spice models):
    inv_2   : VDD VNW VPW VSS  Y A
    nand2_2 : VDD VNW VPW VSS  Y B A
    mux2_2  : VDD VNW VPW VSS  S B A Y

Usage:
    gen_ring_dco_spice.py --pdk-root <dir> --bits 7 --code 64 > dco.spice
    gen_ring_dco_spice.py --pdk-root <dir> --bits 7 --sweep 0,16,32,64,127 --run
"""
import argparse
import os
import re
import subprocess
import sys

CELL = "gf180mcu_as_sc_mcu7t3v3"


def pdk_paths(pdk_root, pdk="gf180mcuD"):
    base = os.path.join(pdk_root, pdk)
    ng = os.path.join(base, "libs.tech", "ngspice")
    design = os.path.join(ng, "design.ngspice")   # sets statistical params used by models
    models = os.path.join(ng, "sm141064.ngspice")
    cells = os.path.join(base, "libs.ref", CELL, "spice", f"{CELL}.spice")
    return design, models, cells


TOPOLOGIES = ("binary", "thermometer", "muxtap")


def _inv_pair(a, src, mid, dst):
    """Two inv_2 in series (non-inverting delay): src -> mid -> dst.  (pins Y A)"""
    a(f"X{mid} VDD VNW VPW VSS {mid} {src} {CELL}__inv_2")
    a(f"X{dst} VDD VNW VPW VSS {dst} {mid} {CELL}__inv_2")


def _ring_binary(a, bits, code):
    """ring_dco_binary: segment i = 2**i inverter pairs, a mux per segment inserts or
    bypasses that delay by the binary value of `code`.  Returns the oscillating net."""
    a(f"Xgate VDD VNW VPW VSS node0 OUT enable {CELL}__nand2_2")   # node0 = NAND(enable, OUT)
    node = "node0"
    for i in range(bits):
        d_prev = node
        for j in range(1 << i):
            _inv_pair(a, d_prev, f"b{i}_{j}m", f"b{i}_{j}o")
            d_prev = f"b{i}_{j}o"
        sel = "VDD" if (code >> i) & 1 else "0"          # fixed code -> hard tie
        nxt = "OUT" if i == bits - 1 else f"node{i+1}"
        a(f"Xsel{i} VDD VNW VPW VSS {sel} {d_prev} {node} {nxt} {CELL}__mux2_2")  # S B A Y
        node = nxt
    return "OUT"


def _ring_thermometer(a, bits, code):
    """ring_dco_thermometer: 2**bits-1 identical unit pairs; the first `code` of them are
    inserted (monotonic).  Each unit's select is a hard tie since `code` is fixed."""
    num_units = (1 << bits) - 1
    a(f"Xgate VDD VNW VPW VSS node0 OUT enable {CELL}__nand2_2")
    node = "node0"
    for k in range(num_units):
        _inv_pair(a, node, f"u{k}m", f"u{k}d")
        sel = "VDD" if k < code else "0"
        nxt = "OUT" if k == num_units - 1 else f"u{k}n"
        a(f"Xsel{k} VDD VNW VPW VSS {sel} u{k}d {node} {nxt} {CELL}__mux2_2")
        node = nxt
    return "OUT"


def _ring_muxtap(a, bits, code):
    """ring_dco_muxtap: a 2**bits-tap delay chain selected by a binary mux tree; `code`
    picks which tap closes the loop (variable ring length).  Returns the oscillating net."""
    num_taps = 1 << bits
    a(f"Xgate VDD VNW VPW VSS tap0 OUT enable {CELL}__nand2_2")
    for k in range(1, num_taps):
        _inv_pair(a, f"tap{k-1}", f"t{k}m", f"tap{k}")
    level = [f"tap{i}" for i in range(num_taps)]
    for lvl in range(1, bits + 1):
        sel = "VDD" if (code >> (lvl - 1)) & 1 else "0"
        nxt = []
        for i in range(num_taps >> lvl):
            y = "OUT" if (lvl == bits and i == 0) else f"tl{lvl}_{i}"
            a(f"Xmux{lvl}_{i} VDD VNW VPW VSS {sel} {level[2*i+1]} {level[2*i]} {y} {CELL}__mux2_2")
            nxt.append(y)
        level = nxt
    return "OUT"


_RINGS = {"binary": _ring_binary, "thermometer": _ring_thermometer, "muxtap": _ring_muxtap}


def gen_deck(design, models, cells, bits, code, topology="binary", vdd=3.3, corner="typical",
             temp=25.0, tstop_ns=1600.0, tstep_ps=10.0, settle_rise=6, meas_periods=10):
    """Return a SPICE deck string for one tune code / topology at one PVT corner. Mirrors
    the three RTL DCOs in src/adpll/dco/. Since the tune code is fixed per run, every mux
    select is a hard tie to VDD/VSS (no tune-net drivers needed)."""
    # ngspice is picky: .lib/.include paths must be UNQUOTED, and .measure right-hand
    # sides must be literal numbers (a {VDD/2} param expression fails to evaluate).
    vth = vdd / 2.0
    L = []
    a = L.append
    a(f"* ring_dco_{topology} DCO  bits={bits} code={code} corner={corner} vdd={vdd} temp={temp}")
    a(f".include {design}")               # statistical params referenced by the models
    a(f".lib {models} {corner}")          # process corner (transistor model skew)
    a(f".include {cells}")
    a(f".temp {temp}")                    # temperature corner
    a("")
    a(f".param VDD={vdd}")
    a("Vdd  VDD 0 {VDD}")
    a("Vnw  VNW 0 {VDD}")     # nwell tie to VDD
    a("Vpw  VPW 0 0")          # pwell tie to VSS
    a("Vss  VSS 0 0")
    # enable: rise at 1 ns to kick-start oscillation
    a("Ven  enable 0 PWL(0 0 1n 0 1.05n {VDD})")
    a("")
    out = _RINGS[topology](a, bits, code)
    a(f"Cload {out} 0 1f")               # tiny load on the output node
    a("")
    a(".tran {}p {}n uic".format(tstep_ps, tstop_ns))
    a(".control")
    a("run")
    # Measure the time of two rising crossings `meas_periods` apart, after the startup
    # transient settles; the Python wrapper computes period = (t_b - t_a)/meas_periods.
    a(f"meas tran t_a WHEN v({out})={vth:.4f} RISE={settle_rise}")
    a(f"meas tran t_b WHEN v({out})={vth:.4f} RISE={settle_rise + meas_periods}")
    a(".endc")
    a(".end")
    return "\n".join(L) + "\n"


def run_ngspice(deck, workdir, tag, ngspice="ngspice", meas_periods=8):
    path = os.path.join(workdir, f"dco_{tag}.spice")
    with open(path, "w") as f:
        f.write(deck)
    out = subprocess.run([ngspice, "-b", path], capture_output=True, text=True,
                         timeout=1200)
    txt = out.stdout + "\n" + out.stderr
    # ngspice prints "t_a = <value>" / "t_b = <value>" (seconds)
    ta = re.findall(r"t_a\s*=\s*([0-9.eE+\-]+)", txt)
    tb = re.findall(r"t_b\s*=\s*([0-9.eE+\-]+)", txt)
    freq = period = None
    if ta and tb:
        try:
            period = (float(tb[-1]) - float(ta[-1])) / meas_periods
            if period > 0:
                freq = 1.0 / period
        except ValueError:
            pass
    return freq, period, txt, path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pdk-root", required=True)
    ap.add_argument("--pdk", default="gf180mcuD")
    ap.add_argument("--bits", type=int, default=7)
    ap.add_argument("--code", type=int, default=0)
    ap.add_argument("--topology", default="binary", choices=TOPOLOGIES,
                    help="DCO topology to emit (mirrors the three src/adpll/dco RTL variants)")
    ap.add_argument("--corner", default="typical", help="process corner: typical|ss|ff|fs|sf")
    ap.add_argument("--vdd", type=float, default=3.3, help="supply voltage corner")
    ap.add_argument("--temp", type=float, default=25.0, help="temperature corner (C)")
    ap.add_argument("--tstop-ns", type=float, default=3000.0)
    ap.add_argument("--sweep", default="", help="comma-separated codes to sweep")
    ap.add_argument("--run", action="store_true", help="run ngspice and report freq")
    ap.add_argument("--workdir", default=".")
    ap.add_argument("--ngspice", default="ngspice", help="ngspice binary (>=42 for gf180 BSIM models)")
    args = ap.parse_args()

    design, models, cells = pdk_paths(args.pdk_root, args.pdk)
    for p in (design, models, cells):
        if not os.path.exists(p):
            sys.exit(f"missing PDK file: {p}")

    if args.sweep:
        codes = [int(c) for c in args.sweep.split(",")]
        print(f"# ring_dco_{args.topology} freq-vs-code sweep  bits={args.bits} corner={args.corner} vdd={args.vdd} temp={args.temp}", flush=True)
        print(f"# {'code':>5}  {'freq_MHz':>12}  {'period_ns':>12}", flush=True)
        for code in codes:
            # Escalate tstop so fast (low) codes stay cheap and only slow (high) codes
            # pay for a long transient.
            freq = period = None
            for tstop in (150.0, 500.0, 1600.0, 5000.0):
                deck = gen_deck(design, models, cells, args.bits, code, topology=args.topology,
                                corner=args.corner, vdd=args.vdd, temp=args.temp, tstop_ns=tstop)
                freq, period, txt, path = run_ngspice(deck, args.workdir, f"{args.topology}_b{args.bits}_c{code}",
                                                      ngspice=args.ngspice, meas_periods=10)
                if freq:
                    break
            if freq:
                print(f"  {code:>5}  {freq/1e6:>12.3f}  {period*1e9:>12.4f}", flush=True)
            else:
                print(f"  {code:>5}  {'FAIL':>12}  (see {path})", flush=True)
                sys.stderr.write(txt[-1500:] + "\n")
        return

    deck = gen_deck(design, models, cells, args.bits, args.code, topology=args.topology,
                    corner=args.corner, vdd=args.vdd, temp=args.temp, tstop_ns=args.tstop_ns)
    if args.run:
        freq, period, txt, path = run_ngspice(deck, args.workdir, f"{args.topology}_b{args.bits}_c{args.code}", ngspice=args.ngspice, meas_periods=10)
        print(txt)
        if freq:
            print(f"\n# RESULT bits={args.bits} code={args.code}: "
                  f"freq={freq/1e6:.3f} MHz period={period*1e9:.4f} ns")
    else:
        sys.stdout.write(deck)


if __name__ == "__main__":
    main()
