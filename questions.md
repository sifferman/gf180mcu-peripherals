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
