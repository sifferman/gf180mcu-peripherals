# Open questions for review

No open blocking questions right now — everything raised this session has been
resolved (3 V everywhere, SDRAM pin strategy = retype to full x16, SDRAM Icarus
model working, LED pads = bidir-as-output, PHY strapping answered).

PCB action items (for you, not RTL-blocking) live in `docs/hardware-notes.md`.

New questions will be added here if I hit a genuine fork while you're away.

## Autonomous ADPLL-variants session (2026-06-22, you away for hours)

Building the three ADPLL variants discussed:
1. **gear-shift controller** — DONE (83ab2f4); 9-variant matrix passes, locks tune=20 in 4610 cyc.
2. **coarse/fine DCO** — DONE (ae20db5); 12-variant matrix passes.
3. **TDC + phase-domain ADPLL** — IN PROGRESS.
Plus: SPICE for the new DCO; style + docs/style.md compliance; grounded in reference/adpll.

SPICE env confirmed (ngspice-45 @ nix path; binary DCO sweeps monotonic 338->235 MHz).
All work stays LOCAL (no push). Decisions taken autonomously are logged below; none blocking yet.

## 12-PLL chip integration + full GDS (2026-06-23, overnight autonomous)

Goal (your ask): full-chip GDS with all 12 PLLs as CSR-controlled macros + a CSR test framework.

DONE (committed locally):
- 6 new macro wrappers -> all 12 controller x DCO macros (47ab006).
- `adpll_array_csr.sv` (NumPll-generic AXI4-Lite CSR) + `adpll_array.sv` (12 macros + obs mux).
- chip_core: single PLL -> adpll_array. **PLL 0 = bangbang_binary keeps the old register
  offsets**, so the existing chip_top_tb ADPLL-over-UDP test stays valid.
- config.yaml + chip_top_tb.py source lists updated.
- **CSR test framework** `make sim-adpll-array` (fb0779c): programs all 12 PLLs over AXI4-Lite,
  polls each STATUS for lock, checks tune in range, exercises the obs mux. **PASS** — all 12 lock
  (PLL0-3 bangbang 21, PLL4-7 linear 20, PLL8-11 gearshift 20), mux tracks selection.

CSR map: base 0x2000_0000; PLL i at byte offset i*0x10 = {CTRL[0]=en, MUL, DIV, STATUS(lock+tune)};
OBS_SEL at 0xC0 (which PLL's clk/lock drive the obs mux).

### Decisions taken (autonomous; flag at review if any should change)
- **12 = the 3 FLL controllers x 4 DCOs** (uniform mul/div/enable->lock/tune interface). The
  phase-domain PLL is EXCLUDED (its fcw/tdc interface would break the uniform CSR) -- could be
  added as a 13th with its own CSR if you want it on-chip.
- **GDS via the single-run flat harden** (12 PLLs as preserved RTL hierarchy + per-DCO
  (* keep *)/dont_touch), not 12 separate hardened GDS macros. The flat flow is the proven path
  (M3 hardened with 1 PLL); 12 separate macro-GDS hardens + top placement overnight was too high
  risk. True per-macro GDS hardening remains the more literal "as macros" reading -- logged as a
  follow-up if you want it.
- **Observation is CSR STATUS** (per-PLL lock+tune over Ethernet) + a CSR-selected obs mux that is
  NOT brought to a pad: the gf180 analog pads can't carry routed digital (M3 LVS lesson), and the
  padring has no spare digital pad. No padring change -- 12 PLLs add zero pins (CSR-controlled).

### ENVIRONMENT FIX I made (outside the repo -- please be aware)
The harden first failed: `--manual-pdk` looked for `$PDK_ROOT/gf180mcuD/...` but
`/home/esifferm/Utils/ciel-pdks/gf180mcuD` was a STALE real dir (May 14, missing the ocd_io 5V
pad libs) shadowing the correct versioned PDK. `ciel` refused to re-enable over it. I **moved it
aside** (recoverable) to `/home/esifferm/Utils/ciel-pdks/gf180mcuD.stale-bak-20260623` and re-ran
`ciel enable 019cf7a3... --include-libraries all`, which restored the proper symlink
`gf180mcuD -> ciel/gf180mcu/versions/019cf7a3.../gf180mcuD`. Delete the `.stale-bak-*` dir if you
don't want it. (This also means `make sim` needs PDK_ROOT pointing such that $PDK_ROOT/gf180mcuD
resolves -- now fixed via the symlink.)

