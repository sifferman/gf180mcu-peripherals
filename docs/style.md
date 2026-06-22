# STYLE.md

The lowRISC style guide
([references/lowRISC-style-guide/VerilogCodingStyle.md](references/lowRISC-style-guide/VerilogCodingStyle.md))
is the official reference. Everything below is either an excerpt, an
emphasis, or a project-specific rule.

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

## Anti-patterns to avoid

- **Don't add comments that restate what the code does**. Comments are
  for *why* and for surprising invariants. If you need a comment to
  explain *what*, the names are bad — fix the names.

## Pure functions and constants

- Prefer `localparam` over `parameter` for module-internal constants.
- Prefer `wire` (continuous assign) over `always_comb` if the logic is
  a pure function (no priority chain).

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
