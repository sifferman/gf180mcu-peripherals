#!/usr/bin/env python3
# SPDX-FileCopyrightText: © 2026 gf180mcu-peripherals Authors
# SPDX-License-Identifier: Apache-2.0
"""
Plot the ADPLL comparison figures from the SPICE corner sweep and the
controller-survey logs.

Inputs (produced by `make dco-spice-corners` / `make sim-adpll-survey`):
  * corner_<name>.dat -- the freq-vs-code table printed by gen_ring_dco_spice.py
    (header lines start with '#', then rows of "code  freq_MHz  period_ns").
  * controller lock times are passed on the command line (they come straight
    from the survey print-out; no machine-readable log to parse).

Outputs (PNG): dco_freq_vs_code.png, dco_pvt_envelope.png, ctrl_lock_compare.png
"""
import argparse
import os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

# Slowest -> fastest. Colours chosen colour-blind-safe.
CORNER_ORDER = ["ss", "typical", "ff"]
CORNER_LABEL = {
    "ss": "SS  (ss / 3.0 V / 125 °C)",
    "typical": "TT  (typ / 3.3 V / 25 °C)",
    "ff": "FF  (ff / 3.6 V / −40 °C)",
}
CORNER_COLOR = {"ss": "#1b9e77", "typical": "#7570b3", "ff": "#d95f02"}


def parse_dat(path):
    """Return [(code, freq_MHz), ...] for the rows that measured a frequency."""
    rows = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            if len(parts) < 2 or parts[1] == "FAIL":
                continue
            try:
                rows.append((int(parts[0]), float(parts[1])))
            except ValueError:
                continue
    rows.sort()
    return rows


def monotonic_prefix(rows):
    """Longest leading run where freq strictly decreases with code (the usable,
    single-mode region; high codes go multi-mode and fold back up)."""
    if not rows:
        return rows
    keep = [rows[0]]
    for c, fr in rows[1:]:
        if fr < keep[-1][1]:
            keep.append((c, fr))
        else:
            break
    return keep


def plot_freq_vs_code(datasets, outpath):
    fig, ax = plt.subplots(figsize=(7.5, 4.6))
    for name in CORNER_ORDER:
        rows = datasets.get(name)
        if not rows:
            continue
        codes = [c for c, _ in rows]
        freqs = [f for _, f in rows]
        ax.plot(codes, freqs, "-o", ms=4, color=CORNER_COLOR[name],
                label=CORNER_LABEL[name])
        mono = monotonic_prefix(rows)
        if mono and len(mono) < len(rows):
            mc, mf = mono[-1]
            ax.annotate("multi-mode →", (mc, mf), color=CORNER_COLOR[name],
                        fontsize=8, xytext=(6, 6), textcoords="offset points")
    ax.set_xlabel("tune code (0 = no inserted delay = fastest)")
    ax.set_ylabel("DCO frequency (MHz)")
    ax.set_title("Ring DCO frequency vs. tune code, by PVT corner\n"
                 "(gf180mcu 3v3 std-cells, ngspice)")
    ax.grid(True, alpha=0.3)
    ax.legend()
    fig.tight_layout()
    fig.savefig(outpath, dpi=130)
    plt.close(fig)


def plot_pvt_envelope(datasets, outpath):
    """min/max reachable frequency at each corner -> the lock envelope."""
    fig, ax = plt.subplots(figsize=(7.5, 4.6))
    names = [n for n in CORNER_ORDER if datasets.get(n)]
    lows, highs, mids = [], [], []
    for name in names:
        rows = datasets[name]
        mono = monotonic_prefix(rows)
        freqs = [f for _, f in mono]
        lows.append(min(freqs))
        highs.append(max(freqs))
        mids.append(rows[0][1])  # code 0 = fastest
    xs = range(len(names))
    for i, name in enumerate(names):
        ax.vlines(i, lows[i], highs[i], color=CORNER_COLOR[name], lw=8, alpha=0.55)
        ax.plot(i, highs[i], "v", color=CORNER_COLOR[name])
        ax.plot(i, lows[i], "^", color=CORNER_COLOR[name])
        ax.annotate(f"{highs[i]:.0f}", (i, highs[i]), xytext=(8, 0),
                    textcoords="offset points", va="center", fontsize=9)
        ax.annotate(f"{lows[i]:.0f}", (i, lows[i]), xytext=(8, 0),
                    textcoords="offset points", va="center", fontsize=9)
    # the band that is lockable at EVERY corner: max of the lows .. min of the highs
    band_lo, band_hi = max(lows), min(highs)
    if band_lo < band_hi:
        ax.axhspan(band_lo, band_hi, color="0.6", alpha=0.18, zorder=0)
        ax.text(len(names) - 0.5, (band_lo + band_hi) / 2,
                f"reachable at\nALL corners\n{band_lo:.0f}–{band_hi:.0f} MHz",
                ha="center", va="center", fontsize=8, color="0.25")
    else:
        ax.text(len(names) / 2 - 0.5, (max(highs) + min(lows)) / 2,
                "NO single frequency\nreachable at every corner\n"
                "→ programmable mul/div required",
                ha="center", va="center", fontsize=9, color="#b00")
    ax.set_xticks(list(xs))
    ax.set_xticklabels([CORNER_LABEL[n] for n in names], fontsize=8)
    ax.set_ylabel("DCO frequency (MHz)")
    ax.set_title("Per-corner reachable frequency range (usable monotonic codes)")
    ax.grid(True, axis="y", alpha=0.3)
    fig.tight_layout()
    fig.savefig(outpath, dpi=130)
    plt.close(fig)


