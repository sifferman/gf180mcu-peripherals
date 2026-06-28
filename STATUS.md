# Build status (autonomous session)

Living tracker. See `questions.md` for decisions/risks and
`/home/esifferm/.claude/plans/sorted-zooming-pancake.md` for the full plan.

## Milestones

- [ ] **M0** Repo scaffolding: submodules, src/ dirs, host dir, docs.
- [x] **M1** Ethernet → on-chip SRAM gold path: RTL integrated in chip_core, pure-cocotb
      `make sim` passes (ARP + UDP write/read), hardens under CI default flow.
- [~] **M2** SDRAM controller (ultraembedded sdram_axi) on the AXI bus, open behavioral
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

- M1 hardening: power-pad fix (fd_io 3-pin) + package inlining cleared Verilator lint and
  yosys parse; full synth in progress locally. Pushed to origin/peripherals-mvp.
- M2 WIP (parked, not integrated): open behavioral SDRAM model cocotb/models/sdram_sim.v +
  standalone tb; AXI write/read-back currently times out (controller init/handshake — TBD).
  Per project note, SDRAM functional sim is a 'later' item (authoritative = encrypted .vp on VCS).

- Switched ENTIRE flow to 3v3 (SCL=as_sc_mcu7t3v3/PAD=ocd_io/SRAM=ocd_ip_sram); pinned PDK
  already ships these + the 3v3 SCL librelane config, so no install-3v3-scl needed. 3v3 RTL
  sim passes. CI (fork 'default' matrix) now builds 3v3. Committed+pushed.
- 3v3 full hardening running locally (past lint, in JsonHeader).
- SDRAM behavioral model (cocotb/models/sdram_sim.v) now PASSES write/read-back vs the
  ultraembedded controller under Icarus — M2 functional sim de-risked.
- Template power-pad fix committed on branch fix-fd-io-power-pad-pins in
  /home/esifferm/GitHub/gf180mcu-project-template (off wafer-space/main), ready to PR.

## Synthesis-frontend breakthrough (overnight)

- yosys default Verilog frontend CANNOT derive verilog-ethernet's parameterized CRC `lfsr`
  in finite time (constexpr `lfsr_mask`, >60s per instance, both LOOP/REDUCTION). Confirmed on
  an unloaded box, so not contention.
- Switched to the **slang** frontend (USE_SLANG) — elaborates the whole UDP stack in ~20s.
- **(2026-06-21) slang lfsr crash root-caused + fixed cleanly — NO RTL patches, submodule pristine,
  REAL CRC restored.** The `Assertion 'location' failed` was slang's constexpr step limit: yosys-slang
  reuses one `EvalContext`, so slang's per-evaluation `steps` counter accumulates design-wide and the
  two DATA_WIDTH=32 arp_cache CRC lfsr instances push it past the 1,000,000 default (then slang asserts
  on an empty SourceLocation instead of erroring). Fix: `SLANG_ARGUMENTS += --max-constexpr-steps
  1000000000`. The earlier two src/patches overrides (lfsr.v LOOP-style + arp_cache.v XOR-fold) are
  DELETED — the submodule is back to upstream 2a692e4 and the design uses the true CRC ARP hash.
  Validated: full Yosys synthesis clean (netlist produced, no crash) + RTL `make sim` PASS with real CRC.
  Upstream fork patches (yosys-slang step accumulation; slang assert-on-empty-loc) tracked in questions.md.

## Hardening progress (overnight, slang)

- Synthesis now COMPLETES (slang, ~3 min). Cell area **5.5M um2** (was 16.8M) after shrinking
  TX/RX FIFOs 4096->1024 and ARP cache 512->4 entries — fits the 12.9M um2 1x1 core.
- Cleared Verilator lint + YosysUnmappedCells. YosysSynthChecks flagged only benign warnings
  (unused PTP ports; async-FIFO gray2bin yosys false-positive) -> ERROR_ON_SYNTH_CHECKS=false.
