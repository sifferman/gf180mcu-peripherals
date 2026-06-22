#!/usr/bin/env python3
# SPDX-FileCopyrightText: © 2026 gf180mcu-peripherals Authors
# SPDX-License-Identifier: Apache-2.0
"""
Closed-loop ADPLL characterizer for the 6 variants (2 controllers x 3 DCOs).

Each DCO's *measured* SPICE frequency-vs-code curve (from gen_ring_dco_spice.py
--topology ...) drives the loop, and the two loop filters (bang-bang / linear PI) are
replicated EXACTLY from the RTL (src/adpll/controller/*.sv) + the shared lock detector
(src/adpll/adpll_lock_detect.sv). For each (controller x DCO) it reports settle time,
settled code, steady-state jitter, and lock success, and plots them.

Validation: with the analytic behavioural curve f(tune) = 1 / (2*(1000+100*tune) ps) -- the
same model the RTL behavioural DCO uses -- this reproduces the RTL sims (bang-bang 7938
ref-cycles / tune 21, linear 4610 / tune 20), so the Python loop is faithful to the RTL.
"""
import argparse
import os


def clamp(v, lo, hi):
    return lo if v < lo else (hi if v > hi else v)


class LockDetect:
    """Mirrors adpll_lock_detect.sv: declares lock after MinSamplesForLock in-band samples."""
    def __init__(self, band_radius, min_samples_for_lock):
        self.band_radius, self.min_samples_for_lock = band_radius, min_samples_for_lock
        self.band_center, self.in_band_count, self.lock = 0, 0, False

    def sample(self, tuning_sample):
        if abs(tuning_sample - self.band_center) <= self.band_radius:
            if self.in_band_count == self.min_samples_for_lock:
                self.lock = True
            else:
                self.in_band_count += 1
        else:
            self.band_center, self.in_band_count, self.lock = tuning_sample, 0, False
        return self.lock


def run_loop(freq_of_code, bits, ctrl, mul, div, ref_ns, max_windows=4000, post_lock=40):
    """One window = div reference cycles; measured = DCO edges in a window = f * div * Tref,
    using the tune that was ACTIVE during that window (one-window measurement latency, as in
    the RTL adpll_freq_counter). Free-runs `post_lock` windows after lock so steady-state jitter is the
    settled limit-cycle spread, not the acquisition tail."""
    tune_max = (1 << bits) - 1
    window_s = div * ref_ns * 1e-9
    ALPHA, BETA, LOCKBAND = 10, 8, 2
    acc_max = tune_max << BETA

    integ = acc = 0
    tune = tune_active = 0
    lock = LockDetect(band_radius=(1 if ctrl == "bangbang" else LOCKBAND), min_samples_for_lock=8)
    traj = []
    lock_window = None

    for w in range(max_windows):
        m = round(freq_of_code(tune_active) * window_s)     # count reflects the active tune
        if ctrl == "bangbang":
            d = 1 if m > mul else (-1 if m < mul else 0)
            integ = clamp(integ + d, 0, tune_max)           # IntegralGain=1
            tune = clamp(integ + d, 0, tune_max)            # ProportionalGain=1
            watched = integ                                  # detector watches the integral code
        elif ctrl == "linear":
            e = m - mul
            acc = clamp(acc + e, 0, acc_max)                # anti-windup
            tune = clamp((e >> ALPHA) + (acc >> BETA), 0, tune_max)
            watched = tune                                   # detector watches the output code
        else:
            raise ValueError(ctrl)
        traj.append(tune)
        tune_active = tune                                   # new code takes effect next window
        if lock.lock is False and lock.sample(watched) and lock_window is None:
            lock_window = w + 1
        elif lock_window is not None:
            lock.sample(watched)
        if lock_window is not None and w >= lock_window + post_lock:
            break

    locked = lock_window is not None
    settle_windows = lock_window if locked else max_windows
    tail = traj[lock_window:] if locked and len(traj) > lock_window else traj[-16:]
    settle_cyc = settle_windows * div
    return {
        "locked": locked,
        "settle_cyc": settle_cyc,
        "settle_us": settle_cyc * ref_ns / 1000.0,
        "tune": tune,
        "freq_mhz": freq_of_code(tune) / 1e6,
        "jitter_lsb": (max(tail) - min(tail)) if tail else 0,   # settled limit-cycle spread
        "traj": traj,
    }


