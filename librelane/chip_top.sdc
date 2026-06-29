current_design $::env(DESIGN_NAME)
set_units -time ns

set clock_port __VIRTUAL_CLK__
if { [info exists ::env(CLOCK_PORT)] } {
    set port_count [llength $::env(CLOCK_PORT)]

    if { $port_count == "0" } {
        puts "\[WARNING] No CLOCK_PORT found. A dummy clock will be used."
    } elseif { $port_count != "1" } {
        puts "\[WARNING] Multi-clock files are not currently supported by the base SDC file. Only the first clock will be constrained."
    }

    if { $port_count > "0" } {
        set ::clock_port [lindex $::env(CLOCK_PORT) 0]
    }
}

if { $::env(CLOCK_PORT) == $::env(CLOCK_NET) } {
    set port_args [get_ports $clock_port]
} else {
    # This should actually use CLOCK_PIN?
    set port_args [get_pins [lindex $::env(CLOCK_NET) 0]]
}

puts "\[INFO] Using clock $clock_port…"
create_clock {*}$port_args -name $clock_port -period $::env(CLOCK_PERIOD)

set input_delay_value [expr $::env(CLOCK_PERIOD) * $::env(IO_DELAY_CONSTRAINT) / 100]
set output_delay_value [expr $::env(CLOCK_PERIOD) * $::env(IO_DELAY_CONSTRAINT) / 100]
# Minimum (earliest) input arrival. A real source-synchronous driver (e.g. the
# LAN8720A RMII RX) holds its data for several ns after the clock edge, so the
# default -min of 0 (data racing the clock edge) creates spurious input-port hold
# violations at the first capture flop. Model ~10% of the period of input hold.
set input_delay_min_value [expr $::env(CLOCK_PERIOD) * 0.10]
puts "\[INFO] Setting output delay to: $output_delay_value"
puts "\[INFO] Setting input delay to: $input_delay_value"

set_max_fanout $::env(MAX_FANOUT_CONSTRAINT) [current_design]
if { [info exists ::env(MAX_TRANSITION_CONSTRAINT)] } {
    set_max_transition $::env(MAX_TRANSITION_CONSTRAINT) [current_design]
}
if { [info exists ::env(MAX_CAPACITANCE_CONSTRAINT)] } {
    set_max_capacitance $::env(MAX_CAPACITANCE_CONSTRAINT) [current_design]
}

set clocks [get_clocks $clock_port]

# --- Forwarded clocks (generated from clk_PAD) -----------------------------------------------------
# The chip drives clk_PAD out as the RMII ref_clk (bidir_PAD[3]) and the SDRAM clock (bidir_PAD[24]);
# the PHY and SDRAM sample relative to THOSE forwarded clocks, not clk_PAD directly. Model them as
# divide-by-1 generated clocks and reference each interface's I/O delays to them, so STA credits the
# clock-forwarding insertion delay (data and the forwarded clock share the same output-pad delay -- a
# ~5 ns common-mode term that a clk_PAD-relative model omits, which falsely failed the RMII TX at SS).
# In normal mode bidir_PAD[3] = clk through the SD mux; in SD mode it is sd_reset (static, not timed).
set CGC_SRC [get_pins $::env(CLOCK_NET)]
# REF_CLK-Out mode (chosen): the LAN8720A sources the 50 MHz RMII ref_clk (REFCLKO) onto clk_PAD, so
# clk_PAD IS the shared ref_clk -- RMII I/O is referenced to it directly with NO forwarding delay (the
# PHY launches RX/captures TX on the same clock the chip uses), which is what lets RMII RX close at
# 50 MHz. Only the SDRAM clock is still chip-driven (forwarded out bidir_PAD[24]); model THAT as a
# generated clock so the SDRAM I/O gets its clock-forwarding credit.
catch { create_generated_clock -name sdram_clk_out -source $CGC_SRC -divide_by 1 [get_ports {bidir_PAD[24]}] }
set rmii_clk  $clock_port
set sdram_clk [expr {[llength [get_clocks -quiet sdram_clk_out]] ? {sdram_clk_out} : $clock_port}]
puts "\[INFO] RMII I/O referenced to clock: $rmii_clk ; SDRAM I/O referenced to: $sdram_clk"

