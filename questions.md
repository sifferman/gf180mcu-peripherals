# Open questions for review

No open blocking questions right now — everything raised this session has been
resolved (3 V everywhere, SDRAM pin strategy = retype to full x16, SDRAM Icarus
model working, LED pads = bidir-as-output, PHY strapping answered).

PCB action items (for you, not RTL-blocking) live in `docs/hardware-notes.md`.

New questions will be added here if I hit a genuine fork while you're away.

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