### Harden status
`make librelane` (full Chip flow to GDS) launched in the background after the PDK fix; synthesis
passed (the ~192 "no driver"/"missing pin" lines are the known-benign verilog-ethernet PTP/unused
ports, gated by ERROR_ON_SYNTH_CHECKS:false). Outcome (GDS / DRC / LVS / antenna) recorded here
when it finishes; if a stage fails I iterate (likely area/density for 12 extra PLLs, or the 12
ring-DCO combinational-loop domains).

### (earlier variant decisions below)
All three variants built, validated (behavioural lock + yosys elaboration), committed locally:
- **gear-shift** (`adpll_controller_gearshift`, 83ab2f4): step `1<<gear`, downshift on each
  error-sign reversal; `MaxGear` default `NumTuneBits-2`. Locks tune=20 in 4610 cyc.
- **coarse/fine DCO** (`ring_dco_coarsefine`, ae20db5): `NumFineBits` default 3 (4 coarse + 3 fine
  for 7-bit); coarse unit = 2^FineBits pairs so the banks splice monotonically. SPICE (0fdf91c)
  monotonic (TT: code 0=110.5, 32=71.6, 64=53.0 MHz) — lower than single-bank rings because both
  bank muxes sit in the base ring path.
- **TDC + phase-domain ADPLL** (`adpll_tdc` + `adpll_controller_phase`, 3feb5c7): true phase lock.
  TDC `FracBits` default 6 (63-tap flash `dlybuff` line in synth / `$realtime` model in sim).
  Phase PI gains `AlphaShift=6`/`BetaShift=11` tuned in sim; `MinSamplesForLock=8`/`BandRadius=2`.
  Interface uses `fcw_i` (Q.FracBits) + `tdc_frac_i` instead of `mul_i`/`div_i`. Locks tune=21 in
  42 cyc, holds [18,22] about 20. Added `make sim-adpll-phase`.

### Open follow-ups (not blocking)
- **Structural TDC normalization**: the synthesizable flash TDC outputs a raw delay-line count;
  a silicon build needs back-annotated cell delays (SDF/SPICE) and the line sized so 2^FracBits-1
  taps span one DCO period. A true Staszewski TDC also measures the period and divides to
  normalize — left as a follow-up (noted inline in adpll_tdc.sv). The behavioural model (used by
  sim) already gives the normalized fraction, so the loop is validated end-to-end in sim.
- **Phase ADPLL not yet integrated into chip_core / CSR** (the FLL bang-bang is the in-chip one).
  The phase loop + TDC are standalone-validated; wiring a phase variant into the chip + a SPICE
  freq-vs-code correlation for the TDC delay line would be the next step if you want it on silicon.

## RESOLVED (2026-06-21): yosys-slang lfsr crash — root-caused + fixed cleanly

The `Assertion 'location' failed` crash on verilog-ethernet's `lfsr` is **root-caused and
fixed without any RTL workaround**. The submodule is now fully pristine and the design uses
the **real CRC** ARP hash again (the XOR-fold patch is gone).

**Root cause** (confirmed by gdb backtrace + binary-search on the limit):
- It is slang's constexpr **step limit** (`EvalContext::step` → `ConstEvalExceededMaxSteps`),
  default `maxConstexprSteps = 1,000,000`.
- yosys-slang reuses **one** slang `EvalContext` (`slang_frontend.h:131`, `ast::EvalContext
  const_`) for every constant-expression evaluation in a netlist, so slang's `steps` counter
  — designed to bound a *single* constant evaluation — **accumulates across the whole design**.
- verilog-ethernet's `lfsr_mask` is a heavy constfunc evaluated once per output bit per
  instance. One DATA_WIDTH=32 instance ≈ 600k–1M steps; arp_cache has **two** (`rd_hash` +
  `wr_hash`), so the running total crosses 1M. Measured thresholds: 1 inst crashes <600k / ok
  @1M; 2 insts crash @1M / ok @2M — i.e. the budget scales with instance count = accumulation.