# =================================================================================================
# Per-interface I/O timing from the device datasheets.
#
# Clocking (REF_CLK-Out mode): the LAN8720A sources the 50 MHz RMII ref_clk (REFCLKO) onto clk_PAD,
# so clk_PAD is the shared RMII reference -- RMII I/O references clk_PAD directly (no forwarding). The
# SDRAM clock is still chip-driven (forwarded out bidir_PAD[24]) and is modeled as a generated clock
# above so its I/O gets the clock-forwarding credit. Board trace delay not included -- add per the PCB.
# Datasheet sources:
#   - LAN8720A, Table 5.9 "REF_CLK Out Mode" (p.71): the PHY sources REFCLKO (Option A). Note these
#     differ from the In-mode table -- RX valid is MUCH tighter to the clock (5 ns) and TX needs more
#     setup (7 ns), because the PHY launches RX off the clock it generates.
#       RX (PHY->MAC) output-valid t_oval(max)=5.0 ns, output-hold t_ohold(min)=1.4 ns
#       TX (MAC->PHY) setup t_su=7.0 ns, hold t_ihold=2.0 ns
#   - Winbond W9825G6KH AC table (p.15), -6 grade, CAS latency 3:
#       read   DQ: access tAC(max)=5.0 ns, output-hold tOH(min)=3.0 ns
#       inputs   : setup tIS=1.5 ns, hold tIH=0.8 ns (common to cmd/addr/cke/dqm/write-DQ)
# Pad map (normal datapath mode) from chip_core.sv:
#   input_PAD[0..3] = RMII crs_dv/rx_er/rxd0/rxd1   input_PAD[4] = mode strap (static)
#   bidir_PAD[0..2] = RMII tx_en/txd0/txd1   [3] = spare (PHY sources ref_clk)   [4..7] = status LEDs
#   bidir_PAD[8..23] = SDRAM DQ[15:0] (bidir)   [24] = SDRAM clk(out)
#   bidir_PAD[25..29] = cke/cs/ras/cas/we   [30..31] = dqm   [32..44] = addr   [45..46] = ba
# =================================================================================================

# --- RMII RX inputs (PHY -> MAC), launched off REF_CLK ---
set rmii_rx_in [get_ports {input_PAD[0] input_PAD[1] input_PAD[2] input_PAD[3]}]
set_input_delay -clock $rmii_clk -max 5.0 $rmii_rx_in
set_input_delay -clock $rmii_clk -min 1.4 $rmii_rx_in

# --- RMII TX outputs (MAC -> PHY), sampled by the PHY off REF_CLK ---
set rmii_tx_out [get_ports {bidir_PAD[0] bidir_PAD[1] bidir_PAD[2]}]
set_output_delay -clock $rmii_clk -max 7.0  $rmii_tx_out
set_output_delay -clock $rmii_clk -min -2.0 $rmii_tx_out

# --- SDRAM command/address/control outputs (bidir_PAD[25..46]): tIS=1.5 / tIH=0.8 ---
set sdram_ctrl_names {}
for {set i 25} {$i <= 46} {incr i} { lappend sdram_ctrl_names "bidir_PAD\[$i\]" }
set sdram_ctrl_out [get_ports $sdram_ctrl_names]
set_output_delay -clock $sdram_clk -max 1.5  $sdram_ctrl_out
set_output_delay -clock $sdram_clk -min -0.8 $sdram_ctrl_out

