#!/usr/bin/env python3
# SPDX-FileCopyrightText: © 2026 gf180mcu-peripherals Authors
# SPDX-License-Identifier: Apache-2.0
"""
Generate a SPICE deck for the ring_dco (binary-weighted DCO) from the gf180mcu 3v3
standard cells, and (optionally) sweep the tune code with ngspice to extract the
frequency-vs-code curve.

The ring mirrors src/adpll/ring_dco.sv exactly:
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


def gen_deck(design, models, cells, bits, code, vdd=3.3, corner="typical", temp=25.0,
             tstop_ns=1600.0, tstep_ps=10.0, settle_rise=6, meas_periods=10):
    """Return a SPICE deck string for one tune code at one PVT corner."""
    # ngspice is picky: .lib/.include paths must be UNQUOTED, and .measure right-hand
    # sides must be literal numbers (a {VDD/2} param expression fails to evaluate).
    vth = vdd / 2.0
    L = []
    a = L.append
    a(f"* ring_dco binary-weighted DCO  bits={bits} code={code} corner={corner} vdd={vdd} temp={temp}")
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
    # tune bit drivers
    for i in range(bits):
        lvl = "{VDD}" if (code >> i) & 1 else "0"
        a(f"Vt{i} tune{i} 0 {lvl}")
    a("")
    # gate: node0 = NAND(enable, feedback) where feedback == the output node node{bits}
    # (pins: Y B A); wiring node{bits} straight into B closes the ring.
    a(f"Xgate VDD VNW VPW VSS node0 node{bits} enable {CELL}__nand2_2")
    # weighted delay segments + selects
    for i in range(bits):
        npairs = 1 << i
        innode = f"node{i}"
        # inverter-pair delay chain
        d_prev = innode
        for j in range(npairs):
            mid = f"d{i}_{j}_m"
            out = f"d{i}_{j}_o"
            a(f"Xi{i}_{j}a VDD VNW VPW VSS {mid} {d_prev} {CELL}__inv_2")   # Y A
            a(f"Xi{i}_{j}b VDD VNW VPW VSS {out} {mid} {CELL}__inv_2")
            d_prev = out
        delayed = d_prev  # node[i] if npairs==0, but npairs>=1 always here
        # mux: Y=node{i+1}, S=tune i, B=delayed, A=bypass(node i)   (pins: S B A Y)
        a(f"Xsel{i} VDD VNW VPW VSS tune{i} {delayed} {innode} node{i+1} {CELL}__mux2_2")
    a(f"Cload node{bits} 0 1f")          # tiny load on the output node
    a("")
    a(".tran {}p {}n uic".format(tstep_ps, tstop_ns))
    a(".control")
    a("run")
    # Measure the time of two rising crossings `meas_periods` apart, after the startup
    # transient settles; the Python wrapper computes period = (t_b - t_a)/meas_periods.
    a(f"meas tran t_a WHEN v(node{bits})={vth:.4f} RISE={settle_rise}")
    a(f"meas tran t_b WHEN v(node{bits})={vth:.4f} RISE={settle_rise + meas_periods}")
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
        print(f"# ring_dco freq-vs-code sweep  bits={args.bits} corner={args.corner} vdd={args.vdd} temp={args.temp}", flush=True)
        print(f"# {'code':>5}  {'freq_MHz':>12}  {'period_ns':>12}", flush=True)
        for code in codes:
            # Escalate tstop so fast (low) codes stay cheap and only slow (high) codes
            # pay for a long transient.
            freq = period = None
            for tstop in (150.0, 500.0, 1600.0, 5000.0):
                deck = gen_deck(design, models, cells, args.bits, code,
                                corner=args.corner, vdd=args.vdd, temp=args.temp, tstop_ns=tstop)
                freq, period, txt, path = run_ngspice(deck, args.workdir, f"b{args.bits}_c{code}",
                                                      ngspice=args.ngspice, meas_periods=10)
                if freq:
                    break
            if freq:
                print(f"  {code:>5}  {freq/1e6:>12.3f}  {period*1e9:>12.4f}", flush=True)
            else:
                print(f"  {code:>5}  {'FAIL':>12}  (see {path})", flush=True)
                sys.stderr.write(txt[-1500:] + "\n")
        return

    deck = gen_deck(design, models, cells, args.bits, args.code,
                    corner=args.corner, vdd=args.vdd, temp=args.temp, tstop_ns=args.tstop_ns)
    if args.run:
        freq, period, txt, path = run_ngspice(deck, args.workdir, f"b{args.bits}_c{args.code}", ngspice=args.ngspice, meas_periods=10)
        print(txt)
        if freq:
            print(f"\n# RESULT bits={args.bits} code={args.code}: "
                  f"freq={freq/1e6:.3f} MHz period={period*1e9:.4f} ns")
    else:
        sys.stdout.write(deck)


if __name__ == "__main__":
    main()
