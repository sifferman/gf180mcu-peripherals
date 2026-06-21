# Hardware / PCB notes

Reference for the breakout PCB. Not RTL-blocking; captured so it isn't lost.

## LAN8720A PHY strapping (from reference/8720a.pdf §3.7)

The design uses no MDIO, so the PHY is configured by reset-latched straps on its
RMII/LED pins. Augment with ~10 kΩ external resistors (the pins also carry live
signals). Pull high to VDDIO, except REGOFF/nINTSEL to VDD2A.

| Strap     | Shared pin        | Set to | Meaning |
|-----------|-------------------|--------|---------|
| MODE[2:0] | RXD0/RXD1/CRS_DV  | `111`  | All-capable, auto-negotiation enabled (Table 3.4) |
| PHYAD0    | RXER              | `0`    | SMI address 0 (unused — no MDIO) |
| nINTSEL   | LED2              | `1`    | REF_CLK **In** Mode — the chip sources the 50 MHz clock |
| REGOFF    | LED1              | low    | Use the PHY internal 1.2 V regulator (else feed 1.2 V to VDDCR) |

**Clocking:** REF_CLK In Mode → a 50 MHz oscillator drives the chip `clk_PAD`
and the PHY's XTAL1/CLKIN (the chip also forwards it as `ref_clk`). No 25 MHz
crystal on the PHY.

## Padring

Stock 74-pad 1×1 ring. For full x16 SDRAM, ~7 input-only positions are retyped to
bidir (`NUM_INPUT 12→5`, `NUM_BIDIR 40→47`) — same bondpad positions/power, only
the pad cell type changes. **The custom PCB must drive those retyped positions as I/O.**
