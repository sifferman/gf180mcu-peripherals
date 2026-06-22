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

# Bidirectional pads
set clk_core_inout_ports [get_ports { 
    bidir_PAD[*]
}] 

set_input_delay -min $input_delay_min_value -clock $clocks $clk_core_inout_ports
set_input_delay -max $input_delay_value -clock $clocks $clk_core_inout_ports
set_output_delay $output_delay_value -clock $clocks $clk_core_inout_ports

# Input-only pads
set clk_core_input_ports [get_ports { 
    rst_n_PAD
    input_PAD[*]
}] 

set_input_delay -min $input_delay_min_value -clock $clocks $clk_core_input_ports
set_input_delay -max $input_delay_value -clock $clocks $clk_core_input_ports

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

if { [info exists ::env(OPENLANE_SDC_IDEAL_CLOCKS)] && $::env(OPENLANE_SDC_IDEAL_CLOCKS) } {
    unset_propagated_clock [all_clocks]
} else {
    set_propagated_clock [all_clocks]
}