def load_curve(path, bits):
    """Read a gen_ring_dco_spice sweep (.dat) -> piecewise-linear freq(code) over 0..2^bits-1.
    Uses the raw measured points (including any non-monotonic multi-mode folds)."""
    pts = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            p = line.split()
            if len(p) >= 2 and p[1] != "FAIL":
                pts.append((int(p[0]), float(p[1]) * 1e6))   # MHz -> Hz
    pts.sort()
    xs = [c for c, _ in pts]
    ys = [f for _, f in pts]

    def f(code):
        code = clamp(code, xs[0], xs[-1])
        for i in range(len(xs) - 1):
            if xs[i] <= code <= xs[i + 1]:
                t = (code - xs[i]) / (xs[i + 1] - xs[i]) if xs[i + 1] != xs[i] else 0
                return ys[i] + t * (ys[i + 1] - ys[i])
        return ys[-1]
    return f


def analytic_curve(code):
    """The RTL behavioural DCO: half period = (1000 + 100*tune) ps."""
    return 1.0 / (2.0 * (1000 + 100 * code) * 1e-12)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bits", type=int, default=6)
    ap.add_argument("--mul", type=int, default=1707)
    ap.add_argument("--div", type=int, default=256)
    ap.add_argument("--ref-ns", type=float, default=40.0)     # 25 MHz reference
    ap.add_argument("--target-code", type=int, default=24,
                    help="per-DCO target: aim each loop at its own freq(target-code) so all "
                         "lock despite the disjoint frequency ranges (mul set per DCO)")
    ap.add_argument("--curve", action="append", default=[], help="NAME:path.dat (repeatable)")
    ap.add_argument("--validate", action="store_true", help="check vs the analytic RTL curve")
    ap.add_argument("--out-dir", default=".")
    ap.add_argument("--plot", action="store_true")
    args = ap.parse_args()

    if args.validate:
        print("# validation against RTL behavioural curve (expect bb~7938/tune21, lin~4610/tune20)")
        for ctrl in ("bangbang", "linear"):
            r = run_loop(analytic_curve, 7, ctrl, 1707, 256, 40.0)
            print(f"  {ctrl:9s} settle={r['settle_cyc']} cyc  tune={r['tune']}  "
                  f"jitter={r['jitter_lsb']} LSB  locked={r['locked']}")
        return

    curves = {}
    for spec in args.curve:
        name, path = spec.split(":", 1)
        curves[name] = load_curve(path, args.bits)

    # The 3 DCOs have disjoint frequency ranges, so give each its own reachable target:
    # mul set so the target == that DCO's freq at target-code (a mid-range monotonic point).
    window_s = args.div * args.ref_ns * 1e-9
    mul_of = {dco: max(1, round(curves[dco](args.target_code) * window_s)) for dco in curves}

    rows = []
    print(f"# 6-variant characterization  bits={args.bits} div={args.div} ref={args.ref_ns}ns "
          f"target-code={args.target_code} (per-DCO mul; ranges are disjoint)")
    print(f"# {'variant':22s} {'tgt_MHz':>8} {'mul':>5} {'settle_cyc':>10} {'settle_us':>10} {'tune':>5} {'freq_MHz':>9} {'jitter':>7} {'lock':>5}")
    for dco in curves:
        tgt = curves[dco](args.target_code) / 1e6
        for ctrl in ("bangbang", "linear"):
            r = run_loop(curves[dco], args.bits, ctrl, mul_of[dco], args.div, args.ref_ns)
            rows.append((f"{ctrl}x{dco}", ctrl, dco, r))
            print(f"  {ctrl+' x '+dco:22s} {tgt:>8.1f} {mul_of[dco]:>5} {r['settle_cyc']:>10} {r['settle_us']:>10.2f} "
                  f"{r['tune']:>5} {r['freq_mhz']:>9.1f} {r['jitter_lsb']:>7} {str(r['locked']):>5}")

    if args.plot:
        plot(rows, curves, args.out_dir, args.target_code)