# --- SDRAM DQ[15:0] (bidir_PAD[8..23]): write = output (tIS/tIH), read = input (tAC/tOH) ---
set sdram_dq_names {}
for {set i 8} {$i <= 23} {incr i} { lappend sdram_dq_names "bidir_PAD\[$i\]" }
set sdram_dq [get_ports $sdram_dq_names]
set_output_delay -clock $sdram_clk -max 1.5  $sdram_dq
set_output_delay -clock $sdram_clk -min -0.8 $sdram_dq
set_input_delay  -clock $sdram_clk -max 5.0  $sdram_dq
set_input_delay  -clock $sdram_clk -min 3.0  $sdram_dq

# --- Bidir pad output-enables (OE): NOT data, do not apply tIS/tIH ---
# A pad's tristate output-enable is bus-DIRECTION control, not a tIS/tIH-governed data signal. The DQ
# output_delay above (correctly, for the write DATA) otherwise also charges the OE paths the SDRAM's
# 0.8 ns tIH -- and the OE is launched from clk_PAD's short core-tree latency yet captured against the
# forwarded sdram_clk_out's long latency, so those paths failed hold by ~1.9 ns at every corner. But
# the OE only changes at read<->write turnaround, which the SDRAM protocol surrounds with multiple
# NOP/precharge/CL cycles -- it has many cycles of margin, never a single-cycle tIH requirement. Same
# is true of every other bidir pad's OE (RMII TX / SD / ctrl pads are output-only -> OE tied static).
# So exclude all bidir-pad OE pins from timing. Verified: worst hold -1.95 -> +0.57 ns, 0 violations,
# while the real SDRAM write-DATA paths stay fully timed (they already met hold). NOT a data false-path.
set oe_pins [get_pins -hierarchical -quiet {bidir*.pad/OE}]
if { [llength $oe_pins] > 0 } {
    puts "\[INFO] Bidir OE: false_path THROUGH [llength $oe_pins] pad output-enable pins (direction ctrl, not tIH data)"
    # -THROUGH, not -to: the timing path ENDS at the output PORT (bidir_PAD[n]) and merely routes
    # THROUGH the pad's OE pin to the PAD; a -to on the OE pin does not cut a path that ends past it.
    set_false_path -through $oe_pins
}

# --- SD-card response inputs share bidir_PAD[1] (CMD) / [2] (DAT0) in SD mode ---
# SD is a slow, divided-clock (clk/CLK_DIV ~ 6-12 MHz) source-synchronous interface and the reader
# oversamples, so it is far less critical than the 50 MHz datapath that shares these pads. The tight
# RMII-TX output constraint above already dominates; add only a relaxed input constraint so the SD
# read path is bounded, not unconstrained. (Approximate -- a precise model would use a divided clock.)
set sd_resp_in [get_ports {bidir_PAD[1] bidir_PAD[2]}]
set_input_delay -clock $clocks -max [expr $::env(CLOCK_PERIOD) * 0.5] $sd_resp_in
set_input_delay -clock $clocks -min 0.0 $sd_resp_in

# --- SD-card reader sector-number arithmetic: multicycle ---
# read_sector_no = first_data_sector + cluster_size * curr_cluster + offset -- a 32-bit multiply+add
# evaluated only when the FAT FSM advances a cluster/sector, after which the reader streams a full 512 B
# sector over the slow (clk/CLK_DIV) SD bus = thousands of clk cycles before read_sector_no changes
# again. So this deep arithmetic has many cycles to settle; STA otherwise treats it as 1-cycle and it
# is the lone -2 ns SS violator. Declare it a 2-cycle multicycle (unconditionally valid here -- every
# update is followed by a long SD transfer). Anchored on the read_sector_no nets (32, regs renamed by
# synthesis); this is the SD reader's only deep path. Guarded.
# Anchor -TO the whole FAT-arithmetic register group, not just read_sector_no: the SS violators
# converge on TWO register clusters -- (a) read_sector_no, fed by first_data_sector + cluster_size*
# curr_cluster + offset; and (b) first_data_sector_no / first_fat_sector_no, which carry the *chained*
# multiplies sectors_per_fat*number_of_fat and cluster_size*2 out of the FAT sector buffer. Both are
# computed only when the FAT FSM advances, after which the reader streams a full 512 B sector over the
# slow SD bus before any of them changes again -- so they are all genuine compute-once/hold-thousands-
# of-cycles paths. get_cells -of these nets yields the driving FFs (renamed by synthesis); STA applies
# the setup multicycle to those endpoints. Valid: every update is gated by a full SD sector transfer.
set fat_regs [get_cells -quiet -of_objects [get_nets -hierarchical -quiet { \
    *read_sector_no* *first_data_sector_no* *first_fat_sector_no* \
    *curr_cluster* *rootdir_sector* *cluster_size* *cluster_sector_offset* }]]
