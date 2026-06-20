# Open questions / decisions for review

Logged autonomously while you're away (per your instruction not to prompt).
Each item has the decision I made so work could continue — change any of them and I'll adjust.

## Resolved-with-a-default (override if you disagree)

1. **CI hardens to GDS, and that's the hard part.** `.github/workflows/ci.yml` runs
   `make sim` → `make librelane-condensed` (full PnR to GDS) → manufacturability → `make sim-gl`.
   For a fork the matrix is a single `default` config (Makefile defaults = **5 V**:
   `gf180mcu_fd_sc_mcu7t5v0` / `gf180mcu_fd_io` / `gf180mcu_fd_ip_sram`).
   - **Decision:** I'm building the design so it hardens under the **default 5 V** flow that CI
     exercises (keeps CI green), while keeping everything parameterized so the **3 V** libraries
     (`as_sc_mcu7t3v3` / `ocd_io` / `ocd_ip_sram`) are selectable via `SCL=/PAD=/SRAM=` and become
     the local default for `make`. Reason: a 3 V CI run also needs `install-3v3-scl` (the 3 V SCL
     isn't in the stock PDK) which CI doesn't do, and flipping CI to 3 V + adding that step is a
     separate change I didn't want to make blind. **If you want CI itself to build 3 V**, say so and
     I'll add the install step to the flow + flip the fork matrix.

2. **Sim has no `cocotbext-eth/axi` in the Nix devshell.** To keep CI self-contained I wrote the
   Ethernet testbench in **pure cocotb + `struct`** (builds/parses ARP + UDP + the DMA protocol by
   hand, drives the RMII di-bits directly). No new Python deps. The richer `cocotbext`-based bench
   from `reference/vivado_nexys/sim` is kept for local VCS use.

3. **Full-chip GDS closure of all four peripherals at once is high-risk autonomously.** Strategy is
   **incremental, keep-CI-green milestones**: (M1) Ethernet→on-chip-SRAM gold path hardens + sims;
   (M2) +SDRAM controller; (M3) +SD card; (M4) +DPLL; (M5) top pin-mux/padring polish + 3 V. Each
   milestone is a commit that should leave CI green. If a milestone won't close in time, it stays on
   the branch un-merged rather than breaking the others. See STATUS.md for where I am.

4. **SDRAM sim model is encrypted (VCS/Questa/NC only).** Icarus/CI path uses a small open
   behavioral W9825-like model I wrote; the encrypted `.vp` is gated behind `SIM=vcs`. (You already
   flagged Icarus support comes later.)

5. **PLL control over Ethernet** = a memory-mapped CSR (`ctrl`/`enable`) on the AXI bus; only
   `pll_in`/`pll_clk`/`lock` are pads (`pll_clk`+`lock` on the 2 analog pads). PLL does not clock the core.

6. **Padring:** stock 74-pad 1×1 ring; ~7 input positions retyped to `bi_24t` bidir (same positions,
   same power) so the 47 drive-capable datapath signals fit. SD + PLL-probe share datapath pads via a
   mode strap.

## Genuinely open (need your input when you're back)

- **A1.** Do you want CI to build the **3 V** flow (adds `install-3v3-scl` + flips the matrix), or is
  3 V-by-local-default + 5 V-in-CI acceptable for the MVP?
- **A2.** LAN8720A PHY address/mode strapping is a **PCB** concern (no MDIO in the design). Confirm
  your PCB straps the PHY to 100 M full-duplex, auto-neg as desired.
- **A3.** SD demo: 16 dedicated LED pads vs. exposing the 2-byte value via a CSR read. I defaulted to
  CSR-readable + a few status LEDs to save pads; say if you want the full 16-LED bank.
- **A4.** If full-chip GDS won't close in the time available, which subset is most important to you to
  have hardened first? (My default priority: Ethernet+SDRAM > SD > PLL.)
