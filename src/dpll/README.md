<!-- SPDX-License-Identifier: Apache-2.0 -->
# `dpll` — digital ring-oscillator PLL (DCO + frequency-locked loop)

A reusable, standalone digital PLL for GF180MCU 3.3 V. The oscillator is a digitally
controlled ring (binary-weighted mux-chain delay), tuned by a frequency-locked loop. It is
an **observe-only** block: it does **not** clock the core — control comes from a CSR (set over
Ethernet in this chip) and `clk_o`/`lock` are meant for the analog observation pads.

## Files
| file | role |
|---|---|
| `ring_dco.sv` | binary-weighted ring oscillator. `NAND2` gate + per-bit weighted inverter-pair delay segments selected by `mux2`. Structural gf180 cells (`nand2_2`/`inv_2`/`mux2_2`) with `(* keep *)`/`(* dont_touch *)` for synth/SPICE; a `FUNCTIONAL` behavioural clock model for digital sim. |
| `dpll_ctrl.sv` | bang-bang frequency-locked loop. Gray-coded DCO edge counter CDC'd into the reference clock domain; per-window count vs `target_i`; tune ±1 per window; lock asserts when the tune code stays within a ±1 band for `LockWindows` windows. |
| `gen_ring_dco_spice.py` | emits a SPICE deck for the ring from the PDK cell subckts and sweeps tune codes through ngspice (freq-vs-code). |

## Verify
```sh
make sim-dpll                       # iverilog: DCO oscillates + FLL locks (behavioural DCO)
make dco-spice NGSPICE=/path/ngspice # ngspice freq-vs-code sweep (needs ngspice >= 42 for the
                                    # gf180 BSIM4 models; system ngspice-34 is too old)
```
A real ring oscillator has no period in zero-delay RTL, so digital sim uses the behavioural
DCO; true frequency-vs-code comes from SPICE. Typical-corner SPICE shows clean monotonic tuning
in the low-code range (e.g. ~337 MHz at code 0 → ~184 MHz at code 16); high codes exhibit
multi-mode oscillation in the long ring (multiple circulating wavefronts) — keep tuning in the
monotonic region, or constrain stage count / add single-edge startup for production use.

## Integrating into a chip (TODO, not yet wired into chip_top)
- Drive `enable_i`/`target_i` (and read `lock_o`) from a memory-mapped CSR.
- Bring `ring_dco.clk_o` and `dpll_ctrl.lock_o` to the two analog pads.
- Preserve the ring in PnR: `SYNTH_KEEP_HIERARCHY`/keep modules for `ring_dco`,
  `RSZ_DONT_TOUCH` the oscillator nets, and extract the ring's frequency in SPICE rather than
  trusting STA on the combinational loop.
