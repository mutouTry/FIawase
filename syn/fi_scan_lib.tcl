# SPDX-License-Identifier: Apache-2.0
# Copyright 2025-2026 the FIawase authors
# ============================================================
# fi_scan_lib.tcl -- the DUT-independent half of the FI synthesis flow
# ------------------------------------------------------------
# Steps, in the order a Design Compiler flow calls them (syn/flow/dc_fi.tcl
# and syn/flow/scanchain.tcl are one such flow), by the file in lib/:
#
#   common      fi_init_flow_vars        first                     -- output paths
#   precompile  fi_pre_compile           before the first compile  -- edits on the generic netlist
#               fi_survey                after the first compile   -- optional: what a port classifies
#   resets      fi_restore_clears        mapped, first FI step     -- clears the DUT reset does not hold
#   scan        fi_insert_clock_gate     mapped, before insert_dft -- splice in the freeze
#               fi_apply_scan_exclusion  mapped, before insert_dft -- keep frozen blocks off the chain
#               fi_dft_config            before insert_dft         -- the DFT settings FI needs
#   checks      fi_check_invariants      final netlist, before change_names -- A1..A12
#   export      fi_export_scanmap        after change_names        -- the FI_Index -> flop map
#               fi_export_clock_gates    after change_names        -- every clock gate, for an FPGA
#               fi_report                last                      -- summary
#
# Everything DUT-specific is in the port's fi_scan_cfg.tcl, sourced before
# this file; how the RTL is read, the compile options and what is written
# belong to the flow. The flow does not use the Synopsys DC Reference
# Methodology, which cannot be redistributed: fi_init_flow_vars takes its
# variables when a flow defines them and otherwise uses the same file names.
#
# A frozen register must not be on the chain: it would miss the L shift edges
# and the chain could not be restored. So freezing and scan exclusion go
# together (set_scan_element false), and A2 checks the result.
# ============================================================

set fi__dir [file dirname [file normalize [info script]]]
if {![info exists FI_GATE_SRC]} { set FI_GATE_SRC [file join $fi__dir fi_clk_gate.v] }
foreach fi__f {common resets precompile scan checks export} {
    source [file join $fi__dir lib $fi__f.tcl]
}
unset fi__dir fi__f
