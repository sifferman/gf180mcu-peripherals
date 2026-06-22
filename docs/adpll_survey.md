# ADPLL design survey (gf180mcu, all-standard-cell)

A survey of all-digital PLL (ADPLL) building-block variants for the `src/adpll/` subsystem,
grounded in `reference/adpll/`. Every block is built **only** from gf180mcu standard cells
(so it goes through the normal digital flow and is SPICE-characterizable like any cell);
genuinely analog blocks (LC tank, MOS varactors, current-DAC bias, stochastic/mismatch TDC)
are intentionally excluded.

## References

- **[Kratyuk2007]** V. Kratyuk, P. K. Hanumolu, U.-K. Moon, K. Mayaram, "A Design Procedure
  for All-Digital Phase-Locked Loops Based on a Charge-Pump Phase-Locked-Loop Analogy,"
  *IEEE TCAS-II*, vol. 54, no. 3, pp. 247–251, Mar. 2007.
- **[Hanumolu2007]** P. K. Hanumolu, G.-Y. Wei, U.-K. Moon, K. Mayaram, "Digitally-Enhanced
  Phase-Locking Circuits," *IEEE CICC*, pp. 361–368, 2007.
- **[Staszewski2006]** R. B. Staszewski, P. T. Balsara, *All-Digital Frequency Synthesizer in
  Deep-Submicron CMOS*, Wiley, 2006.
- **[Razavi]** B. Razavi, *Design of CMOS Phase-Locked Loops* (type-II loop dynamics,
  damping/phase-margin background).
- **[DaDalt2004]** J. Lee, K. S. Kundert, B. Razavi, "Analysis and modeling of bang-bang
  clock and data recovery circuits," *IEEE JSSC*, vol. 39, no. 9, 2004 ([Kratyuk2007] ref [12]).

## Architecture

A programmable-ratio frequency synthesizer, the canonical ADPLL pipeline
([Kratyuk2007] Fig. 2 / [Hanumolu2007] Fig. 4):

```
            +-------------------+   +-----------+   +-----+
  F_clk_i ->| adpll_freq_meas   |-->| loop      |-->| ring|--> clk_o (F_DCO)
            | (edge count over  |   | filter    |   | DCO |--+
            |  div_i cycles)    |   |(adpll_ctrl|   +-----+  |
            +-------------------+   | _*)       |            |
                    ^               +-----------+            |
                    +----------- DCO edges (Gray-CDC) -------+
```

At lock `measured == mul`, so **F_DCO = (mul / div) · F_clk_i**: `mul` is the
feedback-multiply ratio N and `div` is the reference divider M. Both are **runtime inputs**
(set over Ethernet through a CSR) — programmability is itself the stated ADPLL advantage:
[Hanumolu2007 §III] *"since the DPLL's loop dynamics are set by DLF coefficients, loop
characteristics can be easily programmed and are also immune to process, voltage, and
temperature (PVT) variations."* A second-order (type-II) loop suffices: [Kratyuk2007 §IV]
*"In all-digital PLLs, this problem does not exist, and a second-order PLL is sufficient."*

### Reusable blocks (one module per file, no swiss-army `generate if`s)

| module | role |
|---|---|
| `adpll_freq_meas` | Gray-coded DCO-edge counter sampled over a runtime `div_i`-cycle window; frequency-to-digital front end. Shared by all controllers. |
| `adpll_lock_detect` | declares lock when the watched control code holds a ±`Band` window for `LockWindows` samples. Shared. |

## DCO variants (interface `enable_i`, `tune_i[NumTuneBits-1:0]`, `clk_o`)

