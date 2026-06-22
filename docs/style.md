# STYLE.md

The lowRISC Verilog Coding Style guide is the official reference.
Everything below is either an excerpt, an emphasis, or a project-specific rule.

This is a **living document**: whenever a style decision or correction is made,
it is recorded here so the same mistake isn't repeated.

## Names

- **Self-documenting**. Variable and function names should make comments
  unnecessary. If you can't name it well, the thing probably shouldn't
  exist — split it apart or merge it with something nearby.
- **Verbose and descriptive** over short and clever. `accumulator_in_ready`
  beats `acc_ir` every time.
- **No jargon**. Don't name a parameter `RegisterB`. Don't call a wire
  `m_d2`. Spell out intent.
- **Consistent style for everything**. snake_case throughout SV; reserve
  CamelCase for parameters and typedefs per lowRISC. Stick to the same
  pattern across the codebase.
- **`_d` and `_q` suffixes on every flip-flop**. The `_d` is the
  combinational next-state wire; `_q` is the registered output. Per
  lowRISC: if a signal is also active-low or a module port, suffix order
  is `_n` → `_d`/`_q` → `_i`/`_o`/`_io` (e.g. `rst_ni`). Pipelined copies
  are `_q2`, `_q3`, etc.
- **`always_ff` holds only the reset and `_q <= _d`.** No combinational
  logic in a clocked block — all next-state computation (enables/holds,
  arithmetic, muxing, increments) goes in `always_comb` or continuous
  `assign`s that drive `_d` (or an `_o`). An `always_ff` is exactly
  `if (!rst_ni) _q <= <reset>; else _q <= _d;`. An enable becomes part of
  `_d` (`_d = en ? next : _q`), never `if (en) _q <= …` in the `always_ff`.
  (The one pragmatic exception is a RAM write port — a memory array has no
  `_d` shadow, so `if (we) mem[addr] <= wdata` stays in the `always_ff`.)
- **No abbreviations.** Spell the word out: `controller` not `ctrl`,
  `integral` not `integ`, `accumulator` not `acc`, `frequency` not `freq`
  (in prose). The only allowed short forms are universally understood ones:
  `clk`, `rst`, `dco`, `addr`, and standard protocol/acronym names
  (`axi`, `udp`, `rmii`, …). If a reader has to pause to expand it, don't abbreviate it.
- **Declare each flip-flop on one line, `_d` before `_q`**:
  `logic [NumTuneBits-1:0] integral_d, integral_q;` — never split the pair
  across two declarations.
- **Module names are nouns**, naming the *thing* the block is, not an action:
  `adpll_freq_counter`, not `adpll_measure_freq`. Pick the textbook noun where
  one exists (a windowed edge counter is a "counter," not a "measurer").

## Modules

- **Every module communicates with ready/valid**, unless it is:
  - An intentional skid buffer (which IS ready/valid by definition)
  - Purely combinational (e.g. `ternip_sig`, `ternip_csig`)
- If you turn a previously combinational module into a sequential one,
  **you must add ready/valid on both ends**. No exceptions.
- **Don't add `Pipelined`-style parameters without ready/valid plumbing**.
  Sticking a flop into a combinational path without back-pressure is a
  hack — it relies on the upstream producer "happening to" hold its
  output stable.

## When you need new logic, choose in this order

1. **Instantiate an existing module**. Look in `ternary_matmul/
   third_party/` first — `basejump_stl`, `alexforencich_axis`, and
   `ternip` already cover a lot.
2. **Inline the pattern**. A simple skid buffer or pipeline register is
   ~10 lines of always_ff and an assign. No module needed.
3. **Add a new module** — LAST RESORT. Check `third_party/` again first.

## Instantiation

- **One parameter/port connection per line.** Every `.name(value)` port
  connection — and every `#(.PARAM(value))` override — goes on its own line,
  even for a two-pin cell. Keeps diffs minimal and every connection greppable.
  Use named connections (`.port(sig)`); the `.clk_i` implicit-connect shorthand
  (`.clk_i(clk_i)`) is fine, one per line.
- **A module instantiated once in its scope takes the module's name as its
  instance name** — `adpll_freq_counter adpll_freq_counter (…)`, not `u_meas`.
  Only give a distinct instance name when there are several of the same module
  in one scope (then name by role: `i_ic`, `i_ic_top`). (Doesn't apply to PDK
  std-cell primitives, whose type name is impractically long.)

## Anti-patterns to avoid

- **Don't add comments that restate what the code does**. Comments are
  for *why* and for surprising invariants. If you need a comment to
  explain *what*, the names are bad — fix the names.
- **Keep comments terse — a phrase, not a paragraph.** State the one fact that
  drives the decision (e.g. `// small alpha so a coarse DCO's cold-start error
  can't rail the loop`). If it needs a paragraph, the design or naming is the
  problem. (Module headers follow the concise format under *File headers*.)