def plot(rows, curves, out_dir, target_code=24):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    os.makedirs(out_dir, exist_ok=True)
    CTRLC = {"bangbang": "#7570b3", "linear": "#d95f02"}
    DCOLS = {"binary": "-", "thermometer": "--", "muxtap": ":"}
    DCOC = {"binary": "#1b9e77", "thermometer": "#e7298a", "muxtap": "#666600"}
    dcos = list(curves.keys())
    short = lambda lbl: lbl.replace("bangbang", "bb").replace("linear", "lin").replace("x", "×")

    fig, ax = plt.subplots(2, 2, figsize=(12, 8.5))

    # (0,0) DCO freq-vs-code curves (the SPICE differentiator)
    codes = list(range(0, 64))
    for dco in dcos:
        ax[0, 0].plot(codes, [curves[dco](c) / 1e6 for c in codes], DCOLS[dco],
                      color=DCOC[dco], lw=1.8, label=dco)
    ax[0, 0].axvline(target_code, color="0.5", lw=1, ls="-.")
    ax[0, 0].annotate("target code", (target_code, ax[0, 0].get_ylim()[1]*0.9), fontsize=8,
                      rotation=90, va="top", ha="right", color="0.4")
    ax[0, 0].annotate("binary folds →\n(multi-mode)", (33, 403), fontsize=7.5, color=DCOC["binary"])
    ax[0, 0].set_title("SPICE DCO frequency vs. tune code (TT, 6-bit)")
    ax[0, 0].set_xlabel("tune code"); ax[0, 0].set_ylabel("DCO frequency (MHz)")
    ax[0, 0].legend(); ax[0, 0].grid(alpha=.3)

    labels = [short(r[0]) for r in rows]
    xs = list(range(len(rows)))
    cols = [CTRLC[r[1]] for r in rows]

    # (0,1) settle time bars
    bars = ax[0, 1].bar(xs, [r[3]["settle_cyc"] for r in rows], color=cols)
    for b, r in zip(bars, rows):
        ax[0, 1].annotate(f"{r[3]['settle_us']:.0f}µs", (b.get_x()+b.get_width()/2, r[3]["settle_cyc"]),
                          ha="center", va="bottom", fontsize=7)
    ax[0, 1].set_xticks(xs); ax[0, 1].set_xticklabels(labels, rotation=35, ha="right", fontsize=8)
    ax[0, 1].set_title("Settle time (reference cycles)"); ax[0, 1].grid(axis="y", alpha=.3)
    ax[0, 1].legend(handles=[plt.Rectangle((0,0),1,1,color=CTRLC["bangbang"]),
                             plt.Rectangle((0,0),1,1,color=CTRLC["linear"])],
                    labels=["bang-bang", "linear PI"], fontsize=8)

    # (1,0) acquisition trajectories — colour = controller, linestyle = DCO
    for r in rows:
        ax[1, 0].plot(r[3]["traj"], color=CTRLC[r[1]], ls=DCOLS[r[2]], alpha=.85, lw=1.4,
                      label=short(r[0]))
    ax[1, 0].axhline(target_code, color="0.6", lw=1, ls="-.")
    ax[1, 0].set_title("Acquisition trajectory (tune vs. window)\n"
                       "bang-bang staircases overlap (DCO-independent); linear slews per curve")
    ax[1, 0].set_xlabel("measurement window"); ax[1, 0].set_ylabel("tune code")
    ax[1, 0].legend(fontsize=7, ncol=2); ax[1, 0].grid(alpha=.3)

    # (1,1) steady-state jitter bars
    bars = ax[1, 1].bar(xs, [r[3]["jitter_lsb"] for r in rows], color=cols)
    ax[1, 1].set_xticks(xs); ax[1, 1].set_xticklabels(labels, rotation=35, ha="right", fontsize=8)
    ax[1, 1].set_title("Steady-state jitter (settled code spread, LSB)"); ax[1, 1].grid(axis="y", alpha=.3)

    fig.suptitle("ADPLL 6-variant characterization — SPICE-curve-driven loop (gf180 3v3, TT)", fontsize=13)
    fig.tight_layout()
    out = os.path.join(out_dir, "pll_6variant.png")
    fig.savefig(out, dpi=130)
    print("wrote", out)


if __name__ == "__main__":
    main()
