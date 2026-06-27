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
