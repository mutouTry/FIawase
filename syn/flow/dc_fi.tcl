# SPDX-License-Identifier: Apache-2.0
# Copyright 2025-2026 the FIawase authors
# ============================================================
# dc_fi.tcl -- the example flow, first half: RTL to the mapped design.
#
#     dc_shell -f dc_fi.tcl          (or: make dc)
#
# One way to get from RTL to an FI-ready netlist with Design Compiler and a
# standard cell library, for a DUT that has no flow yet. It is intentionally
# minimal: read, constrain, the FIawase step that precedes the first compile,
# the first compile, then scanchain.tcl for the rest. Any DUT whose port
# directory holds a design.tcl and an fi_scan_cfg.tcl can use it.
#
# IF YOU ALREADY HAVE A FLOW, YOU DO NOT NEED THIS FILE. Call the FIawase
# steps of syn/fi_scan_lib.tcl from your own flow at the points listed in
# syn/README.md. This file and scanchain.tcl show where they go.
#
# THE STATE scanchain.tcl EXPECTS (when sourced into a flow of your own)
# ----------------------------------------------------------------------
#   * current_design is the DUT top
#   * the design is elaborated, linked and uniquified
#   * timing constraints are applied
#   * fi_pre_compile ran before the first compile (it edits the generic
#     netlist: test-mode splice, ties, black boxes, latch holds, clears,
#     clock-gating exclusions)
#   * the design is ALREADY MAPPED, by a plain compile_ultra. scanchain.tcl
#     then splices the freeze gate in and recompiles with -scan. This is
#     the order the flow was validated in, so this file reproduces it:
#         compile_ultra -no_seq_output_inversion -no_autoungroup   <- here
#         fi_insert_clock_gate / fi_apply_scan_exclusion           <- scanchain
#         compile_ultra -scan -no_seq_output_inversion -no_autoungroup
#         fi_dft_config, insert_dft
#     -no_autoungroup is load-bearing in BOTH compiles: the instances
#     fi_scan_cfg.tcl names (frozen, exempt) must survive as hierarchy, and
#     the checks match register paths against them.
#   * link_library resolves every macro. A memory without a .db is made a
#     black box on purpose (FI_BLACKBOX_MODULES; A9 requires it frozen);
#     any other unresolved cell is an error
# ============================================================

# This flow's directory, and FIawase's synthesis directory above it.
set FI_ROOT    [file dirname [file normalize [info script]]]
set FI_LIB_DIR [file dirname $FI_ROOT]

# The port directory holds the files that describe one DUT: design.tcl (how
# to read it), fi_scan_cfg.tcl (what is shifted or frozen) and the SDC. It
# defaults to the example DUT's, examples/tinyriscv/port. Point FI_PORT_DIR (Tcl
# variable or environment; make dc PORT=...) at your own directory to port
# another DUT without editing anything in this repository.
if {![info exists FI_PORT_DIR]} {
    if {[info exists ::env(FI_PORT_DIR)] && $::env(FI_PORT_DIR) ne ""} {
        set FI_PORT_DIR $::env(FI_PORT_DIR)
    } else {
        set FI_PORT_DIR $FI_ROOT/../../examples/tinyriscv/port
    }
}
set FI_PORT_DIR [file normalize $FI_PORT_DIR]

if {![file exists $FI_PORT_DIR/design.tcl]} {
    error "FI-ERROR: $FI_PORT_DIR/design.tcl not found"
}
source $FI_PORT_DIR/design.tcl

# The machine's side: the libraries, from site.mk through the environment
# (make dc), unless the session sourcing this file has set them already.
foreach fi__v {FI_SEARCH_PATH FI_TARGET_LIBRARY FI_MACRO_LIBRARY FI_BUF_CELL
               FI_BUF_CELL_PIN FI_IO_CELL FI_IO_CELL_PIN FI_INPUT_DDC} {
    if {[info exists $fi__v]} { continue }
    if {[info exists ::env($fi__v)]} { set $fi__v $::env($fi__v) } else { set $fi__v "" }
}
unset fi__v
if {$FI_TARGET_LIBRARY eq ""} {
    error "FI-ERROR: no standard cell library -- copy site.mk.example at the top of\
           FIawase to site.mk and fill it in"
}
if {![info exists FI_LINK_LIBRARY]} {
    set FI_LINK_LIBRARY [concat * $FI_TARGET_LIBRARY $FI_MACRO_LIBRARY]
}

