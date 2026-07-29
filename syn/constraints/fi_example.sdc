# SPDX-License-Identifier: Apache-2.0
# Copyright 2025-2026 the FIawase authors
# ============================================================
# Minimal example constraints for tinyriscv_soc_top.
#
# Enough to get a sensible scan-inserted netlist out of dc_fi.tcl. It is
# NOT a sign-off SDC: no IO budgets, no derates, no multi-corner, no
# per-peripheral clock definitions. If you already have constraints for
# your design, point FI_SDC at those instead -- the FI flow needs nothing
# from this file that a normal SDC would not already contain.
#
# What the FI flow actually depends on:
#   * the functional clock is a real, named clock on FI_CLK_PORT, because
#     scanchain.tcl declares that same port as the DFT ScanClock
#   * the TCK domain is declared and marked asynchronous to it, because
#     jtag_TCK is in FI_EXEMPT_CLOCKS and assertion A3 resolves it via
#     all_registers -clock
#   * the reset on FI_RST_PORT is ideal, so DFT's -fix_reset has something
#     coherent to work with
# Everything else below is ordinary QoR setup.
# ============================================================

if { [info exists env(FREQ_SCALE)] } {
    set freq_scale $env(FREQ_SCALE)
} else {
    set freq_scale 1.0
}

set SYS_CLK_FREQ  [expr 50.0 * $freq_scale]   ;# MHz -> 20 ns
set JTAG_TCK_FREQ [expr 10.0 * $freq_scale]   ;# MHz -> 100 ns

# ---- clocks --------------------------------------------------------------
set sys_period [expr 1000.0 / $SYS_CLK_FREQ]
create_clock -name sys_clk_in -period $sys_period \
             -waveform [list 0.0 [expr $sys_period / 2.0]] \
             [get_ports clk_50m_i]
set_clock_uncertainty -setup [expr $sys_period * 0.2] [get_clocks sys_clk_in]

set tck_period [expr 1000.0 / $JTAG_TCK_FREQ]
create_clock -name jtag_TCK -period $tck_period \
             -waveform [list 0.0 [expr $tck_period / 2.0]] \
             [get_ports jtag_TCK_pin]
set_clock_uncertainty -setup [expr $tck_period * 0.2] [get_clocks jtag_TCK]

# A virtual clock for IO timing, so [all_inputs]/[all_outputs] have a
# reference even where no real clock reaches the pad.
create_clock -name virtual_clk -period $sys_period

# The debug TAP runs from the host adapter and is unrelated to the
# functional clock. This is also what makes jtag_TCK a legitimate entry in
# FI_EXEMPT_CLOCKS: its flops are neither shifted nor frozen, and that is
# only safe because the domain is idle during the scan window.
set_clock_groups -asynchronous -name fi_async_grp \
                 -group {sys_clk_in} -group {jtag_TCK}

# ---- reset ---------------------------------------------------------------
set_ideal_network [get_ports rst_ext_ni]

# ---- IO ------------------------------------------------------------------
# Library cells come from tool_config.tcl so that nothing foundry-specific
# is written down here.
set_input_transition -max 1 [all_inputs]
set_input_transition -min 1 [all_inputs]

if {[info exists FI_BUF_CELL] && $FI_BUF_CELL ne ""} {
    if {![info exists FI_BUF_CELL_PIN] || $FI_BUF_CELL_PIN eq ""} {
        set FI_BUF_CELL_PIN I
    }
    set fi_buf_pin [get_lib_pins -quiet $FI_BUF_CELL/$FI_BUF_CELL_PIN]
    if {[sizeof_collection $fi_buf_pin] > 0} {
        set_load [expr [load_of $fi_buf_pin] * 12] [all_outputs]
    } else {
        puts "FI-WARN: no lib pin $FI_BUF_CELL/$FI_BUF_CELL_PIN -- output load\
              not set. Fix FI_BUF_CELL / FI_BUF_CELL_PIN in tool_config.tcl."
    }
}
if {[info exists FI_IO_CELL] && $FI_IO_CELL ne ""} {
    set_driving_cell -lib_cell $FI_IO_CELL -pin $FI_IO_CELL_PIN \
                     -no_design_rule [all_inputs]
}

# ---- optimisation --------------------------------------------------------
set_max_area 0

# Mark the memory macros so downstream reporting can tell them apart. The
# filter is on ref_name, so it works whether or not T22NM is defined -- it
# simply matches nothing in the gen_ram case.
set sram_cells [get_cells -quiet -hierarchical -filter "ref_name =~ sram*"]
if {[sizeof_collection $sram_cells] > 0} {
    set_attribute $sram_cells I_am_sram_cell true
}