- Don't put combinational logic in always_ff blocks. Combinational logic
  should only exist in always_comb and assign blocks were _o/_d values are assigned.
  In always_ff blocks, the only logic should be the reset and _q<=_d.

## Pure functions and constants

- Prefer `localparam` over `parameter` for module-internal constants.
- Prefer `wire` (continuous assign) over `always_comb` for simple
  expressions/muxes (no priority chain).
- **Call a SystemVerilog `function` only inside an `always_comb` block, never
  in a continuous `assign`/`wire =`.** Continuous assigns are for operators and
  selects; anything that invokes a `function` (e.g. `clamp`, `gray2bin`) lives
  in `always_comb`.
- **Helper functions take their conventional signature.** `clamp` is
  three-argument — `clamp(lo, value, hi)` returning `min(max(lo, value), hi)` —
  not a one-argument form that reaches module-scope bounds.
- **Use `'0` for an all-zero value**, not `{Width{1'b0}}`. (Likewise `'1`,
  and `'x` for sim-only don't-cares.)
- **Compare a magnitude against an unsigned tolerance, not a signed ± bound.**
  For a "within ±tol" test, compute an explicit unsigned absolute value and compare
  it to the unsigned bound (`band_error_abs <= BandRadius`), rather than building a
  signed bound and checking `(e >= -Bound) && (e <= Bound)`. A "signed radius" is a
  contradiction — a radius is a magnitude.

## Time and compiler directives

- **No `` `timescale `` and no `` `default_nettype `` in source** (RTL or
  testbench). Supply simulation precision at the *tool* level instead — cocotb's
  `runner.build(timescale=…)`, and a single compiled-first precision file for
  standalone iverilog targets. (iverilog with no timescale defaults precision to
  1 s and silently rounds `ns` delays to zero — so the precision must come from
  the flow, not be missing entirely.)
- **Every `#` delay carries an explicit time-unit literal**: `#(20ns)`, never
  `#20`. A delay must not depend on an ambient `` `timescale ``.
- **A parameter or variable that holds a time is typed `realtime`** and built
  from time literals, e.g. `localparam realtime HalfPeriod = 1.0ns;`.

## Parameterization

- **Parameterize by the physical quantity, derive the bit-width.** Expose the
  operating envelope (`MaxEdgesPerWindow`, `MaxWindowSize`) as the `parameter`
  and compute the width with a `localparam`:
  `localparam int unsigned EdgeCountWidth = $clog2(MaxEdgesPerWindow + 1);`.
  A bare `…Width = 24` parameter hides what it's for.
- **Name the parameter for the thing it bounds, specifically.** `EdgeCountWidth`
  (the DCO edge count), not `CountWidth` ("count of what?"); a *size* is
  `…Size`/`…Length`, never `…Count` (which reads as "how many").
- **Guard fixed-width arithmetic with an elaboration-time assertion.** When math
  is evaluated in a fixed type (e.g. `int` inside a function), add a static check
  that the parameterization can't overflow it, and `$error` if it can:
  `if ($clog2(MaxValue + 1) + 1 > $bits(int)) $error("…");` (a bare
  `if (cond) $error(...)` module item fires at elaboration).

## File headers

Keep the module header short: the BSD license block, then
- one **citation** line — the work + chapter the design is drawn from (cite the
  work itself, e.g. "Staszewski & Balsara, Wiley 2006, Ch. 3" — **never** a path
  into a local `reference/` tree, which is not committed);
- **1–2 sentences** on what the block does;
- a bulleted **Parameters** list and a bulleted **Ports** list.

No multi-paragraph derivations or block quotes in the header.

## File organization

- Keep files, modules, and functions small. If a file passes ~500 lines,
  consider splitting.
- One module per file. Filename matches module name.
- Group related modules in subdirs

## Things that should be specified in a parameter list, not hardcoded

- Bit widths
- Number of operands / lanes / banks
- Internal precision / exponent for fixed-point modules

## Things that should NOT be parameters

- Anything that's "always 1" or "always 0" in practice
- Anything where the name would be jargon (`RegisterB`) — restructure
  the abstraction instead

## Project-specific idioms (match these — don't invent new ones)

- **Genvar suffix**: name generate-loop counters with the `_GEN` suffix
  (`for (genvar i_GEN = 0; i_GEN < N; i_GEN++)`). Avoids shadowing
  `i`, `b`, etc. in surrounding always_comb blocks.
- **Generate block names**: always name the body: `begin : lanes`,
  `begin : decoupled_ready`. Required for hierarchical net names that
  show up in timing reports.
- **`ifndef SYNTHESIS` for sim-only**: assertions, `<= 'x` reset writes,
  expected-queue model code all go inside `ifndef SYNTHESIS` /
  `endif` blocks. Never reset a data-path FF to a non-`'x` value just
  for sim — the resulting synth FF gets a reset pin you don't want.