All three are ring oscillators (one NAND gate gives the single inversion; `enable_i` gates
it), built from `nand2`/`inv`/`mux2` cells with `keep`/`dont_touch`. A ring is used over an
LC DCO because LC needs an inductor + MOS varactors ([Staszewski2006] §2.1–2.3) — not
standard cells; the accepted cost is phase noise: ring synthesizers *"are all based on a ring
oscillator structure which inherently features relatively poor phase-noise characteristics"*
[Staszewski2006]. Tuning is by switching **delay elements** (std-cell muxes) rather than the
textbook ring method of steering **bias current** ([Kratyuk2007 §II] *"frequency tuning can be
performed by digitally turning on and off bias current sources"*), which would need an analog
current DAC.

| module | architecture | trade-off |
|---|---|---|
| `ring_dco` | binary-weighted delay select (segment i = 2^i pairs, N muxes) | smallest (N muxes); binary weighting can be non-monotonic at major carries |
| `ring_dco_thermometer` | unit-weighted (thermometer) delay select, 2^N identical stages | monotonic by construction; mismatch can be averaged with DEM [Staszewski2006 §3.5]; costs 2^N cells |
| `ring_dco_muxtap` | variable ring **length** via a 2^N:1 tap mux tree (Kajiwara–Nakagawa style) | re-routes feedback instead of inserting delay; fixed mux-tree delay floor |

## Controller variants (interface `clk_i,rst_ni,enable_i,mul_i,div_i,dco_clk_i → tune_o,lock_o`)

Both reuse `adpll_freq_meas` + `adpll_lock_detect`; only the loop filter differs. Both are
proportional-integral (PI): [Kratyuk2007 §IV-C] *"A digital equivalent of an analog loop
filter consists of a proportional path with a gain α and an integral path with a gain β."*

| module | loop filter | source |
|---|---|---|
| `adpll_ctrl` | **bang-bang** PI: 1-bit (sign) error, integer gains | [Hanumolu2007 §IV-A] *"A DFF simply detects the sign of the phase error and hence serves as a 1-bit TDC"*; bang-bang dynamics [DaDalt2004] |
| `adpll_ctrl_linear` | **linear** PI: multi-bit error, power-of-two α/β shifts, anti-windup | full [Kratyuk2007] procedure; gains quantized to powers of two ([Kratyuk2007 §V] *"α ≈ 2⁻³, β ≈ 2⁻⁷"*) |

## Results

### Controller comparison — `make sim-adpll-survey` (behavioural DCO, mul=1707, div=256, target tune≈20)

| controller | settled tune | lock time (ref cycles) | notes |
|---|---|---|---|
| bang-bang PI | 21 | 7937 | no gain matching; clean ±1 LSB limit cycle |
| linear PI | 20 | 4609 | faster + exact, **but** required a tiny proportional gain (`AlphaShift=10`) — a larger α slams tune to a rail and oscillates rail-to-rail on a coarse DCO (huge cold-start error) |

Finding: the linear PI is faster and more accurate *once gains are matched to K_DCO*, but on
a coarse DCO it needs that care (small α / integral-dominant acquisition); the bang-bang
needs none and is inherently PVT-robust — which is why bang-bang dominates coarse ADPLLs.

### DCO across PVT corners — `make dco-spice-corners` (ngspice ≥ 42, `ring_dco`, 7-bit)

| code | SS (ss/3.0 V/125 °C) | TT (typ/3.3 V/25 °C) | FF (ff/3.6 V/−40 °C) |
|---|---|---|---|
| 0 (fastest) | 209.5 MHz | 338.5 MHz | 499.6 MHz |
| 64 | 146.3 | 226.9 | 327.6 |
| 127 | 215.6 ⚠ | 221.9 | 244.6 |

Findings (confirming the textbook):
1. **~2.4× PVT spread** at a fixed code (209→500 MHz) — Staszewski's "highly nonlinear
   frequency vs. voltage." This is why an open-loop frequency setting is impossible and a
   closed loop with programmable `mul/div` is required.
2. **No single fixed target is reachable at every corner**: FF's slowest setting (code 127,
   244 MHz) is above SS's fastest (code 0, 210 MHz). The programmable `mul/div` (chosen
   per-chip after sensing the corner) is what makes "works at all corners" achievable — the
   loop locks to whatever ratio is reachable at the actual silicon corner.
3. **High codes go multi-mode** (SS: code 127 reads 215 MHz > code 64's 146 MHz, non-monotonic):
   a long ring sustains multiple circulating waves. Usable monotonic range is the low codes.

Corner sims are run regularly via `make dco-spice-corners` as the design evolves.
