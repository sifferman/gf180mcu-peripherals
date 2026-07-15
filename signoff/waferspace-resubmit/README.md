# wafer.space precheck submission

Density-fixed `chip_top.gds` submitted to the wafer.space gf180mcu precheck — **PASSED**
(2026-07-14). The GDS blob itself is git-ignored (360 MB); recorded here for provenance.

- **sha256:** `d60b956c2f06eba63ec92d59e8288cb822b7719fbdcbcca6a62f04e06faf01c5`
- **md5:** `e0e57e96ad83de91b9f5b2c4dedd44dc`
- **size:** 376752230 bytes

## How it was produced
Base layout: pre-fill (sealring) stage of `RUN_2026-07-08_13-52-47`, re-filled with the custom
KLayout filler `librelane/klayout_fill/` (orthogonal lattice, 2.5 um Metal2 cell at 1.0 um spacing).
This clears the M2.4 rule (Metal2 coverage > 30 %) that the stock staggered filler could not reach
(it topped out at 29.54 %). Verified locally with the PDK density, dummy_metal, and full DRC decks
(all 0 violations) before submission.
