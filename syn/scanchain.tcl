# SPDX-License-Identifier: Apache-2.0
# Copyright 2025-2026 the FIawase authors
# ============================================================
# FI wrapper: freeze gate insertion + scan exclusion
# ------------------------------------------------------------
# The RTL contains no clock gating at all. Which blocks get frozen
# during the scan window is declared once, in fi_scan_cfg.tcl, and
# applied here. See fi_scan_lib.tcl for why freezing and scan
# exclusion have to be the same decision.
#
# This replaces the old block of set_dont_touch commands. Those did
# keep instances off the chain (by blocking the scan-flop swap), but
# they were a blunt instrument: they cost QoR, they say nothing about
# intent, and they never froze anything -- so an instance could be
# dont_touch'd and still running during the window, or gated in RTL and
# still stitched into the chain. That divergence is exactly what
# fi_check_invariants now refuses to let through.
# ============================================================
# Self-locating: these three files travel together, so find them next to
# this script rather than through an environment variable the caller has
# to know about.
set FI_ROOT [file dirname [file normalize [info script]]]
source $FI_ROOT/fi_scan_cfg.tcl
source $FI_ROOT/fi_scan_lib.tcl

# Resolve where the artefacts go. Inherits the Synopsys DC RM variables if
# your flow defines them, otherwise falls back to the same filenames.
fi_init_flow_vars

fi_insert_clock_gate
fi_apply_scan_exclusion

#compile_ultra -scan -gate_clock -no_seq_output_inversion -no_autoungroup
compile_ultra -scan -no_seq_output_inversion -no_autoungroup

write -format ddc -hierarchy -output ${FI_RESULTS_DIR}/predft.ddc

# Two settings that exist to protect the FI_Index -> flop map.
#
# Keeping the design name stable, and doing no optimisation during DFT
# insertion, means the flop names in the exported map are the same objects
# fi_check_invariants classified a moment earlier. Let insert_dft re-optimise
# and the assertions have been run against a netlist that no longer exists.
set_dft_insertion_configuration -preserve_design_name true
set_dft_insertion_configuration -synthesis_optimization none

# One chain across the whole DUT, so clocks have to be allowed to mix. This
# is safe here for a reason specific to this flow rather than to DFT: every
# clock domain that could not tolerate being shifted is already off the chain
# entirely, either frozen (FI_GATE_PINS) or declared out of scope
# (FI_EXEMPT / FI_EXEMPT_CLOCKS). What is left is one coherent domain.
set_scan_configuration -clock_mixing mix_clocks


# NEVER declare the gated branch ($FI_GATE_NET) as a ScanClock. Only the
# free-running functional clock may be one. A flop whose clock is not a
# ScanClock has no test clock and is not a scan candidate, which is the
# second, implicit reason the frozen blocks stay off the chain -- and
# the first, explicit one (set_scan_element false) is applied above.
set_dft_signal -view existing_dft -type ScanClock -timing [list 45 55] -port $FI_CLK_PORT
set_dft_signal -view spec         -type ScanClock -port $FI_CLK_PORT

set_dft_signal -view existing_dft -type Reset -active_state 0 -port $FI_RST_PORT
set_dft_signal -view spec         -type Reset -active_state 0 -port $FI_RST_PORT

set_dft_signal -view existing_dft -type TestMode -active_state 1 -port $FI_TESTMODE_PORT
set_dft_signal -view spec         -type TestMode -active_state 1 -port $FI_TESTMODE_PORT


set_dft_configuration -fix_reset enable
set_dft_configuration -fix_set enable
set_dft_configuration -fix_clock enable

set_dft_configuration -fix_bidirectional enable


create_port $FI_SCAN_IN_PORT
create_port $FI_SCAN_EN_PORT
create_port $FI_SCAN_OUT_PORT -direction out
set_dft_signal -view spec -type ScanDataIn  -port $FI_SCAN_IN_PORT
set_dft_signal -view spec -type ScanDataOut -port $FI_SCAN_OUT_PORT
set_dft_signal -view spec -type ScanEnable  -port $FI_SCAN_EN_PORT -active_state 1

# One chain, no lockup latches: the FI executor rotates a single chain
# through the wrapper and counts exactly L shift edges.
set_scan_configuration -chain_count 1

set_dft_drc_configuration -allow_se_set_reset_fix true

create_test_protocol


# Run scan chain insertion
insert_dft

# ============================================================
# FI wrapper: prove the chain is actually injectable.
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

# Capture scan path and clock gating issues before running final DFT rule check
report_scan_path    > ${FI_REPORTS_DIR}/scan_path_debug.log
report_clock_gating > ${FI_REPORTS_DIR}/clock_gating_debug.log
report_dft_signal   > ${FI_REPORTS_DIR}/dft_signal_debug.log

# Run initial DFT rule check and attempt auto-fix
# dft_drc -fix
dft_drc
dft_drc -verbose > ${FI_REPORTS_DIR}/${FI_RPT_DRC_CONFIGURED}


write -format ddc -hierarchy -output ${FI_RESULTS_DIR}/postdft.ddc

optimize_netlist -area -no_seq_output_inversion
change_names -rules verilog -hierarchy
set_svf -off

write_scan_def -output ${FI_RESULTS_DIR}/${FI_OUT_SCANDEF}
check_scan_def > ${FI_REPORTS_DIR}/${FI_RPT_CHECK_SCANDEF}
write_test_model -format ctl -output ${FI_RESULTS_DIR}/${FI_OUT_CTL}

report_dft_signal > ${FI_REPORTS_DIR}/${FI_RPT_DFT_SIGNALS}

write_test_protocol -output ${FI_RESULTS_DIR}/${FI_OUT_SPF}

# THE report the FI_Index -> flop map is parsed from. Everything else in
# this block is conventional DFT output; this one is load-bearing.
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
    fi__msg ERROR "no netlist at ${FI_RESULTS_DIR}/${FI_OUT_NETLIST} --\
                   the write failed. Nothing downstream can use this run."
}

# ============================================================
# FI wrapper: export the FI_Index <-> flop map, then print the verdict.
#
# AFTER change_names -rules verilog, so the names written here are the
# ones you will see in the netlist and in the waveform viewer -- and
# last in the file, so the PASS/FAIL banner is the final thing on screen
# rather than being buried under DFT DRC output.
# ============================================================
fi_export_scanmap
fi_report