if { [llength $fat_regs] > 0 } {
    puts "\[INFO] SD: FAT-arithmetic 2-cycle multicycle TO [llength $fat_regs] cells"
    set_multicycle_path 2 -setup -to $fat_regs
    set_multicycle_path 1 -hold  -to $fat_regs
}

# --- Status LEDs (bidir_PAD[4..7]) drive LEDs only: no capture flop, no setup requirement ---
set_false_path -to [get_ports {bidir_PAD[4] bidir_PAD[5] bidir_PAD[6] bidir_PAD[7]}]

# --- mode strap (input_PAD[4]): static configuration, never toggles in operation ---
set_false_path -from [get_ports {input_PAD[4]}]

# --- Reset (rst_n_PAD): externally asserted, ASYNChronous (button / power-on), held for many cycles --
# rst_n has NO synchronous launch relative to clk_PAD, so the previous -max of 0.5*period (10 ns) was
# pure over-pessimism: it charged the reset 10 ns of fictitious "external" arrival, leaving only ~10 ns
# for its (legitimately large, ~900-flop) on-chip distribution fan-out -> 146 of 151 SS setup fails all
# traced to this one port. A held external reset is, if anything, EARLY/stable at the clock edge, so a
# small input_delay (here 2 ns of board/pad budget) is the honest model -- it KEEPS the internal reset
# distribution timed (so a pathological reset cone would still be caught) without the bogus 10 ns. This
# is NOT a false_path: the reset-distribution logic still meets setup with margin; we only removed the
# fictional external delay. (Proper deassertion cleanliness is a reset-synchronizer's job, in RTL.)
set_input_delay -clock $clocks -max 2.0 [get_ports {rst_n_PAD}]
set_input_delay -clock $clocks -min 0.0 [get_ports {rst_n_PAD}]

# Forwarded clock outputs bidir_PAD[3] (RMII ref_clk) and bidir_PAD[24] (SDRAM clk) carry clk_PAD to
# the peripherals -- they are clocks, not data, so they intentionally get NO data output delay.

# Output load
set cap_load [expr $::env(OUTPUT_CAP_LOAD) / 1000.0]
puts "\[INFO] Setting load to: $cap_load"
set_load $cap_load [all_outputs]

puts "\[INFO] Setting clock uncertainty to: $::env(CLOCK_UNCERTAINTY_CONSTRAINT)"
set_clock_uncertainty $::env(CLOCK_UNCERTAINTY_CONSTRAINT) $clocks

puts "\[INFO] Setting clock transition to: $::env(CLOCK_TRANSITION_CONSTRAINT)"
set_clock_transition $::env(CLOCK_TRANSITION_CONSTRAINT) $clocks

puts "\[INFO] Setting timing derate to: $::env(TIME_DERATING_CONSTRAINT)%"
set_timing_derate -early [expr 1-[expr $::env(TIME_DERATING_CONSTRAINT) / 100]]
set_timing_derate -late [expr 1+[expr $::env(TIME_DERATING_CONSTRAINT) / 100]]

