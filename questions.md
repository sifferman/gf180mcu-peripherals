# Open questions / decisions for review

Logged autonomously while you're away. Resolved items have been removed.
Background/decision record lives in STATUS.md and the plan file.

## Decided (kept for the record)

- **SDRAM pins: retype ~7 input-only pads to bidir** (`NUM_INPUT 12→5`, `NUM_BIDIR 40→47`) →
  full **x16** SDRAM, no controller change, same 74-pad ring/positions/power. (Chosen over the
  8-bit "bond-8-of-16" alternative.) Applied at the top-level pad mapping in M2.

## For your PCB (not blocking RTL)

- **LAN8720A PHY strapping** (from reference/8720a.pdf §3.7). The design has no MDIO, so the PHY
  is configured by reset-latched straps on its RMII/LED pins (augment with ~10k external resistors
  since the pins also carry live signals):
  - MODE[2:0] = RXD0/RXD1/CRS_DV → **111** "All capable, auto-neg enabled" (pull-ups to VDDIO).
  - PHYAD0 = RXER → **0** (internal pull-down default; fine, no MDIO).
  - nINTSEL = LED2 → **1 = REF_CLK In Mode** (we source the 50 MHz clock); tie high to VDD2A.
  - REGOFF = LED1 → **low** = use internal 1.2 V regulator (unless feeding external 1.2 V to VDDCR).
  - Clocking: a 50 MHz oscillator drives chip clk_PAD AND the PHY XTAL1/CLKIN (REF_CLK In Mode);
    no 25 MHz crystal on the PHY.
- **Retyped input→bidir positions: confirm your custom PCB drives those positions as I/O.**

## Tooling

- `gh` CLI is **not authenticated** in this environment. I can push (SSH works) but cannot open
  PRs or read CI. Branches pushed: `peripherals-mvp` (this repo) and
  `fix-fd-io-power-pad-pins` (your template fork). Please open/observe those PRs.