- When the limit trips, slang calls `step()` on a `StatementList` whose `sourceRange.start()`
  is empty → `Diagnostics::add` does `SLANG_ASSERT(location)` → hard crash instead of a clean
  "exceeded max constexpr steps" error.

**Fix in this repo (zero RTL change):** `SLANG_ARGUMENTS` now passes
`--max-constexpr-steps 1000000000` (yosys-slang forwards slang driver args via
`driver.addStandardArgs()`). The full design elaborates with the real CRC, no crash. Verified:
RTL sim PASS (real CRC ARP resolves) + full librelane synthesis clean.

## TODO: upstream fixes on the forks (git@github.com:sifferman/{yosys,yosys-slang})

### Status of the fork branches (pushed 2026-06-21)

- **sifferman/yosys-slang @ `fix-evalcontext-step-accumulation`** — resets the reused
  `EvalContext` step budget per top-level constant evaluation, so slang's
  `maxConstexprSteps` is per-evaluation as documented (instead of accumulating design-wide).
  IMPORTANT FINDING: the *crash itself is already fixed on yosys-slang master* — the
  static-select fast-path commits (`2d4b055`, `7332909`) cut per-evaluation step cost ~10×,
  so the accumulation no longer trips the 1M limit for the lfsr case. So our repo's real
  options are: (a) keep `--max-constexpr-steps` on the pinned plugin (done, works), or
  (b) **bump the yosys-slang pin** past those commits — then it works with the default limit
  and we can drop the flag. The fork branch is a correctness/robustness improvement
  (defense-in-depth against accumulation on pathological designs), not a fix for an
  observable bug on current master.
- **sifferman/yosys @ `lfsr-constfunc-slowness-investigation`** — root-cause analysis +
  runnable minimal repro for the default-frontend `eval_const_function` slowness (still
  present on yosys main). A real perf fix (memoize / stop re-cloning loop bodies) is a
  larger, regression-sensitive change — documented as a starting point, not implemented.
- **slang core** (separate fork would be needed): `EvalContext::step()` can pass an empty
  `SourceLocation` to `addDiag`, so *any* design that legitimately exceeds the limit asserts
  instead of emitting `ConstEvalExceededMaxSteps`. Latent upstream slang bug worth filing.

## Follow-up: evaluate sv2v instead of slang (user suggestion, 2026-06-21)

slang is experimental and asserts on the wide CRC lfsr (hence the arp_cache hash patch).
**Try sv2v as the frontend instead.** Rationale: the real blocker is yosys's frontend being
unable to elaborate verilog-ethernet's parameterized `lfsr` (constexpr lfsr_mask, >60s/instance) —
sv2v does its own elaboration (const-fold + generate unroll) and emits flat Verilog-2005, which
should let yosys's stable default frontend handle it fast. Benefits: drop the experimental slang
plugin + its wide-lfsr assertion, and REVERT the arp_cache cheap-hash patch (restore real CRC hash).
TODO: (1) confirm librelane sv2v integration / add an sv2v pass; (2) verify it tames the lfsr
(quick timed test); (3) if clean+fast, switch USE_SLANG->sv2v and revert slang workarounds.

## TODO (user request, 2026-06-21): upstream yosys + yosys-slang patches for the lfsr

Running **yosys** (default frontend) or **yosys-slang** on alexforencich_ethernet's `lfsr.v`
causes issues:
  * **yosys default frontend** — cannot evaluate the parameterized `lfsr_mask` constant function
    in finite time (>60 s/instance); effectively hangs on the wide (DATA_WIDTH=32) CRC instances.
  * **yosys-slang** — `Assertion 'location' failed` in slang's `Diagnostics::add` on the
    DATA_WIDTH=32 `lfsr` (the 8-bit ones are fine).
Current stopgap: the design overrides those two files via `src/patches/alexforencich_ethernet/`
(submodule stays pristine) — `arp_cache.v` uses a cheap XOR-fold hash instead of the wide CRC
lfsr, and `lfsr.v` carries the YOSYS-macro LOOP-style note. **Eventually want real upstream
patches** so stock yosys / yosys-slang handle the lfsr directly (then we can drop the
src/patches override and restore the true CRC hash):
  * yosys: make the constant-function evaluator handle `lfsr_mask` quickly (or memoize it).
  * yosys-slang: fix the `Diagnostics::add` assertion on the wide lfsr (needs the slang
    submodule itself bumped — yosys-slang's pinned slang rev f04e8156 == current HEAD, so
    bumping only yosys-slang does nothing; the fix is in slang).