# --- ADPLL ring-DCO clock (observe-only, free-running) ------------------------------
# The ring DCO is a self-timed oscillator. chip_core does `assign analog[0] = pll_dco_clk`,
# so after synthesis the DCO oscillation net IS analog_PAD[0] (the final ring mux drives
# .Y(analog_PAD[0]) and the feedback NAND reads .B(analog_PAD[0])); it also clocks the
# frequency-measure counter. It MUST be declared a clock: leaving it undefined makes CTS add
# clock-tree nets that the LVS netlist lacks (53 unmatched CLK nets -> "Netlists do not
# match"). Declare it (nominal fastest-corner 2 ns / 500 MHz) and make it asynchronous to the
# core clock so STA treats the freq_meas CDC correctly. Guarded so builds without the ADPLL
# are unaffected. The ring's combinational loop is broken by the timing engine; the ring
# cells are preserved by (* keep *)/(* dont_touch *) in ring_dco.sv.
# The ADPLL ring-DCO clock (pll_dco_clk) is a free-running self-timed oscillator that clocks
# the frequency-measure counter. It is intentionally left undefined as an SDC clock: its source
# is a combinational loop with no valid clock-tree root (defining it crashes TritonCTS), so STA
# treats the small, async, observe-only counter domain as unconstrained. Its CDC into clk_i is
# handled in RTL (Gray-coded). It is NOT routed to a pad (the analog pads can't carry routed
# digital signals); observability is via the CSR STATUS register over Ethernet.

# --- ADPLL ring-DCO oscillators: not synchronous datapaths ---------------------------------------
# Each ring DCO is a self-timed oscillator: a (* dont_touch *) chain of inv/mux/nand cells whose
# combinational delay IS the oscillation period (tens of ns by construction). The only clk_PAD
# connections are (a) the tune bits, which are quasi-static -- written once over the CSR, then held
# during lock -- and (b) the ring output, consumed by the DCO's own free-running frequency counter,
# NOT captured on clk_PAD in a single cycle. Left unconstrained, OpenSTA traces tune_reg -> ring
# inverter chain -> a clk_PAD flop and charges the full oscillator delay to the clk_PAD setup budget,
# producing a large false violation that masks the true core critical path. Exclude every path
# through the ring cells from clk_PAD timing. (OpenSTA already auto-breaks the ring's combinational
# loop; `set_dynamic_loop_breaking` would auto-generate the loop exceptions too, but the explicit
# -through is targeted and deterministic -- it does not depend on which arc STA picks to break.)
# Pattern verified against the routed netlist: 738 ring-DCO cells across the 10 PLLs. Guarded so a
# build without the ADPLL array is unaffected.
set dco_cells [get_cells -hierarchical -quiet {*ring_dco_*}]
if { [llength $dco_cells] > 0 } {
    puts "\[INFO] ADPLL: false-pathing [llength $dco_cells] ring-DCO cells out of clk_PAD timing"
    set_false_path -through $dco_cells
}

# --- ADPLL flash TDC delay line: a DCO-vs-reference time measurement, not a synchronous path -------
# The phase-domain TDC (adpll_tdc_flash) launches the DCO clock edge down a (* dont_touch *) chain of
# dlybuff delay cells (adpll_cell_delay) and latches the whole line on the reference edge -- the
# edge's position = elapsed DCO time. The delay line is intentionally ~one DCO period long (tens of
# ns), and the launch (DCO) and capture (reference) clocks are asynchronous, so the line->sampler
# path is a CDC measurement, not a setup-constrained datapath. Like the ring DCO, STA otherwise
# charges the full delay-line length to the reference-clock setup budget (this was the real worst
# path at the SS corner). False-path through the delay cells; the sampler->priority-encoder->phase_o
# logic does NOT pass through them and is still timed normally. 186 delay cells verified on the
# routed netlist. (The delay-line nets are also held don't-touch via RSZ_DONT_TOUCH_RX so no buffer
# splices the calibrated line -- same rationale as the ring.)
set tdc_cells [get_cells -hierarchical -quiet {*adpll_cell_delay*}]
if { [llength $tdc_cells] > 0 } {
    puts "\[INFO] ADPLL: false-pathing [llength $tdc_cells] TDC delay-line cells out of reference timing"
    set_false_path -through $tdc_cells
}

