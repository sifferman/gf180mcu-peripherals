# Build status (autonomous session)

Living tracker. See `questions.md` for decisions/risks and
`/home/esifferm/.claude/plans/sorted-zooming-pancake.md` for the full plan.

## Milestones

- [ ] **M0** Repo scaffolding: submodules, src/ dirs, host dir, docs.
- [x] **M1** Ethernet → on-chip SRAM gold path: RTL integrated in chip_core, pure-cocotb
      `make sim` passes (ARP + UDP write/read), hardens under CI default flow.
- [ ] **M2** SDRAM controller (ultraembedded sdram_axi) on the AXI bus, open behavioral
      model sim, write-over-Ethernet test.
- [ ] **M3** SD card file-to-LED block + sim.
- [ ] **M4** Digital ring-oscillator DCO + DPLL controller, CSR-tuned, RTL sim + ngspice extraction.
- [ ] **M5** Top pin-mux + padring retype + 3 V config polish; STATUS/docs/README.

## Log

- Submodules vendored under third_party/ (alexforencich_ethernet@rmii, cocotbext-eth@rmii,
  wangxuan95 FPGA-SDcard-Reader, ultraembedded core_sdram_axi4).
- Branch: `peripherals-mvp`.

- M1 DONE: chip_core gold path (eth UDP->axil_ram) passes `make sim` (ARP+UDP write/read-back
  over RMII) via vendored cocotb/_eth (no pip deps). SRAM macros removed from RTL+macros+pdn
  (guarded). Pure-struct testbench + tb_top.sv wrapper (works for RTL & GL).
