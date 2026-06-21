# gf180mcu-peripherals

A 3.3 V GF180MCU test chip and **reusable-IP library** for future tapeouts, built on the
[wafer.space gf180mcu project template](https://github.com/wafer-space/gf180mcu-project-template).
It integrates four peripherals on a shared on-chip AXI fabric driven over Ethernet:

| Peripheral | Source | Status |
|---|---|---|
| **RMII Ethernet MAC + UDP→memory** (LAN8720A PHY) | [verilog-ethernet](https://github.com/alexforencich/verilog-ethernet) | ✅ integrated, RTL-sim passing |
| **SDRAM controller** (Winbond W9825G6KH, x16) | [ultraembedded/core_sdram_axi4](https://github.com/ultraembedded/core_sdram_axi4) | controller + behavioral-model sim ✅; on-bus integration WIP |
| **SD-card file→LED** | [WangXuan95 FPGA-SDcard-Reader](https://github.com/WangXuan95/FPGA-SDcard-Reader) | WIP |
| **Digital ring-oscillator PLL** (mux-chain DCO) | this repo | WIP |

A host PC writes/reads on-chip memory over plain UDP (no soft CPU) — a hardware state machine
turns UDP commands into AXI reads/writes. See `reference/vivado_nexys/docs/protocol.md`.

## Layout

```
src/            chip_top (pads), chip_core (integration), and reusable blocks:
  eth/          UDP→memory datapath (ported from reference/vivado_nexys)
  axi/          AXI4-Lite RAM (on-chip gold-path target)
  sdram/ sdcard/ dpll/ csr/   (per-peripheral, WIP)
third_party/    vendored submodules (verilog-ethernet, core_sdram_axi4, SD reader, cocotbext-eth)
cocotb/         testbenches; _eth/ = vendored deps-free RMII model; models/ = SDRAM behavioral model
ethernet-host/  dma.py — host UDP tool (ping/write/read/test)
librelane/      LibreLane (OpenLane2) flow config, slots, macros, PDN
docs/           hardware-notes.md (PHY strapping, padring)
```

## Build (LibreLane → GDS)

```
nix-shell                 # or: nix develop
make librelane            # 3.3 V flow: SCL as_sc_mcu7t3v3 / PAD ocd_io / SRAM ocd_ip_sram
```
Defaults are 3.3 V (Makefile). The PDK is fetched by `make clone-pdk` (pinned commit).

## Simulate

```
make sim          # RTL: ARP + UDP write/read-back over RMII (pure cocotb, no extra deps)
make sim-sdram    # standalone SDRAM controller + behavioral model (iverilog)
make sim-gl       # gate-level (after a run populates final/)
```

## Notes / decisions

- **3.3 V everywhere** (libs + CI). Stock 74-pad 1×1 ring; ~7 input pads retyped to bidir to fit
  the full x16 SDRAM bus (same bondpad positions — see `docs/hardware-notes.md`).
- Synthesis uses the **slang** frontend (`USE_SLANG`): yosys's default frontend cannot derive
  verilog-ethernet's parameterized CRC `lfsr` in finite time. Two small submodule patches
  (LOOP-style lfsr under yosys; cheap ARP-cache hash) make it tractable.
- FIFO depths and the ARP cache are sized down from the FPGA defaults for ASIC area.
- See `STATUS.md` for live progress and `questions.md` for open items.

Licensing: integrating WangXuan95's GPLv3 SD reader makes the combined design GPLv3; individual
reusable blocks keep their own permissive headers.
