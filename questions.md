# Open questions for review

N/A

## Chip-fill ADPLL array + tapeout GDS (2026-06-27, multi-day autonomous; you asleep)
Your ask: fill the empty die with a TON of DISTINCT ADPLLs, CSR-selectable; clean GDS in ~4 days.
Fill 50-70% util (less OK); harden LOCALLY, no push; monitor build health, back off util / skip
unneeded checks if congestion or runtime blows up; log decisions here, don't interrupt you.

STARTING STATE (discovered): the 12-PLL array + NumPll-generic CSR + obs mux ALREADY existed and
ALREADY hardened clean (RUN_2026-06-23_00-59-30: DRC/LVS/antenna=0, util 50.9%, 1x1). So this is
SCALING a proven design, not building from scratch -> low risk.

DECISIONS TAKEN (autonomous):
- Built src/adpll_config.sv: ONE parameterized PLL (FilterSel 0/1/2 = bangbang/proportionalintegral/
  gearshift; DcoSel 0..3 = binary/therm/muxtap/coarsefine; all loop gains + lock band/min-samples +
  detector widths exposed) via generate-case. Replaces the 12 hand-written rtl/adpll/ wrappers.
  Int selects (not strings) so a genvar-indexed table is robust in yosys-slang.
- Rewrote src/adpll_array.sv: nested generate filter(3) x DCO(4) x variant(NumVariants) => 12*NumVariants
  DISTINCT PLLs. Per-variant gain/lock PROFILES (cycle mod 4) make each (filter,DCO,variant) a unique
  design point. Uniform 7-bit tune so the CSR readback width stays uniform (NO per-PLL width handling).
  PLL0 = bangbang x binary x profile0 (defaults) -> original CSR offsets preserved for the UDP test.
  NumVariants=4 => 48 PLLs as the starting point; tune this knob to hit 50-70% util after measuring.
- Submodule divergence reconciled: parent recorded adpll @28dbfc1 (old pi/linear names); current
  submodule @82d26c2 renamed pi->proportionalintegral, linear->proportionalintegral, added phase
  configs + gearshift fix. Updated config.yaml + sim file lists to the current names; will bump the
  parent submodule pointer. (Brings the gearshift MaxGear=2 railing fix onto the chip.)
- config.yaml VERILOG_FILES: dropped the 12 fixed wrappers, added src/adpll_config.sv +
  adpll_post_divider.sv; pi->proportionalintegral. (File-list edit only -- not a flow/param change,
  so no tool-source consult needed; will consult ~/GitHub/{librelane,OpenROAD} for any PDN/util/step
  change.)
- Phase-domain PLLs still EXCLUDED from the array (fcw/TDC interface breaks the uniform CSR). Could
  add as a second CSR-distinct group if you want them on-chip -- flag for later.

OPEN QUESTIONS FOR YOU (non-blocking; using my judgement meanwhile):
- Is 48 distinct configs (or whatever hits ~60% util) the right "ton", or do you want me to push
  toward more via tune-bit/ring-length variants (needs CSR tune-width = max, zero-extend per PLL)?
- Want the phase-domain ADPLLs on-chip too (separate CSR group)?

## 2026-06-27 (cont) harden running + gain verification
- 48-PLL harden RUN_2026-06-27_01-26-59: synth OK, FLOORPLAN UTIL = 0.600 (60%, in your 50-70% band),
  chip area 7.61M um2. Now in placement (~step 27). baz7tjvn1 notifies on completion. Letting it run
  to GDS; gains do NOT change the routing-critical rings, so its DRC/LVS validates the design.
- VERIFIED variant gains all lock: gearshift MaxGear=3 (variants 1,3) does NOT rail at the array's
  167MHz operating point (tune~19/89) on any of the 4 DCOs -- the railing was specific to the cosim's
  300MHz steep-low-code region. So NO gain change needed; the 48 configs are all expected to lock.
