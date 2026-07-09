## SDRAM Model

The Winbond W9825G6KH SDRAM simulation model cannot be distributed with this
repository due to copyright restrictions. You must download it yourself:

1. Go to the [Winbond support product page](https://www.winbond.com/hq/support/documentation)
2. Download the Verilog simulation model for W9825G6KH
3. Extract the files. You will need:
   - `Config-AC.v` — timing parameter definitions
   - `W9825G6KH.vcs.vp` — VCS encrypted model (or `.modelsim.vp` / `.nc.vp` for other simulators)

## Eventual Struture for Cocotb

```bash
make SIM=vcs \
    SDRAM_MODEL=/path/to/W9825G6KH.vcs.vp \
    SDRAM_CONFIG=/path/to/Config-AC.v
```
