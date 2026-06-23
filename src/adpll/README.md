<!-- SPDX-License-Identifier: Apache-2.0 -->
# `adpll` — all-digital ring-oscillator PLL

A reusable, all-standard-cell digital PLL for GF180MCU 3.3 V. It is a programmable-ratio
frequency synthesizer: the controller tunes a ring DCO so that

> **F_DCO = (mul / div) · F_clk_i**

where `mul` (the feedback-multiply ratio N) and `div` (the reference divider M) are runtime
inputs, set over Ethernet through a CSR. It is **observe-only** — it does not clock the core;
`clk_o` and `lock_o` are routed to the analog observation pads.

The design is grounded in the ADPLL literature with per-decision citations and quotes; the
variant survey, the citations, and the simulation results live in
[`../../docs/adpll_survey.md`](../../docs/adpll_survey.md).

## Layout

```
adpll_freq_counter.sv   shared: Gray-CDC DCO-edge counter over a runtime-length measurement window
adpll_lock_detect.sv    shared: lock detector (tuning sample stays in-band for MinSamplesForLock)
adpll_tdc.sv            shared (phase loop): time-to-digital converter -- sub-cycle DCO phase
controller/
  adpll_controller_bangbang.sv    bang-bang PI loop filter (1-bit/sign frequency error)
  adpll_controller_linear.sv      linear PI loop filter (multi-bit error, power-of-two gains)
  adpll_controller_gearshift.sv   adaptive-step bang-bang (binary-search acquisition; Da Dalt)
  adpll_controller_phase.sv       phase-domain type-II PI (TDC + phase accumulators) -- true phase lock
dco/
  ring_dco_binary.sv        binary-weighted delay-select ring (the default)
  ring_dco_thermometer.sv   unit-weighted (thermometer) ring, monotonic by construction
  ring_dco_muxtap.sv        variable-length ring (tap mux tree)
  ring_dco_coarsefine.sv    two-bank coarse + fine ring (wide range + fine resolution)
  gen_ring_dco_spice.py     emit a SPICE deck for a ring DCO and sweep tune codes in ngspice
```

A controller + a DCO form a loop; the shared blocks are common to every controller. All
controllers share one port interface and all DCOs share another, so they are drop-in swappable
(3 frequency-locked controllers × 4 DCOs = the 12-variant matrix). The **bang-bang**, **linear**,
and **gear-shift** controllers are FLLs (they lock average frequency via the edge counter); the
**phase** controller is a true PLL — it adds the TDC and reference/variable phase accumulators to
null *phase*, not just frequency.

## Sim/synth views (one macro: `SYNTHESIS`)

A ring oscillator is a zero-delay combinational loop that an event-driven simulator cannot
evaluate, so each DCO has two views selected by `SYNTHESIS` (the project's single sim/synth
macro, per `../../docs/style.md`):

- `` `ifdef SYNTHESIS `` — the structural gf180-cell ring (`nand2`/`inv`/`mux2`, all
  `keep`/`dont_touch`). yosys-slang defines `SYNTHESIS=1`, so synthesis/PnR get this view.
- `` `else `` — a behavioural `#`-delay clock model for digital sim (no macro needed).

The real frequency-vs-code curve only exists after parasitic extraction, so characterize the
DCO in SPICE, not in STA.

## Verify

```sh
make sim-adpll          # iverilog: DCO oscillates + the loop locks (behavioural DCO)
make sim-adpll-survey   # compare the FLL controller variants (bang-bang/linear/gearshift)
make sim-adpll-matrix   # all 12 FLL variants (3 controllers x 4 DCOs): lock time + settled tune
make sim-adpll-phase    # phase-domain ADPLL (TDC + phase accumulators): true phase lock
make sim-adpll-array    # CSR framework: program all 12 PLLs over AXI4-Lite, poll lock, test obs mux
make dco-spice          # ngspice freq-vs-code at the typical corner
make dco-spice-corners  # ngspice freq-vs-code across SS/TT/FF PVT corners (run regularly)
```

`gen_ring_dco_spice.py --topology {binary,thermometer,muxtap,coarsefine}` emits the SPICE deck
for any DCO variant (coarse/fine also takes `--fine-bits`).

ngspice **>= 42** is required for the gf180 BSIM4 models (the system ngspice-34 rejects
`mulu0` etc.); override with `make dco-spice NGSPICE=/path/to/ngspice`.

## On the chip: the 12-PLL array

All 12 FLL macros (3 controllers × 4 DCOs) are integrated into `chip_core` as `adpll_array`
(`adpll_array.sv`), each wired to `adpll_array_csr` at `0x2000_0000`. A host programs every PLL
independently over Ethernet and reads its lock/tune; PLL `i` occupies four 32-bit words at byte
offset `i*0x10` (`CTRL`/`MUL`/`DIV`/`STATUS`), and `OBS_SEL` at `0xC0` picks which PLL's DCO clock
+ lock drive the observation mux. PLL 0 is `bangbang_binary` at the original single-PLL offsets.

- **Control/observe over the CSR, no extra pads.** The 12 PLLs add zero pins — control rides the
  Ethernet→AXI→CSR path and observability is the per-PLL `STATUS` (lock + tune). The CSR-selected
  observation mux is *not* brought to a pad: the gf180 analog pads can't carry routed digital
  (driving a DCO clock onto them opens the sink in LVS), and the padring has no spare digital pad.
- **Rings preserved in PnR** by `(* keep *)`/`(* dont_touch *)` on every DCO's cells; each ring's
  free-running DCO clock is left undefined as an SDC clock (its combinational loop has no valid
  clock-tree root) and its Gray-coded CDC into the core clock is handled in RTL.
- **Size for all corners**: the rings swing ~2.4× across PVT, so the programmable `mul`/`div`
  picks a reachable ratio per chip (corner data in `../../docs/adpll_survey.md`).