See also the pre-compute path below — generating a const-folded `lfsr.v` (masks baked in) lets
stock yosys build it without slang and without the hash deviation.

## ADPLL integration into chip_core (2026-06-22, autonomous)

Wired the standalone ADPLL into the chip (was designed/simulated but disconnected).
Decisions taken (sensible defaults, no blocker — flag at review if any should change):
  * **Controller variant in-chip: bang-bang `adpll_ctrl`** (not the linear sibling). The survey
    shows bang-bang needs no K_DCO gain matching and is inherently PVT-robust on a coarse ring;
    the linear loop locks faster but needs a tuned small alpha. Bang-bang is the safer silicon default.
  * **DCO: `ring_dco`** (binary-weighted), 7-bit — the SPICE-characterized variant.
  * **Fabric: nested split.** Added a top `axil_interconnect` on `addr[29]`: low -> existing
    RAM/SDRAM 2-way (addresses UNCHANGED: RAM 0x0, SDRAM 0x1000_0000), high -> new `adpll_csr`
    at **0x2000_0000**. Reuses the proven 2-way module; host/sim addresses unaffected.
  * **CSR map** (`src/csr/adpll_csr.sv`): 0x0 CTRL[0]=enable, 0x4 MUL(N), 0x8 DIV(M),
    0xC STATUS (ro: [0]=lock, [NumTuneBits:1]=tune). Observe-only: DCO clk -> analog[0], lock -> analog[1].
  * Reference is the 50 MHz core clock (mul/div synthesizer); no separate pll_in pad.

Sim-validated: `make sim-adpll-csr` (program over AXI4-Lite, poll STATUS -> lock, tune=21) PASS;
full `chip_top_tb` PASS (eth datapath unaffected, ADPLL disabled at reset). Also fixed a latent
forward-reference in adpll_freq_meas.sv (window_tick used window_cnt_q before its declaration —
Icarus tolerated it standalone but not in the full elaboration; moved the wire below the decls).

**OPEN — M3 harden risk (not yet resolved):** the ring DCO is a combinational oscillator and
its output `dco_clk` clocks the freq-measure counter, i.e. a second (free-running, async) clock
domain now exists in the core. The current SDC defines only the 50 MHz core clock; there is no
`create_clock` for `dco_clk` and no false-path/loop-break for the ring. OpenROAD will auto-break
the comb loop, but `dco_clk`-domain flops are effectively unconstrained and CTS/STA handling is
unverified. The clean fix is SDC work: declare `dco_clk` as a clock (or set the ring feedback as
a false path) + keep the (* keep *)/dont_touch on the ring cells. M2 (Ethernet+SDRAM, no ADPLL)
hardens clean today; M3 (with ADPLL) harden is attempted next and the outcome will be reported
rather than assumed.

### dco_clk SDC net name (resolved 2026-06-22)

The M3 harden's dco_clk SDC clause printed "No ADPLL DCO pin found" — my pattern
(*i_pll_dco*clk_o*, *pll_dco_clk*) didn't match. Root cause: synthesis flattens the
hierarchy AND merges the DCO clock net with the analog pad, because chip_core does
`assign analog[0] = pll_dco_clk`. In the netlist the ring's final mux drives `.Y(analog_PAD[0])`
and the feedback NAND reads `.B(analog_PAD[0])` — i.e. **the DCO oscillation net is
`analog_PAD[0]`**. The correct SDC target is therefore:
    create_clock -name dco_clk -period 2.0 [get_nets {analog_PAD[0]}]   ;# + async clock group
The first M3 run (RUN_2026-06-22_03-14-04) hardened with dco_clk UNCONSTRAINED (the DCO-domain
freq_meas counter untimed). Not editing the SDC mid-run (signoff STA re-reads it -> would desync
from PnR). Fix the net name, then re-harden to validate a properly-constrained M3. Open question
worth confirming: whether CTS cleanly handles a clock rooted on the (dont_touch) ring-oscillator
net that also drives an analog output pad, or whether the DCO counter clock should instead be
taken from a buffered tap.
