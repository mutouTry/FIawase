# SPDX-License-Identifier: Apache-2.0
# Copyright 2025-2026 the FIawase authors
# Shared helpers, the optional settings and their defaults, fi_init_flow_vars.
# Sourced by syn/fi_scan_lib.tcl.

# Run one FIawase step from a flow script; a Tcl error in it ends the run
# (dc_shell's source carries on past an error, with the step half done).
proc fi_step {args} {
    if {[catch {uplevel #0 $args} e]} {
        puts "FI-ERROR: $args: $e"
        exit 2
    }
}
proc fi__msg {lvl txt} { puts "FI-$lvl: $txt" }
proc fi__die {txt}     { error "FI-ERROR: $txt" }

# Optional settings of fi_scan_cfg.tcl and their defaults (FI_GATE_SRC's is in
# fi_scan_lib.tcl, which knows where it is). An environment variable of the
# same name wins for FI_SURVEY (make dc SURVEY=only).
foreach {fi__v fi__d} {
    FI_GATE_CLOCK       0
    FI_SURVEY           0
    FI_TESTMODE_PIN     ""
    FI_TESTMODE_CREATE  0
    FI_RESET_ACK        {}
    FI_TIE_PINS         {}
    FI_BLACKBOX_MODULES {}
    FI_FREEZE           {}
    FI_GATE_PINS        {}
    FI_EXEMPT           {}
    FI_EXEMPT_CLOCKS    {}
    FI_RESULTS_DIR      ""
    FI_REPORTS_DIR      ""
    FI_TOP              ""
    FI_GATE_MODULE      fi_clk_gate
    FI_FREEZE_MODULE    fi_clk_freeze
    FI_GATE_INST        u_fi_clk_gate
    FI_GATE_NET         fi_clk_gated
    FI_FREEZE_NET       fi_freeze
    FI_LATCH_HOLD       1
    FI_CLEAR            1
    FI_SLOW_CLOCKS      {}
    FI_CLEAR_MODULE     fi_clear
    FI_CLEAR_INST       u_fi_clear
    FI_HOLD_MODULE      fi_latch_hold
    FI_HOLD_PORT        fi_latch_hold_tmp
    FI_CHAIN_HEAD_NORESET 1
    FI_CHAIN_NAME       fi_chain
} {
    if {![info exists $fi__v]} { set $fi__v $fi__d }
}
if {[info exists ::env(FI_SURVEY)] && $::env(FI_SURVEY) ne ""} { set FI_SURVEY $::env(FI_SURVEY) }
unset fi__v fi__d

# 1 if $name is one of $prefixes or lives under one. Compared literally:
# instance paths contain glob characters (a generate block's gen_lane[3]), and
# A2, A3 and FI_EXEMPT depend on this match.
proc fi__under {name prefixes} {
    foreach p $prefixes {
        if {$name eq $p} { return 1 }
        set n [string length $p]
        if {[string equal -length $n $p $name] &&
            [string index $name $n] eq "/"} { return 1 }
    }
    return 0
}

# Summarise a list of flop paths as "<instance> xN", so a failure tells
# you which blocks to act on instead of six random leaf names.
proc fi__group {names {depth 3} {top 8}} {
    array set c {}
    foreach n $names {
        set parts [split $n "/"]
        if {[llength $parts] > $depth} { set parts [lrange $parts 0 [expr {$depth-1}]] } \
        else                           { set parts [lrange $parts 0 end-1] }
        set k [join $parts "/"]
        if {$k eq ""} { set k "<top level>" }
        if {[info exists c($k)]} { incr c($k) } else { set c($k) 1 }
    }
    set rows {}
    foreach k [lsort [array names c]] { lappend rows [list $c($k) $k] }
    set rows [lsort -integer -decreasing -index 0 $rows]
    set out {}
    set shown 0
    foreach r $rows {
        if {$shown >= $top} {
            lappend out "... and [expr {[llength $rows]-$top}] more group(s)"
            break
        }
        lappend out "[lindex $r 1] x[lindex $r 0]"
        incr shown
    }
    return "By instance: [join $out {; }]"
}

proc fi__clog2 {n} {
    set r 0
    set v 1
    while {$v < $n} { set v [expr {$v * 2}] ; incr r }
    return $r
}

# Resolve one output-path variable. Precedence, highest first:
#   1. the user already set FI_<name> in fi_scan_cfg.tcl
#   2. the equivalent Synopsys DC RM variable exists in this shell
#   3. the built-in default, which is what the RM would have produced
proc fi__resolve {ourVar rmVar fallback} {
    upvar #0 $ourVar our
    if {[info exists our] && [string trim $our] ne ""} { return "cfg" }
    if {[uplevel #0 [list info exists $rmVar]]} {
        set our [uplevel #0 [list set $rmVar]]
        return "rm"
    }
    set our $fallback
    return "default"
}

# ============================================================
# fi_init_flow_vars -- where the artefacts go. Call it first: it defines every
# FI_* output path the other steps use. The design name is FI_TOP, else the
# RM's DESIGN_NAME, else $env(TOP), else the current design.
# ============================================================
proc fi_init_flow_vars {} {
    global FI_TOP FI_RESULTS_DIR FI_REPORTS_DIR
    global FI_OUT_NETLIST FI_OUT_SDC FI_OUT_SDF FI_OUT_SCANDEF
    global FI_OUT_CTL FI_OUT_SPF
    global FI_RPT_DRC_CONFIGURED FI_RPT_DRC_FINAL FI_RPT_SCAN_PATH
    global FI_RPT_CHECK_SCANDEF FI_RPT_DFT_SIGNALS

    if {![info exists FI_TOP] || [string trim $FI_TOP] eq ""} {
        if {[uplevel #0 {info exists DESIGN_NAME}]} {
            set FI_TOP [uplevel #0 {set DESIGN_NAME}]
        } elseif {[info exists ::env(TOP)]} {
            set FI_TOP $::env(TOP)
        } else {
            set FI_TOP [get_object_name [current_design]]
        }
    }
    set d $FI_TOP

    set src_res [fi__resolve FI_RESULTS_DIR RESULTS_DIR ./results]
    set src_rpt [fi__resolve FI_REPORTS_DIR REPORTS_DIR ./reports]

    fi__resolve FI_OUT_NETLIST       DCRM_FINAL_VERILOG_OUTPUT_FILE         ${d}.mapped.v
    fi__resolve FI_OUT_SDC           DCRM_FINAL_SDC_OUTPUT_FILE             ${d}.mapped.sdc
    fi__resolve FI_OUT_SDF           DCRM_DCT_FINAL_SDF_OUTPUT_FILE         ${d}.mapped.sdf
    fi__resolve FI_OUT_SCANDEF       DCRM_DFT_FINAL_SCANDEF_OUTPUT_FILE     ${d}.mapped.scandef
    fi__resolve FI_OUT_CTL           DCRM_DFT_FINAL_CTL_OUTPUT_FILE         ${d}.mapped.ctl
    fi__resolve FI_OUT_SPF           DCRM_DFT_FINAL_PROTOCOL_OUTPUT_FILE    ${d}.mapped.scan.spf
    fi__resolve FI_RPT_DRC_CONFIGURED DCRM_DFT_DRC_CONFIGURED_VERBOSE_REPORT ${d}.dft_drc_configured.rpt
    fi__resolve FI_RPT_DRC_FINAL     DCRM_DFT_DRC_FINAL_REPORT              ${d}.mapped.dft_drc_inserted.rpt
    fi__resolve FI_RPT_SCAN_PATH     DCRM_DFT_FINAL_SCAN_PATH_REPORT        ${d}.mapped.scanpath.rpt
    fi__resolve FI_RPT_CHECK_SCANDEF DCRM_DFT_FINAL_CHECK_SCAN_DEF_REPORT   ${d}.mapped.check_scan_def.rpt
    fi__resolve FI_RPT_DFT_SIGNALS   DCRM_DFT_FINAL_DFT_SIGNALS_REPORT      ${d}.mapped.dft_signals.rpt

    # The RM creates these in dc_setup.tcl; without it, nobody has.
    foreach d [list $FI_RESULTS_DIR $FI_REPORTS_DIR] {
        if {[catch {file mkdir $d} e]} {
            fi__die "cannot create output directory '$d': $e.\
                     Set FI_RESULTS_DIR / FI_REPORTS_DIR in fi_scan_cfg.tcl\
                     to somewhere writable."
        }
    }

    # The files a run hands on are written only when its checks pass, so one
    # left by an earlier run would pass for this run's: remove them now. Only
    # files this flow wrote (the GENERATED header, or the scan map's).
    foreach f {fi_scan_cfg.vh fi_scan_cfg.tcl fi_scanmap.txt fi_clock_gates.txt} {
        set fp [file join $FI_RESULTS_DIR $f]
        if {![file exists $fp]} { continue }
        set fh [open $fp r]; set head [read $fh 400]; close $fh
        if {[string first "GENERATED by syn/fi_scan_lib.tcl" $head] >= 0 || [string match "# FI_Index*" $head]} {
            file delete $fp
        }
    }

    array set how {cfg "from your config" rm "inherited from the DC RM" default "default"}
    fi__msg INFO "design $FI_TOP"
    fi__msg INFO "  results -> $FI_RESULTS_DIR ($how($src_res))"
    fi__msg INFO "  reports -> $FI_REPORTS_DIR ($how($src_rpt))"
}

# The net attached to a top-level port, creating one if the port floats.
proc fi__port_net {port} {
    set n [get_nets -quiet -of_objects [get_ports $port]]
    if {[sizeof_collection $n] == 0} {
        create_net ${port}_fi_n
        connect_net [get_nets ${port}_fi_n] [get_ports $port]
        set n [get_nets ${port}_fi_n]
        fi__msg WARN "port $port had no net; created ${port}_fi_n"
    }
    return $n
}

# The design that contains the cell at a hierarchical path (the current
# design for a top-level cell).
proc fi__parent_design {cellpath} {
    set p [file dirname $cellpath]
    if {$p eq "."} { return [get_object_name [current_design]] }
    return [get_attribute [get_cells $p] ref_name]
}

# The leaf output pins and ports that drive the electrical net of a pin,
# through any number of hierarchy levels.
proc fi__drivers {pin} {
    set segs [get_nets -quiet -segments -of_objects $pin]
    set d [get_pins -quiet -leaf -of_objects $segs -filter "pin_direction == out"]
    set p [get_ports -quiet -of_objects $segs -filter "port_direction == in"]
    return [list $d $p]
}

# The pins of a register whose library pin carries an attribute (is_clock_pin,
# is_async_pin, clock_gate_test_pin, ...), or has it at a given value
# (signal_type test_scan_in, ...).
proc fi__lib_attr_pins {cell attr} { return [fi__lib_attr_pins_eq $cell $attr true] }
proc fi__lib_attr_pins_eq {cell attr val} {
    set lc  [get_lib_cells -quiet -of_objects $cell]
    set out {}
    if {![sizeof_collection $lc]} { return [get_pins -quiet {}] }
    set lcn [get_object_name $lc]
    foreach_in_collection p [get_pins -quiet -of_objects $cell] {
        set lp [get_lib_pins -quiet $lcn/[file tail [get_object_name $p]]]
        if {[get_attribute -quiet $lp $attr] eq $val} { lappend out [get_object_name $p] }
    }
    return [get_pins -quiet $out]
}
proc fi__clock_pins_of {cell} { return [fi__lib_attr_pins $cell is_clock_pin] }
proc fi__async_pins_of {cell} { return [fi__lib_attr_pins $cell is_async_pin] }

# A name for the electrical net of a pin: its driver pins and ports.
proc fi__net_key {pin} {
    lassign [fi__drivers $pin] d pt
    return [concat [get_object_name $d] [get_object_name $pt]]
}

# The latches that gate a clock: a cell the latch drives has another input
# on the latch's own enable net (latch + AND, the inside of an ICG written in
# RTL). They hold no state across a cycle -- the enable is sampled again in
# every low phase -- so they are neither shifted nor frozen, and that is fine.
proc fi__gate_latches {} {
    set out {}
    foreach_in_collection l [all_registers -level_sensitive] {
        set en_key {}
        foreach_in_collection ep [fi__clock_pins_of $l] { set en_key [fi__net_key $ep] }
        if {![llength $en_key]} { continue }
        set gates 0
        foreach_in_collection q [get_pins -quiet -of_objects $l -filter "pin_direction == out"] {
            foreach_in_collection ld [get_pins -quiet -leaf -of_objects [get_nets -quiet -segments -of_objects $q] -filter "pin_direction == in"] {
                foreach_in_collection ip [get_pins -quiet -of_objects [get_cells -of_objects $ld] -filter "pin_direction == in"] {
                    if {[get_object_name $ip] ne [get_object_name $ld] && [fi__net_key $ip] eq $en_key} { set gates 1 }
                }
            }
        }
        if {$gates} { lappend out [get_object_name $l] }
    }
    return $out
}

# The clock path of a register clock pin, walked back from the pin to its
# root. Returns {root steps}; root is the port the walk ends on ("" if it
# ends anywhere else) and each step, in order from the pin, is one of
#   {buf  <cell>}                  one input: buffer, inverter
#   {icg  <cell> <E> <TE>}         a library clock-gating cell
#   {lgate <cell> <latch>}         latch + AND: a clock gate written in RTL
#   {fi   <inst>}                  the FI freeze gate or a freeze cell
#   {other <cell>}                 anything else (a mux, a divider)
# A latch gates the clock when the cell it drives has another input on the
# latch's own enable net. latches is an array of latch cell names.
proc fi__clock_path {pin latches_name} {
    upvar $latches_name latches
    global FI_GATE_INST
    set steps {}
    set p $pin
    for {set guard 0} {$guard < 64} {incr guard} {
        lassign [fi__drivers $p] d pt
        if {[sizeof_collection $d] == 0} {
            return [list [get_object_name $pt] $steps]
        }
        if {[sizeof_collection $d] > 1} {
            lappend steps [list other [get_object_name $d]]
            return [list "" $steps]
        }
        set c  [get_cells -of_objects $d]
        set cn [get_object_name $c]
        if {[regexp "^(.*/)?(${FI_GATE_INST}|u_fi_clk_freeze_\[0-9\]+)/" $cn m pre inst]} {
            set fi_inst "$pre$inst"
            lappend steps [list fi $fi_inst]
            set p [get_pins $fi_inst/clk_i]
            continue
        }
        set lc [get_lib_cells -quiet -of_objects $c]
        if {[sizeof_collection $lc] && [get_attribute -quiet $lc clock_gating_integrated_cell] ne ""} {
            lappend steps [list icg $cn \
                [get_object_name [fi__lib_attr_pins $c clock_gate_enable_pin]] \
                [get_object_name [fi__lib_attr_pins $c clock_gate_test_pin]]]
            set p [fi__lib_attr_pins $c clock_gate_clock_pin]
            continue
        }
        set ins [get_pins -quiet -of_objects $c -filter "pin_direction == in"]
        if {[sizeof_collection $ins] == 1} {
            lappend steps [list buf $cn]
            set p $ins
            continue
        }
        set in_names [get_object_name $ins]
        set clk_in ""
        set lat ""
        foreach i $in_names {
            lassign [fi__drivers [get_pins $i]] di dpi
            if {[sizeof_collection $di] != 1} { continue }
            set dc [get_object_name [get_cells -of_objects $di]]
            if {![info exists latches($dc)]} { continue }
            set en_key {}
            foreach_in_collection ep [fi__clock_pins_of [get_cells $dc]] { set en_key [fi__net_key $ep] }
            foreach j $in_names {
                if {$j ne $i && [fi__net_key [get_pins $j]] eq $en_key} { set clk_in $j ; set lat $dc }
            }
        }
        if {$clk_in ne ""} {
            lappend steps [list lgate $cn $lat]
            set p [get_pins $clk_in]
            continue
        }
        lappend steps [list other $cn]
        return [list "" $steps]
    }
    lappend steps [list other too-deep]
    return [list "" $steps]
}

# The shift condition: Scan_En and testmode at 1, as all through a scan pass
# (testmode follows Scan_En). Set as case analysis on the two ports; a value
# either port already had is put back by fi__shift_case_end. Case values are
# only readable after update_timing.
proc fi__shift_case_begin {} {
    global FI_SCAN_EN_PORT FI_TESTMODE_PORT
    update_timing
    set saved {}
    foreach pn [lsort -unique [list $FI_SCAN_EN_PORT $FI_TESTMODE_PORT]] {
        set p [get_ports -quiet $pn]
        if {![sizeof_collection $p]} { continue }
        lappend saved $pn [get_attribute -quiet $p case_value]
        set_case_analysis 1 $p
    }
    update_timing
    return $saved
}
proc fi__shift_case_end {saved} {
    foreach {pn v} $saved {
        remove_case_analysis [get_ports $pn]
        if {$v ne ""} { set_case_analysis $v [get_ports $pn] }
    }
}

# The inputs of a clock gate other than its clock: E and TE of a library ICG;
# the data input of the latch of a latch gate (RTL), where both the enable and
# the test term enter. test_only: the test input alone (TE; for a latch gate
# still the latch's data input).
proc fi__gate_inputs {step test_only} {
    switch -- [lindex $step 0] {
        icg {
            if {$test_only} { return [get_pins -quiet [lindex $step 3]] }
            return [get_pins -quiet [concat [lindex $step 2] [lindex $step 3]]]
        }
        lgate {
            set l [get_cells [lindex $step 2]]
            set lcn [get_object_name [get_lib_cells -of_objects $l]]
            set pins {}
            foreach_in_collection p [get_pins -quiet -of_objects $l -filter "pin_direction == in"] {
                if {[get_attribute -quiet [get_lib_pins -quiet $lcn/[file tail [get_object_name $p]]] is_clock_pin] ne "true"} {
                    lappend pins [get_object_name $p]
                }
            }
            return [get_pins -quiet $pins]
        }
    }
    return {}
}

# Does the shift open the gate on every edge? Under the shift condition
# (fi__shift_case_begin) its test input is the constant 1. Sufficient, unlike
# "Scan_En is in its fan-in": TE = Scan_En & x passes that and stays shut.
proc fi__shift_opens {step} {
    set pins [fi__gate_inputs $step 1]
    if {![sizeof_collection $pins]} { return 0 }
    foreach_in_collection p $pins {
        if {[get_attribute -quiet $p case_value] ne "1"} { return 0 }
    }
    return 1
}

# Can the shift change what the gate passes? Scan_En or testmode is in the
# fan-in of one of its inputs other than the clock. A constant is not: a gate
# tied open passes every edge in and out of the window alike.
proc fi__shift_reaches {step} {
    global FI_SCAN_EN_PORT FI_TESTMODE_PORT
    set pins [fi__gate_inputs $step 0]
    if {![sizeof_collection $pins]} { return 0 }
    foreach s [get_object_name [all_fanin -to $pins -flat -startpoints_only]] {
        set t [file tail $s]
        if {$t eq $FI_SCAN_EN_PORT || $t eq $FI_TESTMODE_PORT} { return 1 }
    }
    return 0
}

# Instances of the FI_BLACKBOX_MODULES designs (and of their uniquified
# copies). Works on a design read back from a .ddc too.
proc fi__blackbox_insts {} {
    global FI_BLACKBOX_MODULES
    set top [get_object_name [current_design]]
    set out {}
    foreach m $FI_BLACKBOX_MODULES {
        foreach dn [get_object_name [get_designs -quiet [list $m ${top}_${m}_*]]] {
            foreach n [get_object_name [get_cells -quiet -hierarchical -filter "ref_name == $dn"]] {
                lappend out $n
            }
        }
    }
    return [lsort -unique $out]
}

# The black-box output pins recorded by fi_pre_compile that no longer drive
# any leaf input pin.
proc fi__blackbox_cut_outputs {} {
    global FI_BLACKBOX_LOADED_OUTS
    set out {}
    foreach p $FI_BLACKBOX_LOADED_OUTS {
        set pin [get_pins -quiet $p]
        if {![sizeof_collection $pin] || ![sizeof_collection [get_pins -quiet -leaf -of_objects \
                [get_nets -quiet -segments -of_objects $pin] -filter "pin_direction == in"]]} {
            lappend out $p
        }
    }
    return $out
}

# The latch-hold cells in the design (from fi_pre_compile, or found again
# by name in a design read back from a .ddc).
proc fi__hold_cells {} {
    global FI_HOLD_CELLS
    if {[info exists FI_HOLD_CELLS] && [llength $FI_HOLD_CELLS]} { return $FI_HOLD_CELLS }
    return [get_object_name [get_cells -quiet -hierarchical u_fi_latch_hold_*]]
}

# The registers of each FI_EXEMPT_CLOCKS clock, as {clock collection ...}.
# A name the SDC does not define ends the run: a typo would otherwise file a
# whole clock domain as frozen or as orphans, and the checks that skip
# exempt clocks would skip nothing.
proc fi__exempt_clock_regs {} {
    global FI_EXEMPT_CLOCKS
    set out {}
    foreach ec $FI_EXEMPT_CLOCKS {
        set cc [get_clocks -quiet $ec]
        if {![sizeof_collection $cc]} { fi__die "FI_EXEMPT_CLOCKS: no clock named '$ec' (see report_clocks)" }
        # no -quiet: all_registers has no such option, and with it the
        # command fails with an empty message
        if {[catch {set xr [all_registers -clock $cc]} e]} { fi__die "all_registers -clock $ec failed: $e" }
        lappend out $ec $xr
    }
    return $out
}