- 48-PLL behavioral sim is slow in vvp (48 high-freq rings) -- non-critical (12-PLL + each config type
  verified individually). Running in background for confirmation only.

## 2026-06-27 — ROUTING-CONGESTION WALL limits PLL count (DECISION NEEDED)
FINDING: the dont_touch ring DCOs are routing-congestion-heavy. Detailed-placement results on the
1x1 die (signal routing already uses all 5 metals, Metal1-5):
  - 12 PLLs (~47% util): PLACES clean (the 2026-06-23 sign-off).
  - 24 (51%), 36 (56%), 48 (60%): ALL fail detailed placement (DPL-0036), routing congestion ~1.01,
    placer "minimum feasible density" ~0.46.
So the placeable ceiling is ~12-16 PLLs (~48% util) -- a ROUTING limit, not cell area. The ~49%
"empty" space you saw can't be filled with these rings without relieving routing congestion.

ACTION (best judgement, per "decrease util on congestion"): delivering NumPll=16 (~48.5% util, just
under your 50% floor which you said is OK). 16/16 lock in sim; chip UDP gold-path passes. Hardening
now (bhl2euwlc); if 16 overflows placement I fall back to the proven 12. Clean GDS either way.

TO REACH YOUR 36-48 "ton" (50-70% util), options -- YOUR CALL (each has a tradeoff I didn't want to
take unilaterally):
  (a) Loosen the PDN straps (wider pitch) to free Metal3/4 for signal routing -> fits more PLLs.
      Tradeoff: higher IR drop (and IR-drop signoff is currently skipped -- no VSRC_LOC_FILES), so
      this needs care for a real tapeout. Librelane change (I'd consult OpenROAD PDN source first).
  (b) Smaller DCO rings (NumTuneBits 7->5) -> ~4x less ring routing -> many more fit. Tradeoff:
      narrower freq range (5-bit ring ~264-385MHz in the behavioural model; the 167MHz test target
      isn't reachable, so the on-chip mul/div would target a higher freq). Changes the DCO design pt.
  (c) Accept ~16 PLLs (clean, low-risk) -- what I'm delivering now.
RECOMMENDATION: ship (c) as the safe tapeout GDS; if you want the bigger "ton", I'd do (b) smaller
rings (no power-integrity risk, unlike (a)) -- tell me and I'll characterize + scale it.

## 2026-06-27 (cont) — routable wall is ~12-14 PLLs; delivering 12
- 16 PLLs PLACED (got past detailed placement at ~48.5% util) but FAILED GLOBAL ROUTING
  (GRT-0183 heap underflow / congestion). So the place-AND-route-clean ceiling is ~12-14 PLLs,
  tighter than the placement ceiling. 12 is the proven clean point (2026-06-23 sign-off).
- DELIVERING NumPll=12 (current submodule + adpll_config + all-locking gains): hardening now
  (b6am00mqb) -> the reliable tapeout GDS. This is what fits cleanly with the dont_touch rings.
- To exceed ~12 toward your "ton" still needs the logged tradeoffs (smaller rings = best, no power
  risk). NEXT after the 12-GDS is secured: try NumTuneBits=5 rings (~4x less ring routing) at a
  ~300MHz operating point (5-bit range ~264-385MHz; 167MHz unreachable so retarget mul/div), which
  could let many more route. Will characterize locking then scale the count.

## 2026-06-27 (cont) — 5-bit ring scale-up CONFIRMED viable
- Behavioral check: adpll_config with DcoNumTuneBits=5 LOCKS at ~300MHz (mul=96/div=8) for
  bb-binary(tune21), pi-muxtap(0), gearshift-muxtap(4), bb-coarsefine(21). 5-bit ring range
  ~264-385MHz, so the on-chip mul/div targets ~300MHz (vs 167MHz for 7-bit).
- PLAN after the 12-PLL GDS (b6am00mqb) completes: switch the array to NumTuneBits=5 (rings ~4x
  smaller -> much less routing congestion) + shrink the oversized 24-bit freq detector, then harden
  at a HIGH NumPll (target 36-48) to fit your "ton" cleanly. Tradeoff: 5-bit = 32 tune codes
  (coarser per-PLL resolution) in exchange for many more PLLs. No power-integrity risk (unlike PDN
  loosening). Will verify all lock at scale + drive to clean DRC/LVS.

## 2026-06-27 (cont) — full-chip harden failed legalization; trimmed PLL fill 12->10
DECISION (autonomous, per your "decrease utilization when congested" guidance): the full chip
(eth + SDRAM + SD card + 12 ADPLLs) FAILED detailed-placement legalization (DPL-0036) at
repair_design -- repair inserted 69443 buffers for the high-fanout nets and the legalizer could not
place 14 of them. The curated-12 WITHOUT the SD card routed clean (0 DRC violations, magic-drc clean,
reached final klayout-drc before you killed it), so the SD block (a REQUIRED peripheral) tipped the
design ~2000 buffers / +0.026 util over the legalization cliff. The ADPLLs are the discretionary
"fill," so I trimmed them 12->10 to make room, dropping the two 7-bit FLL configs pi x coarsefine and
gear x binary. The remaining 10 still span ALL 3 loop filters, ALL 4 DCOs, both domains (7 FLL + 3
phase) and both tune widths, and index 0 (bb x binary, the Ethernet-UDP CSR test baseline) is
unchanged. Validated: make sim-adpll-array -> 10/10 lock in range + obs mux OK.
If 10+SD still overflows, next lever is 12->9 or shrink a 7-bit FLL config to 5-bit.

## 2026-06-27 — DECISION NEEDED: RMII clocking architecture for 50 MHz RX closure
After closing the TDC decode (multicycle) and RMII TX (forwarded generated-clock credit), the ONE
remaining 50 MHz timing failure is RMII RX (input_PAD[0..3] crs_dv/rx_er/rxd), and it is a genuine
architecture limit, not a constraint/modeling artifact:
  - In REF_CLK-In mode (current: chip forwards clk_PAD out bidir[3] as the PHY ref_clk), the PHY drives
    RXD valid up to t_oval=14 ns after ref_clk. With the ref_clk forwarding delay (clk -> bidir[3]
    output pad, ~5 ns) added, RX data arrives ~19-24 ns after the launching clk edge -- past the 20 ns
    capture window. STA (honest, referenced to the forwarded clock): -1.0 ns TT, -5.9 ns SS.
  - Neither edge helps: posedge is the best available (-1 ns TT); negedge captures a half-cycle EARLIER
    (worse, -4.3 ns); a 2-cycle multicycle is invalid (PHY drives new RXD every cycle). The FPGA
    reference only closed this via IDELAY/MMCM, which gf180 lacks.
OPTIONS (your call):
  (A) REF_CLK-Out mode: strap the LAN8720A to OUTPUT its 50 MHz REFCLKO and drive the chip's clk_PAD
      FROM it (board change: clk_PAD <- PHY REFCLKO instead of a crystal; bidir[3] ref_clk forward no
      longer needed). Then RX is captured on the same clock the PHY launched from -> full 20-14 = 6 ns
      budget, no forwarding penalty -> closes. RECOMMENDED for a clean 50 MHz RMII. Needs a chip_core
      clocking tweak + the board/strap.
  (B) Accept RMII RX as SS-corner-marginal for a test chip (it meets ~TT with board tuning; SS is the
      pessimistic extreme). Ship the 50 MHz GDS with the documented RX violation.
  (C) Lower the RMII line rate / run the datapath <50 MHz (loses 100 Mbps spec compliance).
Everything else closes at 50 MHz (core logic, SDRAM, SD, all 10 ADPLLs incl 3 phase, RMII TX).

---

## 2026-06-29 autonomous session — verified-GDS push (status @ ~11:45)

**v16 harden (bulletproof run: DELAY synth + corrected SDC + window>=2 clamp + LVS_IGNORE_CELLS):**
- SETUP: **ALL CORNERS CLEAN** — TT +5.96, FF +7.77, SS +1.93, 0 violations. (ADPLL FLL multicycle
  + window clamp closed the last SS path; was -0.216.)
- HOLD: reg-to-reg **CLEAN at all corners** (+0.27..+0.64). Residual = **54 I/O hold violations on
  SDRAM DQ/ctrl OUTPUTS** (bidir_PAD[12..25] vs forwarded sdram_clk_out), -0.3..-0.5 ns, worst at FF.
  Source-synchronous write-data hold; PLACEMENT-VARIANT (v15's placement met it at +0.66; v16 races).
  Router did 33193->54 (34k hold buffers) then hit RSZ-0064 at the 50% buffer budget.
  - PLAN: v17 with PL_RESIZER_HOLD_MAX_BUFFER_PCT 50->75 (+GRT) to finish the hold repair.
  - If it persists: the deterministic fix is centering the SDRAM clock in the data eye (negedge /
    180deg forwarded sdram_clk_out) -- standard SDRAM-write technique, but a design change to re-verify.
    For a test chip, accepting -0.5 ns FF-corner write-hold (board-tunable) is also defensible.
- DRC: 0 (pending v16 final confirm). LVS: expected clean (LVS_IGNORE_CELLS, matches uniquely).

**GLS (full-chip gate sim, make sim-gl on v15's real netlist):**
- Fixed: sdram_sim now builds in GL; RmiiSink resolves X->0 (gate idle TXD is X); adpll-csr test
  skips lock in GL (lock is the ngspice cosim's job).
- WORKS in gates: Ethernet RX -> ARP -> TX -> reply parse ("ARP reply OK"). eth MAC verified at gates.
- BLOCKED: the UDP-WRITE->memory->ack path times out in GL (both eth test line 168 and adpll-csr
  line 229 = the udp_write ack). ARP works (separate block); the IP/UDP-stack or memory-bridge/AXI
  write FSM stalls on X in gates. RTL sim passes the same tests -> this is gate-level X-propagation
  (likely an unreset FSM flop exposed by GL, or iverilog X-pessimism). 
  - NEXT: confirm RTL baseline passes; pinpoint the unreset flop (probe bridge/UDP FSM state in GL);
    if iverilog X-pessimism, robust path is VCS +initreg (X-init) -- the user wanted vcs/icarus+ngspice
    for PLLs anyway. PLL CSR/lock itself is covered by the green ngspice cosim.

### GLS root cause (important): 91% of flops are unreset (dfxtp)
Gate netlist: 31637 dfxtp (NO reset) vs 3143 dfsrtp (set/reset) = ~91% unreset. This is normal for
the vendored eth (alexforencich) + sdram (ultraembedded) datapath IP (area-driven, reset only the
control FSMs). In SILICON these power up to a defined random 0/1 and the datapath flushes them -- the
chip is functionally correct (RTL sim passes; FPGA-proven gold path). But ICARUS GL uses X-PESSIMISM:
an unreset control flop's X stalls the UDP-write handshake -> the write-ack timeout we see. (eth ARP
works because its flops are exercised/cleared quickly.)
=> NOT a chip bug; a GL-sim methodology issue. Proper full-chip GLS needs X-INIT:
   - VCS:  +initreg+0 (or +1) -- the user's suggested vcs path; resolves the X-pessimism cleanly.
   - Verilator: --x-initial unique / +verilator+rand+reset+2.
   - iverilog: no clean +initreg -> full datapath GLS is X-pessimism-limited (eth MAC does verify).
DECISION NEEDED (logged): set up VCS (or Verilator) GLS with reg X-init to verify eth/sdram/pll-csr
datapaths at gates. iverilog GLS already confirms the eth MAC RX->ARP->TX path works in gates.

### UPDATE @16:05 — v16 GDS verified clean (LVS confirmed)
v16 standalone LVS: "Circuits match uniquely" (274538=274538 devices) in ~9 min on the freer box.
=> The in-flow LVS hang was CPU STARVATION (it ran while the 3.4h iverilog GL sim + mrg gemmini
competed). Config was correct. So v16 = SETUP clean (all corners) + reg-to-reg HOLD clean + DRC 0
+ LVS match. Only residual: 54 SDRAM-output I/O hold (-0.3..-0.5ns).
LESSON: don't run heavy sims during a harden's LVS step (or run LVS standalone on the freer box).
v17 launched with hold-buffer budget 50->75% (+--skip Netgen.LVS to dodge starvation; confirm LVS
standalone after) to close the I/O hold.

### UPDATE @16:25 — GLS GREEN at gate-level (VCS) for eth/sdram/pll-csr
make sim-gl with SIM=vcs on v16's verified netlist: TESTS=3 PASS=3.
- test_arp_write_read  PASS  (Ethernet RX->ARP->TX + UDP write/read-back to on-chip mem, at gates)
- test_adpll_csr_over_udp PASS (UDP->bridge->ADPLL CSR @0x2000_0000 MUL/DIV/STATUS read-back, at gates)
- test_sdram_over_udp  PASS  (UDP->AXI->sdram_axi->external SDRAM write+read-back, at gates)
Keys: VCS +vcs+initreg+random (compile) +vcs+initreg+0 (run) resolves the 91%-unreset-flop X-prop;
GL keeps the ADPLL DISABLED (enabling the structural ring DCO explodes the zero-delay event queue ->
VCS RT_DYNEBLK2; the ring osc/lock is the ngspice cosim's job). ~400x faster than iverilog.
REMAINING for full GLS: SD-card file-to-LED (mode-muxed; needs an SD model + LED check) -- task #31.
PLL oscillation/lock: covered by the green ngspice cosim (make cosim / sim-adpll-csr).

### UPDATE — v17 (hold-buffer 75%) does NOT close the SDRAM-output I/O hold
v17 timing == v16 (hold -0.384/-0.483/-0.309, 17/36/2 vios, reg-to-reg=0). Raising the hold-buffer
budget 50->75% made no difference => the router cannot delay these output-to-pad paths enough; it's
a fundamental source-synchronous SKEW (DQ/ctrl launched on clk_PAD vs captured on the forwarded
sdram_clk_out), not a buffer-budget issue.

DECISION (user away -> logged, recommendation below):
The chip is OTHERWISE fully timing-clean: setup clean all corners, reg-to-reg hold clean, DRC 0,
LVS match. The only residual is 54 SDRAM-write-data/ctrl OUTPUT hold paths, -0.3..-0.5 ns at the
FAST corners.
  (A) ACCEPT for the test chip (RECOMMENDED). These are board-tunable source-synchronous write paths;
      reg-to-reg is clean; real margin is set by the W9825 tDH + board trace match + the controller's
      launch. -0.5 ns STA at the fast corner is within normal board-tuning range. Ship v16/v17 GDS.
  (B) DETERMINISTIC fix = center the SDRAM clock in the data eye: forward sdram_clk_out INVERTED
      (negedge / 180deg) so the SDRAM samples DQ mid-eye (~10 ns setup AND hold margin). Standard
      SDRAM-write technique (the vivado_nexys reference used negedge). Does NOT change internal
      all-posedge logic -- only the forwarded output clock. RISK: shifts the SDRAM READ capture by
      half a cycle -> needs the ultraembedded controller's read latency re-checked + re-run the GL
      test_sdram. ~1 design change + 1 harden + GLS re-confirm.
Recommendation: (A) for the test-chip tapeout; (B) if production-grade SDRAM write margin is wanted.
