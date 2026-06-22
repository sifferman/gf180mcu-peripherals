// Simulation time precision for the standalone iverilog targets ONLY (not design RTL).
// The design carries no `timescale; all #-delays use explicit time-unit literals (e.g. 1ns).
// iverilog needs a precision to interpret them, so this file is compiled first to set it.
// Synthesis (yosys/slang) and cocotb (runner timescale) ignore / supply this separately.
`timescale 1ns/1ps