# --- ADPLL flash-TDC decode: a 4-cycle multicycle (matches the RTL snapshot decimation) -----------
# The TDC's combinational decode (a NumPhaseUnits-wide priority encode + a divide) is too deep to
# settle in one 50 MHz cycle. The RTL (adpll_tdc_flash, PhaseTdcSampleEveryN=4) snapshots the delay
# line and re-registers phase_o/period_valid only every 4 reference cycles, so the sampled -> decode
# -> phase_o path genuinely has 4 cycles -- a VALID multicycle (the launch register is stable for 4
# cycles), not a relaxation. The phase loop bandwidth is far below the reference rate, so the slower
# phase update is harmless. Declare setup=4 / hold=3 from the TDC snapshot registers. Guarded.
# Anchor on the snapshot NETS (sampled[*]), not the flop instances: synthesis renames the inferred
# flops (no "sampled" in the instance name) but the nets keep it (189 across the 3 phase PLLs,
# verified on the floorplanned netlist). A path -through a sampled net is exactly sampled_flop -> Q ->
# decode -> phase_o register, i.e. the deep decode; the delay-line -> sampled.D side uses other nets
# (and is false-pathed above), and the sample counter/enables are untouched.
set tdc_samp [get_nets -hierarchical -quiet {*adpll_tdc_flash*sampled*}]
if { [llength $tdc_samp] > 0 } {
    puts "\[INFO] ADPLL: TDC decode 4-cycle multicycle through [llength $tdc_samp] snapshot nets"
    set_multicycle_path 4 -setup -through $tdc_samp
    set_multicycle_path 3 -hold  -through $tdc_samp
}

# --- ADPLL FLL loop-filter accumulator: a 2-cycle multicycle (genuinely multicycle) ---------------
# The loop-filter tune accumulator (a wide add/clamp -- DELAY synthesis maps it to a parallel-prefix
# adder, but it is still deep at the SS 125C/3v00 corner) updates ONLY when the frequency detector
# emits a new error strobe (loop_filter valid_i), which fires once per measurement window of
# window_length_i reference cycles (adpll_freq_counter: window_tick = count >= window_length_i-1).
# A 1-cycle window is non-functional (can't measure a frequency from one clk cycle), so in any real
# config window_length_i >= 2 and the accumulator is stable for >= 2 cycles between updates -- a VALID
# 2-cycle multicycle, not a relaxation. (For a HARDWARE guarantee independent of firmware, clamp
# window_length_i >= 2 in adpll_freq_counter; tracked as a follow-up in sifferman/adpll.) Anchor -TO
# the registers driving the CSR tune readback nets (adpll_array_csr.tune_i) -- these are the loop-
# filter tune_q accumulators across the 10 PLLs (440 cells incl. the readback-mux loads; the
# multicycle applies only to the register endpoints among them). Verified on the routed netlist:
# SS setup -0.22 -> +2.67 ns; the next-worst real single-cycle path is +2.67 (nothing real hidden).
set fll_tune [get_cells -quiet -of_objects [get_nets -hierarchical -quiet {*adpll_array_csr*tune_i*}]]
if { [llength $fll_tune] > 0 } {
    puts "\[INFO] ADPLL: FLL loop-filter 2-cycle multicycle TO [llength $fll_tune] tune-accumulator cells"
    set_multicycle_path 2 -setup -to $fll_tune
    set_multicycle_path 1 -hold  -to $fll_tune
}

if { [info exists ::env(OPENLANE_SDC_IDEAL_CLOCKS)] && $::env(OPENLANE_SDC_IDEAL_CLOCKS) } {
    unset_propagated_clock [all_clocks]
} else {
    set_propagated_clock [all_clocks]
}