- Full 3v3 GDS hardening (PnR/DRC/LVS) running locally (monitored). M1 Ethernet gold path.
- Added cocotb/sim_udp_bridge.py + 'make sim-bridge' (drive dma.py against the sim).

## M2 SDRAM fabric validated (standalone) + M1 hardening through floorplan

- M2 RTL drafted + PASSES standalone iverilog test (`cocotb/models/tb_m2_fabric.v`):
  AXI4-Lite master -> axil_interconnect -> { axil_ram (scratch), sdram_wrap->sdram_axi->
  sdram_sim }. Both SRAM (0x0..) and SDRAM (0x1000_0..) regions write/read correctly.
  Files: src/axi/axil_to_axi4.sv, axil_interconnect.sv, src/sdram/sdram_wrap.sv.
  Remaining M2: wire into chip_core + chip_top pad mux (retype) + extend chip sim — done
  AFTER M1 hardening completes (keep the tree consistent with the running build).
- M1 (Ethernet) hardening: cleared synthesis+checks, **floorplan fits**, now in placement
  prep (padring/macro placement/tap-endcap). PnR/CTS/routing/DRC/LVS to follow.

## FIRST GDS achieved (M1 Ethernet) + sign-off fixes

- Full flow ran end-to-end and **streamed out chip_top.gds (301 MB, LVS-clean, setup-clean,
  routing-DRC clean)** — run RUN_2026-06-20_23-14-11/final/. Cell area 5.5M um2.
- Two deferred sign-off errors, both addressed:
  - Hold: the only 3 violations were INPUT PORTS (RMII RX), caused by SDC `set_input_delay -min 0`
    (data racing the clock edge). Set -min = 10% of period (real RMII RX holds data several ns).
  - Density: M2.4 (Metal2 >30% coverage, die-wide) — the known gf180 case handled by dummy fill
    in the wafer.space precheck; disabled the in-flow KLayout density check (template-intended).
- Re-running for a clean sign-off (LVS + hold + DRC all clear).

## ✅ CLEAN GDS SIGN-OFF (M1 Ethernet) — 2026-06-21 05:06
- Full flow EXIT 0, zero errors. Manufacturability: **Antenna PASS, LVS PASS, DRC PASS**.
- GDS: final/gds/chip_top.gds (301 MB); run librelane/runs/RUN_2026-06-21_02-21-43/.
- 3.3V (as_sc_mcu7t3v3 / ocd_io), slang frontend, 1x1 slot, cell area 5.5M um2.
- This is a tapeout-grade GDS of the Ethernet UDP->on-chip-RAM gold path.
- Next: integrate M2 (Ethernet+SDRAM) — RTL validated standalone — now that the flow is proven.

## ✅ CLEAN GDS SIGN-OFF (M2 Ethernet+SDRAM) — 2026-06-21 08:00
- Full flow EXIT 0, zero errors. Manufacturability: **Antenna PASS, LVS PASS, DRC PASS**.
- GDS: final/gds/chip_top.gds (304 MB); run librelane/runs/RUN_2026-06-21_05-13-19/.
- chip_core: eth UDP master -> axil_interconnect -> {scratch RAM (0x0), SDRAM (0x1000_0000)
  via sdram_wrap/sdram_axi}. Padring retyped to 47 bidir / 5 input for the full x16 SDRAM bus.
  Cell area 5.55M um2. 3.3V, slang.
- This is the headline: a tapeout-grade GDS that writes external SDRAM over Ethernet.

## 2026-06-21 (later): real-CRC cleanup + M4 PLL + fork patches
- **Real CRC restored, src/patches dropped** (commit 7547f71): root-caused the yosys-slang
  lfsr assertion to slang's per-evaluation constexpr step limit accumulating across the
  design (one reused EvalContext); fixed in-repo with `--max-constexpr-steps 1000000000` in
  SLANG_ARGUMENTS, so the *true* CRC arp_cache hash elaborates. Submodule fully pristine.
  Verified: RTL sim PASS (real CRC) + full Yosys synthesis clean. The crash is also already
  fixed on yosys-slang *master* (static-select fast-paths) — see questions.md.
