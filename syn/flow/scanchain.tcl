# SPDX-License-Identifier: Apache-2.0
# Copyright 2025-2026 the FIawase authors
# ============================================================
# scanchain.tcl -- the example flow, second half: from the mapped design to
# the FI netlist and the files the wrapper and the host read
# ------------------------------------------------------------
# The FIawase steps (syn/fi_scan_lib.tcl) are called where they belong; the
# rest -- the compile options, the DFT reports, optimize_netlist, what is
# written -- is this example's own way of finishing. A flow of your own
# calls the same steps at the same points (syn/README.md) and finishes its
# own way. Sourced after the first compile, this file also works inside
# your session; dc_fi.tcl lists the state it expects.
#
# The freeze gate goes in series with whatever clock gating the DUT has
# (RTL gates, and with FI_GATE_CLOCK the ones compile inserts). Which blocks
# get frozen during the scan window is declared once, in the port's
# fi_scan_cfg.tcl, and applied here. See fi_scan_lib.tcl for why freezing
# and scan exclusion have to be the same decision.
# ============================================================
# Self-locating: this flow's directory, FIawase's synthesis directory above
# it, and the port directory (see dc_fi.tcl; without one, the example DUT).
set FI_ROOT [file dirname [file normalize [info script]]]
if {![info exists FI_LIB_DIR]} { set FI_LIB_DIR [file dirname $FI_ROOT] }
if {![info exists FI_PORT_DIR]} {
    if {[info exists ::env(FI_PORT_DIR)] && $::env(FI_PORT_DIR) ne ""} {
        set FI_PORT_DIR [file normalize $::env(FI_PORT_DIR)]
    } else {
        set FI_PORT_DIR [file normalize $FI_ROOT/../../examples/tinyriscv/port]
    }
}
source $FI_PORT_DIR/fi_scan_cfg.tcl
source $FI_LIB_DIR/fi_scan_lib.tcl

# Resolve where the artefacts go. Inherits the Synopsys DC RM variables if
# your flow defines them, otherwise falls back to the same filenames.
fi_step fi_init_flow_vars
# registers off the chain that the DUT reset does not put back get a clear (mapped netlist, before the scan compile)
fi_step fi_restore_clears

# ---- FIawase: the freeze and the exclusion, on the mapped design ----------
fi_step fi_insert_clock_gate
fi_step fi_apply_scan_exclusion

if {$FI_GATE_CLOCK} {
    compile_ultra -scan -gate_clock -no_seq_output_inversion -no_autoungroup
} else {
    compile_ultra -scan -no_seq_output_inversion -no_autoungroup
}

write -format ddc -hierarchy -output ${FI_RESULTS_DIR}/predft.ddc

# ---- FIawase: the DFT settings FI needs, then the chain -------------------
fi_step fi_dft_config
create_test_protocol
set FI_PORTS_PRE_DFT [lsort [get_object_name [get_ports *]]]
insert_dft
set FI_DFT_PORTS {}
foreach fi_p [lsort [get_object_name [get_ports *]]] {
    if {[lsearch -exact $FI_PORTS_PRE_DFT $fi_p] < 0} { lappend FI_DFT_PORTS $fi_p }
}

# Capture scan path and clock gating issues before running final DFT rule check
report_scan_path    > ${FI_REPORTS_DIR}/scan_path_debug.log
report_clock_gating > ${FI_REPORTS_DIR}/clock_gating_debug.log
report_dft_signal   > ${FI_REPORTS_DIR}/dft_signal_debug.log

# Run the DFT rule check
dft_drc
dft_drc -verbose > ${FI_REPORTS_DIR}/${FI_RPT_DRC_CONFIGURED}


write -format ddc -hierarchy -output ${FI_RESULTS_DIR}/postdft.ddc

optimize_netlist -area -no_seq_output_inversion

# ============================================================
# FIawase: prove the chain is actually injectable, on the netlist that is
# written -- after the last step that changes it, before change_names.
#
# HEADS UP: dc_shell's `source` does NOT stop on a Tcl error. This call
# raising "Error: FI-ERROR: ..." does not abort the rest of the script,
# so everything below still runs and still writes a netlist. What stops
# you from using a bad one is that fi_export_scanmap refuses to emit
# fi_scan_cfg.vh / fi_scan_cfg.tcl unless the check passed, and
# fi_report prints the verdict as the last thing on screen.
# Grep the log for "FI-FAIL".
# ============================================================
fi_check_invariants

change_names -rules verilog -hierarchy
set_svf -off

write_scan_def -output ${FI_RESULTS_DIR}/${FI_OUT_SCANDEF}
check_scan_def > ${FI_REPORTS_DIR}/${FI_RPT_CHECK_SCANDEF}
write_test_model -format ctl -output ${FI_RESULTS_DIR}/${FI_OUT_CTL}

report_dft_signal > ${FI_REPORTS_DIR}/${FI_RPT_DFT_SIGNALS}

write_test_protocol -output ${FI_RESULTS_DIR}/${FI_OUT_SPF}

# Conventional DFT output. (The FI_Index -> flop map is parsed from the
# copy fi__scan_order writes into the results, fi_scan_path.rpt.)
report_scan_path > ${FI_REPORTS_DIR}/${FI_RPT_SCAN_PATH}

dft_drc
dft_drc -verbose > ${FI_REPORTS_DIR}/${FI_RPT_DRC_FINAL}

# Promote VO-12 (a net driven by more than one source) to a hard stop. The
# gate insertion rewires clock pins by hand, so a stray leftover connection
# is exactly the mistake this flow can make, and it is silent otherwise.
unsuppress_message {VO-12}
set_message_info -id VO-12 -stop_on

# Written plainly, NOT wrapped in `redirect -bg ... /dev/null`. That form
# needs multicore mode (set_host_options -max_cores) and otherwise fails
# with BGE-007 -- into /dev/null, so the netlist silently never appears
# while the run still ends in PASS. The write output is a few lines; there
# is nothing here worth hiding, and the VO-12 stop_on above only means
# anything if its message can reach the log.
write -format verilog -hierarchy -output ${FI_RESULTS_DIR}/${FI_OUT_NETLIST}
write -format ddc     -hierarchy -output ${FI_RESULTS_DIR}/finaldft.ddc
write_sdf ${FI_RESULTS_DIR}/${FI_OUT_SDF}
write_sdc ${FI_RESULTS_DIR}/${FI_OUT_SDC}

if {![file exists ${FI_RESULTS_DIR}/${FI_OUT_NETLIST}]} {
    puts "FI-ERROR: no netlist at ${FI_RESULTS_DIR}/${FI_OUT_NETLIST} --\
          the write failed. Nothing downstream can use this run."
    exit 2
}

# ============================================================
# FIawase: export the FI_Index <-> flop map, then print the verdict.
#
# AFTER change_names -rules verilog, so the names written here are the
# ones you will see in the netlist and in the waveform viewer -- and
# last in the file, so the PASS/FAIL banner is the final thing on screen
# rather than being buried under DFT DRC output.
# ============================================================
fi_step fi_export_scanmap
fi_step fi_export_clock_gates
fi_step fi_report