def parse_traj(path):
    """Return (points=[(cycle, tune), ...], lock_cycle or None) from a TRACE log."""
    pts = []
    lock_cycle = None
    with open(path) as f:
        for line in f:
            p = line.split()
            if len(p) >= 3 and p[0] == "TRACE":
                pts.append((int(p[1]), int(p[2])))
            elif "lock_time=" in line:
                try:
                    lock_cycle = int(line.split("lock_time=")[1].split()[0])
                except (IndexError, ValueError):
                    pass
    return pts, lock_cycle


def plot_trajectory(trajs, outpath):
    """trajs: list of (label, color, points, lock_cycle)."""
    fig, ax = plt.subplots(figsize=(7.8, 4.6))
    for label, color, pts, lock_cycle in trajs:
        if not pts:
            continue
        xs = [c for c, _ in pts]
        ys = [t for _, t in pts]
        # extend the last code out to the lock point so the line reaches lock
        if lock_cycle and lock_cycle > xs[-1]:
            xs.append(lock_cycle)
            ys.append(ys[-1])
        ax.step(xs, ys, where="post", color=color, lw=1.8, label=label)
        if lock_cycle:
            ax.plot(lock_cycle, ys[-1], "o", color=color, ms=7)
            ax.annotate(f"lock @ {lock_cycle} cyc\ntune={ys[-1]}",
                        (lock_cycle, ys[-1]), color=color, fontsize=8,
                        xytext=(-4, -28), textcoords="offset points", ha="right")
    ax.axhline(20, color="0.6", ls="--", lw=1, label="target ≈ 20")
    ax.set_xlabel("reference cycles since enable")
    ax.set_ylabel("DCO tune code")
    ax.set_title("ADPLL acquisition trajectory: bang-bang vs. linear PI\n"
                 "(behavioural DCO, mul=1707, div=256)")
    ax.grid(True, alpha=0.3)
    ax.legend(loc="lower right")
    fig.tight_layout()
    fig.savefig(outpath, dpi=130)
    plt.close(fig)


def plot_ctrl_compare(lock_data, outpath):
    """lock_data: list of (label, settled_tune, lock_cycles)."""
    fig, ax = plt.subplots(figsize=(6.5, 4.2))
    labels = [d[0] for d in lock_data]
    cycles = [d[2] for d in lock_data]
    colors = ["#7570b3", "#d95f02", "#1b9e77", "#e7298a"][:len(labels)]
    bars = ax.bar(labels, cycles, color=colors, width=0.55)
    for b, d in zip(bars, lock_data):
        ax.annotate(f"{d[2]} cyc\ntune={d[1]}", (b.get_x() + b.get_width() / 2, d[2]),
                    ha="center", va="bottom", fontsize=9)
    ax.set_ylabel("lock time (reference cycles)")
    ax.set_title("Controller acquisition time (behavioural DCO, mul=1707, div=256)")
    ax.set_ylim(0, max(cycles) * 1.25)
    ax.grid(True, axis="y", alpha=0.3)
    fig.tight_layout()
    fig.savefig(outpath, dpi=130)
    plt.close(fig)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data-dir", required=True,
                    help="directory holding corner_<name>.dat files")
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--lock", action="append", default=[],
                    help="controller lock datum LABEL:TUNE:CYCLES (repeatable)")
    ap.add_argument("--traj", action="append", default=[],
                    help="trajectory datum LABEL:COLOR:path (repeatable)")
    args = ap.parse_args()
    os.makedirs(args.out_dir, exist_ok=True)

    datasets = {}
    for name in CORNER_ORDER:
        path = os.path.join(args.data_dir, f"corner_{name}.dat")
        if os.path.exists(path):
            datasets[name] = parse_dat(path)

    if datasets:
        plot_freq_vs_code(datasets, os.path.join(args.out_dir, "dco_freq_vs_code.png"))
        plot_pvt_envelope(datasets, os.path.join(args.out_dir, "dco_pvt_envelope.png"))
        # report extremes
        glob_hi = max(rows[0][1] for rows in datasets.values())
        glob_lo = min(min(f for _, f in monotonic_prefix(rows))
                      for rows in datasets.values())
        print(f"# global max freq = {glob_hi:.1f} MHz (code 0, fastest corner)")
        print(f"# global min freq = {glob_lo:.1f} MHz (slowest usable code, slowest corner)")

    if args.lock:
        lock_data = []
        for s in args.lock:
            label, tune, cyc = s.split(":")
            lock_data.append((label, int(tune), int(cyc)))
        plot_ctrl_compare(lock_data, os.path.join(args.out_dir, "ctrl_lock_compare.png"))

    if args.traj:
        trajs = []
        for s in args.traj:
            label, color, path = s.split(":", 2)
            pts, lock_cycle = parse_traj(path)
            trajs.append((label, color, pts, lock_cycle))
        plot_trajectory(trajs, os.path.join(args.out_dir, "ctrl_trajectory.png"))

    print("wrote figures to", args.out_dir)


if __name__ == "__main__":
    main()