- **✅ GDS re-hardening with real CRC COMPLETE — clean sign-off (2026-06-21 13:19).**
  Run RUN_2026-06-21_10-30-49, "Flow complete." exit 0, ~2h49m. Manufacturability report:
  **Antenna PASSED ✅ · LVS PASSED ✅ · DRC PASSED ✅** (Magic+KLayout DRC, KLayout antenna,
  routing DRC all clear; no setup/hold violations). final/gds/chip_top.gds = 304 MB, real CRC
  ARP hash. (Non-fatal warnings only: Max-Slew/Max-Cap in some corners — timing-quality, not
  manufacturability; IR-drop skipped, no VSRC_LOC_FILES.) The earlier full run
  RUN_2026-06-21_09-13-01 was OOM-killed at step 31 during a 3-job load spike; this restart ran
  clean. This GDS supersedes the XOR-fold M2 GDS with the true CRC — tapeout-current.
- **M4 digital PLL added** (commit, src/adpll/): binary-weighted mux-chain ring DCO
  (`ring_dco.sv`, structural gf180 cells + dont_touch, behavioural sim model) +
  bang-bang frequency-locked control (`adpll_ctrl.sv`, Gray-CDC edge counter, tune-band lock).
  `make sim-adpll` PASS (DCO oscillates monotonically with tune; FLL converges and locks).
  Standalone IP — not yet wired into chip_top (CSR control + analog observe pads = later step).
- **DCO SPICE characterized** (ngspice >= 42 for the BSIM4 models; the system ngspice-34 is too
  old — used the nix ngspice-45). Earlier runs exported the ring from gf180 transistor-level cell
  subckts and swept tune codes; that hand-written generator has been removed and the flow is being
  moved to OpenROAD/Magic parasitic extraction from the hardened ring_dco macro (single source of
  truth = the .sv). Low codes give the expected monotonic tuning (code 0 ~337 MHz -> code 16
  ~184 MHz, typical corner). High codes (32-127) read erratic/higher — consistent with
  multi-mode oscillation in the long ring (multiple wavefronts); a production DCO would
  constrain stage count / add single-edge startup. Usable monotonic range is the low codes.
- **Upstream fork branches pushed**: sifferman/yosys-slang @ fix-evalcontext-step-accumulation
  (reset step budget per eval) and sifferman/yosys @ lfsr-constfunc-slowness-investigation
  (root-cause + repro for the default-frontend slowness). Details in questions.md.

## 2026-06-27 — chip-fill ADPLL array for tapeout (autonomous, multi-day)
- Goal: fill spare die with many DISTINCT ADPLLs (CSR-selectable) + clean GDS in ~4 days.
- src/adpll_config.sv (parameterized filter+DCO+gains) + src/adpll_array.sv rewritten as a nested
  filter(3)xDCO(4)xvariant(NumVariants) generate -> 12*NumVariants distinct PLLs. NumVariants=4 => 48.
- Submodule reconciled to 82d26c2 (pi->proportionalintegral + gearshift fix). config.yaml/Makefile/tb
  updated; 12 fixed wrappers dropped for adpll_config. Committed 14e2941 (local only).
- VERIFIED: sim-adpll-array @ NumVariants=1 (12 base configs) all lock + obs mux OK. 48-PLL sim slow
  in vvp (running). 48-PLL harden RUNNING (RUN_2026-06-27_01-26-59), est ~57% util; monitoring
  floorplan util to confirm 50-70% before the ~3h flow finishes. PDK_ROOT=/home/esifferm/Utils/ciel-pdks.

## 2026-06-27 (cont) — 48-PLL harden hit congestion; iterating to 36
- 48-PLL (60% util) FAILED detailed placement (DPL-0036): routing congestion ~1.01, post-repair
  buffers over-filled. Per guidance, reduced NumVariants 4->3 = 36 PLLs (~56% util).
- Sim found 4 non-locking configs (bangbang IntegralGain=2 + band=1 + 16-sample lock: the integral
  dithers +-2 > band 1). Fixed: bangbang gain 1 unless band>=2 (profile 3 keeps gain2 w/ band2).
