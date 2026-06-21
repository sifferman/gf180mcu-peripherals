# Open questions for review

No open blocking questions right now — everything raised this session has been
resolved (3 V everywhere, SDRAM pin strategy = retype to full x16, SDRAM Icarus
model working, LED pads = bidir-as-output, PHY strapping answered).

PCB action items (for you, not RTL-blocking) live in `docs/hardware-notes.md`.

New questions will be added here if I hit a genuine fork while you're away.

## Tooling blocker found (FYI — worked around)

- **yosys-slang (pinned in flake) crashes on the verilog-ethernet `lfsr`.** Two
  identical-parameter `lfsr` instances → `Assertion 'location' failed` in slang's
  `Diagnostics::add`. The eth stack has many (Ethernet FCS + ARP-cache hashes), so
  `USE_SLANG` can't build this design yet. Minimal repro saved in scratch. Not fixable
  via `-Wnone`/`--suppress-warnings`. **Worked around by using yosys's default Verilog
  frontend** (correct, but slow deriving the CRC networks). To re-enable slang later:
  bump yosys-slang in the flake, or patch/uniquify `lfsr` in third_party. Want me to
  file an upstream yosys-slang issue with the repro?

## Follow-up: evaluate sv2v instead of slang (user suggestion, 2026-06-21)

slang is experimental and asserts on the wide CRC lfsr (hence the arp_cache hash patch).
**Try sv2v as the frontend instead.** Rationale: the real blocker is yosys's frontend being
unable to elaborate verilog-ethernet's parameterized `lfsr` (constexpr lfsr_mask, >60s/instance) —
sv2v does its own elaboration (const-fold + generate unroll) and emits flat Verilog-2005, which
should let yosys's stable default frontend handle it fast. Benefits: drop the experimental slang
plugin + its wide-lfsr assertion, and REVERT the arp_cache cheap-hash patch (restore real CRC hash).
TODO: (1) confirm librelane sv2v integration / add an sv2v pass; (2) verify it tames the lfsr
(quick timed test); (3) if clean+fast, switch USE_SLANG->sv2v and revert slang workarounds.