# Relative paths in design.tcl are relative to the port directory, so a port
# works from any run directory.
proc fi__abs {p} {
    global FI_PORT_DIR
    if {$p eq "" || [file pathtype $p] ne "relative"} { return $p }
    return [file normalize [file join $FI_PORT_DIR $p]]
}
set fi__l {}
foreach d $FI_RTL_DIRS    { lappend fi__l [fi__abs $d] } ; set FI_RTL_DIRS    $fi__l
set fi__l {}
foreach d $FI_RTL_INCDIRS { lappend fi__l [fi__abs $d] } ; set FI_RTL_INCDIRS $fi__l
unset fi__l
set FI_SDC       [fi__abs $FI_SDC]
set FI_INPUT_DDC [fi__abs $FI_INPUT_DDC]

# The DUT description and the procs, early: fi_pre_compile below has to run
# before the first compile.
source $FI_PORT_DIR/fi_scan_cfg.tcl
source $FI_LIB_DIR/fi_scan_lib.tcl

# ---- libraries -----------------------------------------------------------
# DC resolves `include through search_path, so the RTL include directories
# go here rather than into an -I style option.
#
# The incoming $search_path is KEPT, not replaced: it is where dc_shell finds
# its own DesignWare (libraries/syn, dw/syn_ver). Drop it and compile_ultra
# cannot elaborate a single DW_* part, such as a multiplier or a divider.
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
    # The "open the mapped database" entry point of an existing flow: the
    # state scanchain.tcl expects. Already mapped and already
    # constrained, so neither is repeated.
    puts "FI-INFO: reading mapped design from $FI_INPUT_DDC"
    read_ddc $FI_INPUT_DDC
    current_design $FI_DESIGN_TOP
    fi_step fi_init_flow_vars
    # Sourced again: harmless when the ddc already carries the constraints,
    # and essential when it does not.
    source $FI_SDC
    set fi_need_compile 0

} else {
    set_app_var hdlin_autoread_verilog_extensions   ".v .vh"
    set_app_var hdlin_autoread_sverilog_extensions  ".sv .svh"

    analyze -autoread -recursive -library WORK \
            -define $FI_RTL_DEFINES \
            $FI_RTL_DIRS

    elaborate $FI_DESIGN_TOP
    current_design $FI_DESIGN_TOP
    if {![link]} {
        puts "FI-ERROR: link failed: an unresolved reference (LINK-5 / UID-341 above) -- every module the design\
              uses needs its source in FI_RTL_DIRS"
        exit 2
    }
    fi_step fi_init_flow_vars

    # Unique instance names, so a scan position can be tied to one named
    # flop. The FI_Index -> flop map is worthless without this.
    set_app_var uniquify_naming_style "${FI_DESIGN_TOP}_%s_%d"
    uniquify

    # Constraints first: fi_pre_compile tells a latch that gates a clock
    # from one that stores data by whether a clock reaches its enable.
    source $FI_SDC

    # Netlist edits that must precede the first compile: a test-mode pin
    # the RTL ties off, pins tied for FI, memories turned into black boxes,
    # holds on latches that store data, clock-gating exclusions. Compile
    # would otherwise propagate the tie-offs and remove the logic they
    # control. Does nothing for a DUT that needs none of them.
    fi_step fi_pre_compile

    check_design > ./check_design.rpt
}

# ---- first compile -------------------------------------------------------
# The plain map. scanchain.tcl inserts the freeze gate on the result
# and then recompiles with -scan. Skipped when FI_INPUT_DDC already gave
# us a mapped design.
#
# -no_autoungroup keeps the hierarchy, and the hierarchy is what lets a
# scan position be tied to a named flop. Do not drop it.
if {$fi_need_compile} {
    # FI_GATE_CLOCK 1: let compile insert clock gates, as a flow with power
    # optimisation would. insert_dft later ties their test pins to Scan_En.
    if {$FI_GATE_CLOCK} {
        compile_ultra -gate_clock -no_seq_output_inversion -no_autoungroup
    } else {
        compile_ultra -no_seq_output_inversion -no_autoungroup
    }
    # The mapped design before the FI stage. Point FI_INPUT_DDC at it to
    # iterate on fi_scan_cfg.tcl without compiling from RTL again.
    write -format ddc -hierarchy -output ${FI_RESULTS_DIR}/${FI_TOP}.compiled.ddc
}

# ---- survey (optional) ---------------------------------------------------
# FI_SURVEY 1 writes the survey of clocks, clock gates, memories, latches and
# reset-less flops (fi_survey.rpt) before the FI stage; FI_SURVEY only stops
# here, which is how a port starts: survey, write fi_scan_cfg.tcl, re-run.
if {$FI_SURVEY ne "0"} {
    fi_step fi_survey
    if {$FI_SURVEY eq "only"} { exit }
}

# ---- hand over -----------------------------------------------------------
# scanchain.tcl does the rest: splice in the freeze gate, exclude the
# frozen blocks, compile_ultra -scan, the FI DFT settings and insert_dft,
# this flow's post-DFT steps, the invariants on the final netlist, then the
# FI_Index -> flop map and the verdict.
source $FI_ROOT/scanchain.tcl

exit