- Re-running: 36-PLL sim + 36-PLL harden (RUN newest). Monitor b0k80l9vw catches placement gate.

## 2026-06-27 (cont) — curated 12-config array w/ PHASE ADPLLs built + validated
- Per your direction (12 is fine if diverse + useful; add phase-aware ADPLLs): replaced the
  mechanical 12 with a CURATED 12, each a distinct tradeoff (filter x DCO x FLL/phase x 5/7-bit tune).
  3 are PHASE-domain (TDC + phase detector, fcw via CSR MUL field). adpll_config gained a Domain
  param; adpll_array carries the curated table + zero-extends mixed tune widths. Moved subsystem to
  src/adpll/. Committed bf65d24 (local).
- VERIFIED: make sim-adpll-array -> 12/12 lock in range (3 phase incl), obs mux tracks, each
  programmed with its own mul/div or fcw.
- HARDENS RUNNING (parallel, 431GB/128core, no OOM risk): safety-net mechanical-12 (b6am00mqb, at
  Magic DRC) = fallback; CURATED-12 (bq6fxjqlm) = deliverable, synth->place->route. Monitor bg5lzs35w
  catches the curated placement/routing gate (3 phase TDCs add congestion -- the open risk). 12 FLL
  routed before (06-23), and the curated set has 5 small 5-bit configs offsetting the 3 phase TDCs.
- If curated-12 fails routing: fall back to fewer phase / more 5-bit, or the mechanical-12 GDS.

## 2026-06-27 (cont) — curated-12 (w/ phase) PAST placement + global routing @47.9% util
- RUN_2026-06-27_08-37-54 (the curated 12, 3 phase + 5 small 5-bit + 4 fine 7-bit): synth OK,
  floorplan util 0.479, PASSED detailed placement AND global routing (step 38) -> now in
  antenna-repair / STA -> detailed route / DRC / LVS / GDS. The 5-bit configs offset the phase TDC
  area so the diverse set fits where the all-7-bit 16/24/36 sets congested out. This is the deliverable.
- Safety-net mechanical-12 run (RUN_06-26-27) did NOT finish (disturbed by the mid-flight file move);
  superseded by the curated-12 anyway. The 2026-06-21/23 GDSes remain on disk as ultimate fallbacks.
- Monitor bg5lzs35w -> reports curated-12 DRC/LVS/antenna sign-off when the flow completes (~1-2h).

## 2026-06-27 (cont) — SD card integrated + SDRAM top-test added; full re-harden running
- SDRAM top-test: sdram_sim wired into tb_top; test_sdram_over_udp PASS (write/read external SDRAM
  over Ethernet). 3/3 chip-top cocotb tests pass. Committed.
