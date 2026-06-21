# Open questions / decisions for review

Logged autonomously while you're away. Resolved items have been removed.
Background/decision record lives in STATUS.md and the plan file.

## Genuine open fork (affects M2 SDRAM pinout)

- **SDRAM pin strategy.** x16 SDRAM (39 drive pads) + RMII out (4) = 43 > 40 bidir, so the
  full chip needs ~7 more drive-capable pads than the stock ring's 40. Two ways:
  - **(default) Retype ~7 input-only pads to bidir** (`NUM_INPUT 12→5`, `NUM_BIDIR 40→47`):
    keeps full **x16** SDRAM, no controller change, same 74-pad ring/positions/power. Only the
    pad *cell type* changes at 7 positions (your custom PCB must drive those positions as I/O).
  - **8-bit SDRAM**: bond DQ[7:0], tie UDQM high → ~30 drive pads, fits 40 without retyping,
    but halves capacity/bandwidth. ultraembedded controller stays 16-bit, so it'd be a
    "bond-8-of-16" (software uses the low byte) rather than a true x8.
  - **I'm proceeding with the retype (full x16)** when I wire SDRAM into the top in M2. It's
    isolated to the final pad mapping, so M2 logic/sim doesn't depend on this — flip it any time.

## For your PCB (not blocking RTL)

- **LAN8720A PHY strapping.** The design has no MDIO, so the PHY's address/mode (100M full-duplex,
  auto-neg) is set by board straps. Confirm your PCB straps it as desired.
- **If you retype input pads to bidir (above), confirm your PCB drives those positions as I/O.**

## Tooling

- `gh` CLI is **not authenticated** in this environment. I can push (SSH works) but cannot open
  PRs or read CI. Branches pushed: `peripherals-mvp` (this repo) and
  `fix-fd-io-power-pad-pins` (your template fork). Please open/observe those PRs.
