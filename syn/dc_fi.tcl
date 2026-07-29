# SPDX-License-Identifier: Apache-2.0
# Copyright 2025-2026 the FIawase authors
# ============================================================
# dc_fi.tcl -- standalone Design Compiler driver for the FI flow.
#
#     dc_shell -f dc_fi.tcl          (or: make dc)
#
# This exists so that someone with Design Compiler and a standard cell
# library, but no established flow, can get from RTL to a scan-inserted,
# FI-ready netlist. It is intentionally minimal: read, constrain, hand
# over to scanchain.tcl.
#
# IF YOU ALREADY HAVE A FLOW, DO NOT USE THIS FILE. Get your design to
# the state described below and `source scanchain.tcl` instead -- that is
# how this was developed, against a Synopsys DC Reference Methodology
# setup, and scanchain.tcl carries no dependency on either.
#
# THE CONTRACT scanchain.tcl EXPECTS
# ----------------------------------
#   * current_design is the DUT top
#   * the design is elaborated, linked and uniquified
#   * timing constraints are applied
#   * the design is ALREADY MAPPED, by a plain compile_ultra. scanchain.tcl
#     then splices the freeze gate in and recompiles with -scan. This is
#     the order the flow was validated in, so this file reproduces it:
#         compile_ultra -no_seq_output_inversion -no_autoungroup   <- here
#         fi_insert_clock_gate / fi_apply_scan_exclusion           <- scanchain
#         compile_ultra -scan -no_seq_output_inversion -no_autoungroup
#         insert_dft
#     -no_autoungroup is load-bearing in BOTH compiles: flattening destroys
#     the hierarchy that ties a scan position to a named flop, and without
#     that the FI_Index -> flop map is meaningless.
#   * link_library resolves every macro; black boxes silently produce a
#     scan chain with holes in it
# ============================================================

set FI_ROOT [file dirname [file normalize [info script]]]

if {![file exists $FI_ROOT/tool_config.tcl]} {
    error "FI-ERROR: $FI_ROOT/tool_config.tcl not found -- copy tool_config.tcl.example to tool_config.tcl and edit it"
}
source $FI_ROOT/tool_config.tcl

# ---- libraries -----------------------------------------------------------
# DC resolves `include through search_path, so the RTL include directories
# go here rather than into an -I style option.
#
# The incoming $search_path is KEPT, not replaced: it is where dc_shell finds
# its own DesignWare (libraries/syn, dw/syn_ver). Drop it and compile_ultra
# cannot elaborate a single DW_* part, which for this DUT means the
# multiplier and the divider.
set_app_var search_path      [concat $FI_SEARCH_PATH $search_path $FI_RTL_INCDIRS]
set_app_var target_library   $FI_TARGET_LIBRARY
# Same reason: $synthetic_library is dw_foundation.sldb. It is empty in some
# installations, in which case this appends nothing.
set_app_var link_library     [concat $FI_LINK_LIBRARY $synthetic_library]
set_app_var symbol_library   [list]

define_design_lib WORK -path ./WORK

# ---- read ----------------------------------------------------------------
set fi_need_compile 1

if {$FI_INPUT_DDC ne ""} {
    # The "open the mapped database" entry point of an existing flow: this
    # is exactly what `make dc && make dc_open_net` leaves behind, and the
    # state scanchain.tcl was validated against. Already mapped and already
    # constrained, so neither is repeated.
    puts "FI-INFO: reading mapped design from $FI_INPUT_DDC"
    read_ddc $FI_INPUT_DDC
    current_design $FI_DESIGN_TOP
    set fi_need_compile 0

} else {
    set_app_var hdlin_autoread_verilog_extensions   ".v .vh"
    set_app_var hdlin_autoread_sverilog_extensions  ".sv .svh"

    analyze -autoread -recursive -library WORK \
            -define $FI_RTL_DEFINES \
            $FI_RTL_DIRS

    elaborate $FI_DESIGN_TOP
    current_design $FI_DESIGN_TOP
    link

    # Unique instance names, so a scan position can be tied to one named
    # flop. The FI_Index -> flop map is worthless without this.
    set_app_var uniquify_naming_style "${FI_DESIGN_TOP}_%s_%d"
    uniquify

    check_design > ./check_design.rpt
}

# ---- constraints ---------------------------------------------------------
# Sourced for both paths: harmless when the ddc already carries them, and
# essential when it does not.
source $FI_SDC

# ---- first compile -------------------------------------------------------
# The plain map, matching what `make dc` does in the flow this was
# developed against. scanchain.tcl inserts the freeze gate on the result
# and then recompiles with -scan. Skipped when FI_INPUT_DDC already gave
# us a mapped design.
#
# -no_autoungroup keeps the hierarchy, and the hierarchy is what lets a
# scan position be tied to a named flop. Do not drop it.
if {$fi_need_compile} {
    compile_ultra -no_seq_output_inversion -no_autoungroup
}

# ---- hand over -----------------------------------------------------------
# scanchain.tcl does the rest: splice in the freeze gate, exclude the
# frozen blocks, compile_ultra -scan, insert_dft, assert the five
# invariants, export the FI_Index -> flop map, print the verdict.
source $FI_ROOT/scanchain.tcl

exit