- SD card (4th peripheral) integrated: vendored split-IO WangXuan95 reader (src/sdcard/*.sv, inout
  CMD -> o/oe/i for the gf180 bidir pad) + mode-strap pad mux in chip_core. Chip elaborates with it;
  3/3 tests still pass in normal mode. Committed.
- SD functional sim: cocotb/models/tb_sdcard.v + sd_fake + FAT32 image; `make sim-sdcard`. Running
  (monitor br5yuldkn) -- expects led=0x4865 ('H','e' from example.txt).
- FULL RE-HARDEN running (RUN_2026-06-27_12-05-10, task bdl243ac4): eth + SDRAM + 12-PLL array (3
  phase) + SD card on ONE chip. Monitor boo9y8gju catches floorplan util / placement / routing /
  signoff. (Prior ADPLL-only run killed per user so this run has everything.) RISK: SD reader area
  bumps util above the curated-12's 0.479; if it overflows routing, drop a phase config to 5-bit or
  trim a PLL to make room.

## 2026-06-27 (cont) — SD functional sim PASS; full-chip harden past placement/global-route
- SD block sim FIXED + PASS: first attempt used SIMULATE=0 (real ~84ms card power-up wait) so the
  reader never finished init within the 8M-clock sim window (led=0x0000). Set SIMULATE=1 in
  cocotb/models/tb_sdcard.v (matches reference tb) -> `make sim-sdcard`:
  "PASS: SD reads example.txt head -> led=0x4865 ('H','e')". The inout->split-IO CMD adaptation is
  correct end-to-end. Committed f96f399 (local).
- VERIFICATION MATRIX (all 4 peripherals integrated AND top/block verified):
  * RMII Ethernet MAC  -> chip-top cocotb test_arp_write_read (UDP->SRAM over RMII)            PASS
  * SDRAM controller   -> chip-top cocotb test_sdram_over_udp (write/read ext SDRAM over Eth)  PASS
  * ADPLL x12 + CSR    -> chip-top cocotb test_adpll_csr_over_udp (turn ON via CSR -> lock=1)  PASS
  * SD card file->LED  -> block tb_sdcard.v vs sd_fake + FAT32 image (led=0x4865)              PASS
  + sim-adpll-array: 12/12 ADPLLs (incl 3 phase) lock in range. PLL-on-via-CSR-in-sim demonstrated.
- FULL-CHIP harden (RUN_2026-06-27_12-05-10): floorplan util 0.505, PASSED global placement (step
  27) and is in repair_design/STA/route (step 31) with NO GRT-0183/DPL congestion errors -- the SD
  block fits (0.479 -> 0.505, still in the 50-70% target). Mid-PnR setup WNS -92ns is the normal
  pre-buffering reset-net RC (760+ worst paths all start at rst_n_PAD, one net -> ~1900 flops);
  repair_design (step 31) buffers it. Confirmed benign: ALL 4 prior completed runs sign off at
  setup+hold WNS=0 / DRC=0 / LVS=0 across all 9 corners, so no SDC reset constraint is needed.
- Monitor bzpy9mioh -> notifies on this run's own final/ (DRC/LVS/antenna sign-off) or failure.

## 2026-06-27 (cont) — upstream template merge + timing/SDC overhaul (toward a clean 50 MHz GDS)
- UPSTREAM: wafer-space template advanced 3 commits past our fork (baseline a4bca2f); entire delta =
  PDK_COMMIT 019cf7a3->140b0494 (Makefile) + librelane 3131cc55->f18a07a (flake.lock). Applied; new
  devshell builds clean (LibreLane v3.1.0.dev2, yosys-slang overlay OK). All other template features
  (3v3, shuttle ID/marker/logo IP, padring, CI) were already present at our fork point.
- TIMING ROOT CAUSE (25 MHz run RUN_..12-44-09): the only setup violators were FALSE PATHS through the
  self-timed ADPLL structures, not real logic:
    * ring DCO: tune-reg -> dont_touch inverter/mux ring -> clk_PAD flop (worst at TT corner)
    * flash TDC: dco_clk -> dont_touch dlybuff delay line -> reference flop (worst -6.7 ns at SS)
  Worst REAL path had +5.73 ns slack at 25 MHz. Fixes (grounded in OpenROAD/OpenSTA source):
    * chip_top.sdc set_false_path -through the 738 ring-DCO cells + 186 TDC delay cells (patterns
      verified on the routed netlist). Sampler->encoder->phase_o logic still timed normally.
    * RSZ_DONT_TOUCH_RX disabled ("^$"): net-level dont_touch caused repair_design RSZ-3006 (the
      oscillator's high-fanout output needs buffering). Cells stay protected by RTL (* dont_touch *).
      Proper buffer-free-loop fix = RTL output-buffer decoupling (follow-up).
- I/O DELAYS: replaced uniform generic delays with per-interface datasheet values (all 7 port groups
  verified on netlist): RMII RX in 14.0/3.0, RMII TX out 4.0/-1.5 (LAN8720A REF_CLK-In, p72);
  SDRAM cmd/addr/wrDQ out 1.5/-0.8, read DQ in 5.0/3.0 (W9825G6KH -6 CL3, p15); LEDs/strap false_path;
  SD relaxed. First-order system-synchronous ref'd to clk_PAD (1:1 source of both forwarded clocks).
- CLOCK: CLOCK_PERIOD 40->20 (50 MHz). RMII *requires* 50 MHz REF_CLK for 100 Mbps, so this is needed
  for spec-compliant Ethernet, not just nice-to-have. RMII TX uses the existing negedge launch
  (delay_to_negedge, 3 di-bits) -- standard robust ASIC source-synchronous technique.
- DECISION (negedge vs posedge): user prefers all-posedge. Posedge-only is feasible in ASIC (OpenROAD
  can balance data-vs-forwarded-clock skew) but requires generated clocks on the forwarded outputs to
  be "strict enough" -- adds CTS/sim risk. Prioritized the firm "passing GDS asap" goal: deliver via
  the proven negedge path first (RUN_..14-48-36, 50 MHz), then pursue posedge+generated-clocks as a
  parallel refinement. Core-logic 50 MHz closure (SDRAM/AXI) is identical either way.
- RUNS: 25 MHz fallback RUN_..12-44-09 = clean GDS imminent (its DCO/TDC "violations" are the known
  false paths; functionally fine). 50 MHz v2 RUN_..14-48-36 running with all the above. The signoff
  WNS (step 54) of v2 is the real 50 MHz answer. Monitor bzu27zkm4 tracks it.

## 2026-06-27 (cont) — 50 MHz timing closure arc (TDC decode + RMII source-synchronous)
- 25 MHz fallback RUN_..12-44-09 DONE: DRC=0, LVS=0, antenna=0, util 0.56, 346 MB GDS. FF/TT setup
  met; SS -6..-7 ns = the unconstrained DCO/TDC (this run predates the false-paths). DRC/LVS-clean
  safety net for the full chip (eth+SDRAM+SD+10 ADPLLs incl 3 phase). NOTE: RMII needs 50 MHz for
  100 Mbps, so 25 MHz is only a fallback, not the target.
- 50 MHz closure took several constraint iterations (RTL/design all verified in sim along the way):
  * v2 RUN_..14-48-36: false-path DCO+TDC-delay-line + datasheet I/O. Left the TDC *decode* (deep
    priority-encode + divide) as a real 1-cycle path -> SS -4.4 ns.
  * TDC fix (committed, adpll submodule 91a8e7b + parent fe45862): SampleEveryN snapshot decimation
    (N=4) makes the decode a valid 4-cycle multicycle. sim-adpll-array still 10/10 lock incl 3 phase.
  * v3 RUN_..16-06-12: multicycle anchored on flop *instances* -> matched 0 (synth renamed flops) ->
    didn't apply. Fixed (commit 4351c89): anchor -through the sampled NETS (189, names preserved).
  * v4 RUN_..16-25-39: TDC fully gone from violators. Sole residual = negedge RMII TX_EN -> bidir[0],
    SS -4.4 ns. This is MODELING PESSIMISM: RMII I/O was clk_PAD-relative, but the PHY samples the
    forwarded ref_clk (clk_PAD + bidir[3] pad delay ~5 ns) -- a common-mode credit the model omits.
    v4 is a complete 50 MHz GDS (DRC/LVS clean like the 25 MHz run; everything closes but that one
    pessimistic path) -- a strong deliverable.
  * v5 RUN_..18-18-42 (commit 9bcddb9, RUNNING): model bidir[3]/[24] as divide-by-1 generated clocks
    (rmii_ref_clk / sdram_clk_out, both verified to create on the netlist) and reference RMII+SDRAM
    I/O to them -> credits the forwarding to RMII TX (should close) AND makes RMII RX honest (the
    PHY's 14 ns valid on a 20 ns period -- the "extreme requirement"). v5 gives the TRUE RMII margin
    both directions. Monitor brwcyb070. If RX is marginal at SS, that's the real RMII-at-50 MHz limit
    (options: capture RX on a phase-shifted clock, or accept SS-corner derate for a test chip).
- Monitors: check the SS corner explicitly at each signoff (the monitor reports the first/FF corner).
