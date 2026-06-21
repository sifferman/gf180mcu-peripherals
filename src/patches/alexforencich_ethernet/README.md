# alexforencich_ethernet local overrides

These files **replace** the same-named files in the `third_party/alexforencich_ethernet`
submodule at build time — the submodule stays pristine (no upstream commits).
The build (librelane/config.yaml VERILOG_FILES + cocotb/chip_top_tb.py) points here
for these two files and to the submodule for everything else.

- `lfsr.v`      — see header; works around yosys/yosys-slang issues with the CRC lfsr.
- `arp_cache.v` — see header; replaces the wide (DATA_WIDTH=32) lfsr hash.

See questions.md "yosys / yosys-slang lfsr issue" for the upstream-patch TODO.
