# SPDX-License-Identifier: Apache-2.0
# Copyright 2025-2026 the FIawase authors
# ============================================================
# fi_scan_lib.tcl -- DUT-independent half of the FI synthesis flow
# ------------------------------------------------------------
# Six entry points, called from scanchain.tcl:
#
#   fi_init_flow_vars        first                 -- resolve output paths
#   fi_insert_clock_gate     before compile_ultra  -- splice the gate in
#   fi_apply_scan_exclusion  before compile_ultra  -- keep them off the chain
#   fi_check_invariants      after  insert_dft     -- prove it worked
#   fi_export_scanmap        after  change_names   -- emit FI_Index<->FF map
#   fi_report                last                  -- human summary
#
# Everything DUT specific lives in fi_scan_cfg.tcl.
#
# NO DEPENDENCY ON THE SYNOPSYS DC REFERENCE METHODOLOGY
# ------------------------------------------------------
# This flow used to read RESULTS_DIR, REPORTS_DIR and eleven DCRM_*
# filename variables straight out of the DC RM setup scripts, which are
# Synopsys-copyrighted and cannot be redistributed. fi_init_flow_vars
# removes that dependency without changing anyone's behaviour: if your
# flow already defines the RM variables it inherits them verbatim, and if
# it does not it falls back to the same filenames the RM would have
# produced. Either way scanchain.tcl only ever refers to FI_* names.
#
# WHY GATING AND SCAN EXCLUSION ARE ONE OPERATION HERE
# ----------------------------------------------------
# A flop that is frozen during the scan window must not be on the
# chain: the chain would receive L shift edges while that flop received
# none, so its content shifts out of step and the chain can no longer
# be restored bit-perfectly. The failure mode is "the DUT dies the
# instant FI is armed", and it is silent at synthesis time. Assertion
# A2 is the whole reason this file exists.
#
# Two DC mechanisms can keep an instance off the chain, and this flow
# deliberately uses the explicit one and then checks the result:
#   * set_scan_element false  -- purpose-built, does not block
#                                optimization. This is what we use.
#   * a clock that is not a declared ScanClock -- also works, and is a
#     side effect of gating, but it is implicit and DFT's
#     -fix_clock enable may try to "repair" it (see A5).
# (set_dont_touch also happens to work, by blocking the scan-flop swap,
#  but it is a blunt instrument that costs QoR and says nothing about
#  intent. The old scanchain.tcl used it; this flow does not.)
# ============================================================

proc fi__msg {lvl txt} { puts "FI-$lvl: $txt" }
proc fi__die {txt}     { error "FI-ERROR: $txt" }

# 1 if $name is $p or lives under $p, for any prefix in $prefixes.
#
# The prefix is compared LITERALLY. `string match` would glob it, and DC
# instance paths routinely contain glob metacharacters: any SystemVerilog
# generate block produces `gen_lane[3].u_core`, where `[3]` is a character
# class that matches the single character `3` -- so `gen_lane[3].u_core/*`
# never matches its own descendants and this returns 0 for every flop in
# the block.
#
# That is not a cosmetic bug. This proc is the sole mechanism behind A2,
# behind the FI_EXEMPT escape hatch, and behind A3's frozen/gate
# classification. A block named with a generate index would be invisible to
# A2 -- a safety-critical assertion silently answering "nothing to check" --
# while A3 reported its flops as orphans and told you to freeze a clock pin
# that is already in FI_GATE_PINS. Listing the block in FI_EXEMPT, the
# documented remedy, would fail to match for the same reason.
#
# `string equal` on a fixed-length prefix does the same job with no pattern
# semantics at all.
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
# fi_init_flow_vars -- where the artefacts go.
# ------------------------------------------------------------
# Call this FIRST, before anything else in scanchain.tcl. It defines
# every FI_* output path the rest of the flow uses, so that the flow
# runs identically whether or not the Synopsys DC Reference Methodology
# is present. See the header of this file for why.
#
# The design name is taken from FI_TOP if you set it, else from the RM's
# DESIGN_NAME, else from $env(TOP), else from the current design.
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

# ============================================================
# 1. fi_insert_clock_gate -- run BEFORE compile_ultra
# ============================================================
proc fi_insert_clock_gate {} {
    global FI_CLK_PORT FI_RST_PORT FI_GATE_PORT FI_GATE_PINS
    global FI_GATE_MODULE FI_GATE_INST FI_GATE_NET FI_GATE_SRC

    if {[llength $FI_GATE_PINS] == 0} {
        fi__die "FI_GATE_PINS is empty -- nothing would ever be frozen"
    }
    set top [lindex [get_object_name [current_design]] 0]

    # -- top-level control ports --------------------------------
    foreach p [list $FI_CLK_PORT $FI_RST_PORT] {
        if {[sizeof_collection [get_ports -quiet $p]] == 0} {
            fi__die "port '$p' not found on $top (fix fi_scan_cfg.tcl)"
        }
    }
    if {[sizeof_collection [get_ports -quiet $FI_GATE_PORT]] == 0} {
        create_port $FI_GATE_PORT -direction in
        fi__msg WARN "created top port '$FI_GATE_PORT' -- the DUT did not\
                      expose one. Remember to drive it from the FI wrapper."
    }

    # -- compile the portable gate module, then freeze it --------
    # Compiled standalone so set_dont_touch can protect its structure
    # from the top-level compile_ultra and from insert_dft.
    if {[sizeof_collection [get_designs -quiet $FI_GATE_MODULE]] == 0} {
        analyze -format verilog $FI_GATE_SRC
        elaborate $FI_GATE_MODULE
        current_design $FI_GATE_MODULE
        compile_ultra
        set_dont_touch [get_designs $FI_GATE_MODULE]
        current_design $top
        link
    }

    # -- instantiate and wire ------------------------------------
    if {[sizeof_collection [get_cells -quiet $FI_GATE_INST]] == 0} {
        create_cell $FI_GATE_INST $FI_GATE_MODULE
        link
    }
    if {[sizeof_collection [get_pins -quiet $FI_GATE_INST/clk_o]] == 0} {
        fi__die "$FI_GATE_INST has no clk_o pin -- $FI_GATE_MODULE did not\
                 link. Check that analyze/elaborate of $FI_GATE_SRC succeeded."
    }
    if {[sizeof_collection [get_nets -quiet $FI_GATE_NET]] == 0} {
        create_net $FI_GATE_NET
    }
    connect_net [fi__port_net $FI_CLK_PORT]  [get_pins $FI_GATE_INST/clk_i]
    connect_net [fi__port_net $FI_RST_PORT]  [get_pins $FI_GATE_INST/rst_ni]
    connect_net [fi__port_net $FI_GATE_PORT] [get_pins $FI_GATE_INST/clk_gate_i]
    connect_net [get_nets $FI_GATE_NET]      [get_pins $FI_GATE_INST/clk_o]

    # -- re-route every clock pin in the source of truth ---------
    set moved 0
    set kept  0
    foreach p $FI_GATE_PINS {
        set pin [get_pins -quiet $p]
        if {[sizeof_collection $pin] == 0} {
            fi__die "FI_GATE_PINS: pin '$p' does not exist in $top"
        }
        set old [get_nets -quiet -of_objects $pin]
        if {[sizeof_collection $old] &&
            [lindex [get_object_name $old] 0] eq $FI_GATE_NET} {
            incr kept
            continue
        }
        if {[sizeof_collection $old]} { disconnect_net $old $pin }
        connect_net [get_nets $FI_GATE_NET] $pin
        incr moved
    }

    # The gate itself must never be scanned: its synchronizer flop is
    # clocked by the ScanClock, so DC would happily stitch it in, and
    # then shifting would drive the freeze signal with scan data.
    set_scan_element false [get_cells $FI_GATE_INST]
    set_dont_touch         [get_cells $FI_GATE_INST]
    set_dont_touch         [get_nets  $FI_GATE_NET]

    fi__msg INFO "clock gate inserted: $FI_GATE_INST -> $FI_GATE_NET,\
                  $moved pin(s) re-routed, $kept already gated"
}

# ============================================================
# 2. fi_apply_scan_exclusion -- run BEFORE compile_ultra
# ============================================================
proc fi_apply_scan_exclusion {} {
    global FI_GATE_PINS FI_EXEMPT FI_GATE_INST

    set insts {}
    foreach p $FI_GATE_PINS { lappend insts [file dirname $p] }
    foreach i $FI_EXEMPT    { lappend insts $i }
    lappend insts $FI_GATE_INST

    set n 0
    foreach i [lsort -unique $insts] {
        set c [get_cells -quiet $i]
        if {[sizeof_collection $c] == 0} {
            fi__msg WARN "scan exclusion: instance '$i' not found, skipped\
                          (optimized away? renamed?)"
            continue
        }
        set_scan_element false $c
        incr n
    }
    fi__msg INFO "set_scan_element false applied to $n instance(s)"
}

# ============================================================
# internal: the chain in shift order, index 0 = first cell after
# scan-in. Parsed from report_scan_path, NOT from the scandef.
#
# The scandef lists chains as FLOATING, i.e. an unordered set that P&R
# is free to reorder, and DC emits it in a different order than the
# built chain. Using it silently produced a wrong FI_Index<->FF map. The
# report's Cell_# column is the order that was actually built, and it
# is the one calibrated against silicon^Wsimulation
# (docs/DEBUG_NOTES.md A.2.2).
# ============================================================
proc fi__scan_order {} {
    global FI_RESULTS_DIR

    set f ${FI_RESULTS_DIR}/fi_scan_path.rpt
    redirect $f { report_scan_path }

    set fh [open $f r]
    set txt [read $fh]
    close $fh

    array set seen {}
    set collecting 0
    foreach line [split $txt "\n"] {
        if {!$collecting} {
            # the per-cell listing is the only section with this header
            if {[string first "Cell_#" $line] >= 0} { set collecting 1 }
            continue
        }
        set l [string trim $line]
        if {$l eq "" || [string index $l 0] eq "-"} { continue }
        # drop the "I 1" chain prefix that only the first row carries
        regsub {^[A-Za-z]+[ \t]+[0-9]+[ \t]+} $l "" l
        if {![regexp {^([0-9]+)[ \t]+([A-Za-z_][A-Za-z0-9_/$\[\].]*)} $l -> idx name]} {
            continue
        }
        if {[info exists seen($idx)]} {
            fi__die "report_scan_path shows more than one scan chain\
                     (Cell_# $idx appears twice). The FI executor shifts a\
                     single chain; re-run with -chain_count 1."
        }
        set seen($idx) $name
    }

    set n [array size seen]
    if {$n == 0} {
        fi__die "could not parse any scan cells out of $f -- report_scan_path\
                 layout differs in this DC version, fix fi__scan_order"
    }
    set order {}
    for {set i 0} {$i < $n} {incr i} {
        if {![info exists seen($i)]} {
            fi__die "scan path Cell_# indices are not contiguous (missing $i of $n)"
        }
        lappend order $seen($i)
    }
    return $order
}

# ============================================================
# 3. fi_check_invariants -- run AFTER insert_dft
# ============================================================
#
# WHY THERE IS NO all_fanout HERE ANY MORE (2026-07-27, first real run)
# --------------------------------------------------------------------
# The first version derived the frozen set with
#     all_fanout -from [get_nets fi_clk_gated] -flat -endpoints_only
# That is the wrong primitive: all_fanout walks TIMING paths, so from a
# clock net it goes through the gated flops, out their Q pins, through
# combinational logic, and lands on the D pins of everything downstream.
# On this SoC it returned 3099 cells including bus/, timers, the core --
# none of which are gated. A2 then "failed" on a set that was pure
# fiction.
#
# Everything safety-critical here is now computed from two things that
# cannot be misread: the scan path report, and instance path strings.
# The one remaining query, all_registers -clock, is only used to pull
# declared foreign clock domains out of A3, and failing it only warns.
#
proc fi_check_invariants {} {
    global FI_GATE_PINS FI_EXEMPT FI_EXEMPT_CLOCKS
    global FI_GATE_INST FI_GATE_NET FI_N_FF
    global FI_CLK_PORT FI_RST_PORT FI_GATE_PORT
    global FI_SCAN_LEN FI_CHECK_SUMMARY FI_CHECK_OK

    set FI_CHECK_OK 0
    set fails {}
    set order [fi__scan_order]
    set L     [llength $order]
    array set on_chain {}
    foreach c $order { set on_chain($c) 1 }

    set owners {}
    foreach p $FI_GATE_PINS { lappend owners [file dirname $p] }

    # -- A1: every declared gate pin really sits on the gated net ----
    foreach p $FI_GATE_PINS {
        set net [get_nets -quiet -of_objects [get_pins -quiet $p]]
        if {[sizeof_collection $net] == 0 ||
            [lindex [get_object_name $net] 0] ne $FI_GATE_NET} {
            lappend fails "A1 [declared-gate-pins-are-gated]  $p is not driven by $FI_GATE_NET"
        }
    }

    # -- A2: nothing is both frozen and shifted ----------------------
    # SAFETY-CRITICAL, so pure string work: no traversal, no clock
    # query, nothing that can behave differently in another DC version.
    # Conservative on purpose -- it flags the WHOLE of a gated owner.
    # FI_EXEMPT is the documented escape hatch for an instance with two
    # clocks where only one is frozen and the other legitimately stays
    # on the chain; listing it there means you take responsibility.
    set both {}
    foreach c $order {
        if {[fi__under $c $owners] && ![fi__under $c $FI_EXEMPT]} { lappend both $c }
    }
    if {[llength $both]} {
        lappend fails "A2 [nothing-both-frozen-and-shifted]  [llength $both] cell(s) are BOTH under a frozen\
                       instance and on the scan chain -- the chain cannot be\
                       restored bit-perfect. [fi__group $both]"
    }

    # -- classify every register, for A3 -----------------------------
    # Priority: chain > exempt clock > exempt instance > frozen > tool.
    # Exempt clock comes before the hierarchy rules on purpose: a
    # foreign domain (JTAG TCK) usually lives INSIDE a frozen instance,
    # so hierarchy would swallow it.
    array set on_xclk {}
    foreach ec $FI_EXEMPT_CLOCKS {
        set cc [get_clocks -quiet $ec]
        if {[sizeof_collection $cc] == 0} {
            fi__msg WARN "FI_EXEMPT_CLOCKS: no clock named '$ec' (see report_clocks)"
            continue
        }
        # no -quiet here: all_registers does not have that option, and
        # passing it makes the whole command fail silently-ish (the 1629
        # run reported "all_registers -clock jtag_TCK failed:" with an
        # empty message and then mis-filed 200 TCK flops as frozen).
        if {[catch {set xr [all_registers -clock $cc]} e]} {
            fi__msg WARN "all_registers -clock $ec failed: $e"
            continue
        }
        foreach_in_collection r $xr { set on_xclk([lindex [get_object_name $r] 0]) 1 }
    }

    set n_chain 0; set n_xclk 0; set n_exempt 0; set n_frozen 0; set n_tool 0
    set orphans {}
    foreach_in_collection r [all_registers] {
        set n [lindex [get_object_name $r] 0]
        if {[info exists on_chain($n)]}          { incr n_chain  ; continue }
        if {[info exists on_xclk($n)]}           { incr n_xclk   ; continue }
        if {[fi__under $n $FI_EXEMPT]}           { incr n_exempt ; continue }
        if {[fi__under $n $owners]}              { incr n_frozen ; continue }
        if {[fi__under $n [list $FI_GATE_INST]]} { incr n_tool   ; continue }
        lappend orphans $n
    }

    # -- A3: nothing unaccounted for ---------------------------------
    if {[llength $orphans]} {
        lappend fails "A3 [every-flop-accounted-for]  [llength $orphans] register(s) are neither shifted\
                       nor frozen nor exempt: they keep running during the scan\
                       window and cannot be restored. Per group below decide:\
                       add its clock pin to FI_GATE_PINS, its instance to\
                       FI_EXEMPT, or -- if it is a whole foreign clock domain\
                       that is idle during the window -- its clock to\
                       FI_EXEMPT_CLOCKS. [fi__group $orphans]"
    }

    # -- A4: the chain still fits the FI_Entry encoding --------------
    set w_idx [fi__clog2 $FI_N_FF]
    if {$L > $FI_N_FF - 1} {
        lappend fails "A4 [chain-fits-the-table-encoding]  L=$L exceeds FI_N_FF-1=[expr {$FI_N_FF-1}].\
                       Raise FI_N_FF here AND in\
                       rtl/fi/fi_scan_cfg.vh AND FI_W_IDX in\
                       host/tapename.tcl -- all three or none."
    }

    # -- A5: DFT did not rewire the gated clock ----------------------
    # -fix_clock enable exists to make uncontrollable clocks shiftable,
    # which is exactly what our gated branch is. If DC "repairs" it by
    # forcing the clock through during shift, the freeze silently stops
    # working. Checked by membership on the gated net: it must carry
    # exactly the gate output and the declared loads, nothing else.
    #
    # There used to be a fourth check here -- "the gate's three inputs
    # still come straight off the three top ports". Dropped: DC buffers
    # port nets as a matter of course (BUFFD1 U23 on clk_gate in the
    # 1629 run), so it fired on a perfectly healthy netlist. The gate
    # instance is set_dont_touch'd, so a hijack would have to show up on
    # the gated net anyway, which is what the checks below cover.
    set drv {}
    set ld  {}
    foreach_in_collection pn [get_pins -quiet -of_objects [get_nets $FI_GATE_NET]] {
        set n [lindex [get_object_name $pn] 0]
        if {[get_attribute -quiet $pn direction] eq "out"} { lappend drv $n } \
        else                                               { lappend ld  $n }
    }
    if {[lsort $drv] ne [list $FI_GATE_INST/clk_o]} {
        lappend fails "A5 [gate-not-rewired-by-dft]  $FI_GATE_NET drivers are {$drv}, expected only\
                       $FI_GATE_INST/clk_o. Something re-drove the gated clock\
                       -- most likely -fix_clock. Try\
                       'set_dft_configuration -fix_clock disable'."
    }
    foreach l $ld {
        if {[lsearch -exact $FI_GATE_PINS $l] < 0} {
            lappend fails "A5 [gate-not-rewired-by-dft]  $FI_GATE_NET also feeds '$l', which is not in\
                           FI_GATE_PINS. Either add it there or find out who\
                           connected it."
        }
    }

    # -- verdict --------------------------------------------------
    set FI_SCAN_LEN $L
    set FI_CHECK_SUMMARY [list L $L chain $n_chain frozen $n_frozen \
                               exempt_clk $n_xclk exempt_inst $n_exempt \
                               gate $n_tool orphans [llength $orphans] w_idx $w_idx]
    fi__msg INFO "register partition: $FI_CHECK_SUMMARY"

    if {[llength $fails]} {
        foreach f $fails { fi__msg FAIL $f }
        # NOTE: dc_shell's `source` does NOT stop on a Tcl error -- the
        # rest of scanchain.tcl runs anyway. FI_CHECK_OK is what stops
        # fi_export_scanmap from emitting a config the sim/host would
        # silently use. The error below is for the log and for batch
        # runs with sh_continue_on_error false.
        fi__die "[llength $fails] scan invariant(s) violated -- see FI-FAIL above"
    }
    set FI_CHECK_OK 1
    fi__msg INFO "invariants OK: L=$L, $n_frozen flop(s) frozen, W_IDX=$w_idx"
}

# ============================================================
# 4. fi_export_scanmap -- run AFTER change_names
# ============================================================
# Must be after change_names -rules verilog, so the names written here
# are the ones that appear in the netlist you will simulate.
proc fi_export_scanmap {} {
    global FI_RESULTS_DIR FI_N_FF FI_SCAN_LEN FI_CHECK_OK

    set ok [expr {[info exists FI_CHECK_OK] && $FI_CHECK_OK}]

    set order [fi__scan_order]
    set L     [llength $order]
    if {[info exists FI_SCAN_LEN] && $FI_SCAN_LEN ne "" && $FI_SCAN_LEN != $L} {
        fi__msg WARN "chain length changed from $FI_SCAN_LEN (at insert_dft)\
                      to $L (after optimize_netlist/change_names). The\
                      invariants were checked on the earlier one -- re-run\
                      fi_check_invariants if this is not just a rename."
    }
    set FI_SCAN_LEN $L
    set w_idx [fi__clog2 $FI_N_FF]

    # (a) FI_Index -> flop, for picking targets and for reading waveforms.
    # Written even on a failed check -- it is a diagnostic, and you need
    # it to work out which block a stray flop belongs to.
    set f [open ${FI_RESULTS_DIR}/fi_scanmap.txt w]
    puts $f "# FI_Index\tcell"
    puts $f "# FI_Index is what you write into an FI_Entry. FI_Index 0 is the first"
    puts $f "# cell after scan-in; the executor flips FF\[FI_Index\] by inverting"
    puts $f "# scan_out at shift step L-1-FI_Index."
    puts $f "# L = $L"
    if {!$ok} {
        puts $f "# *** fi_check_invariants FAILED -- this chain is NOT safe to"
        puts $f "# *** inject into. Diagnostic use only."
    }
    set i 0
    foreach c $order { puts $f "$i\t$c" ; incr i }
    close $f

    # (b)+(c) the two files the sim and the host actually consume.
    # Deliberately NOT written when the invariants failed: dc_shell's
    # `source` keeps going after a Tcl error, so without this guard a
    # failed run would still hand you a config that looks usable and
    # kills the DUT on the first injection.
    if {!$ok} {
        fi__msg WARN "invariants failed -> NOT writing fi_scan_cfg.vh /\
                      fi_scan_cfg.tcl. Fix fi_scan_cfg.tcl and re-run;\
                      only fi_scanmap.txt was written, for diagnosis."
        return
    }

    # (b) RTL side -- copy over rtl/fi/fi_scan_cfg.vh
    set f [open ${FI_RESULTS_DIR}/fi_scan_cfg.vh w]
    puts $f "\`ifndef FI_SCAN_CFG_VH"
    puts $f "\`define FI_SCAN_CFG_VH"
    puts $f ""
    puts $f "// GENERATED by syn/fi_scan_lib.tcl -- do not edit."
    puts $f "// FI_N_FF     encoding bound; only clog2() of it is used, so"
    puts $f "//             the FI_Entry field split does not move when L"
    puts $f "//             drifts across re-synthesis. Contract: L <= FI_N_FF-1."
    puts $f "// FI_SCAN_LEN measured chain length; informational, the"
    puts $f "//             executor uses the runtime CFG_SCAN_LEN (DMI 0x63)."
    puts $f ""
    puts $f "\`define FI_N_FF        $FI_N_FF   // -> W_IDX = $w_idx"
    puts $f "\`define FI_SCAN_LEN    $L"
    puts $f ""
    puts $f "\`endif"
    close $f

    # (c) host side -- source it from inject_and_run_dmi.tcl instead of
    #     hard-coding CFG_SCAN_LEN
    set f [open ${FI_RESULTS_DIR}/fi_scan_cfg.tcl w]
    puts $f "# GENERATED by syn/fi_scan_lib.tcl -- do not edit."
    puts $f "set FI_SCAN_LEN $L"
    puts $f "set FI_W_IDX    $w_idx"
    close $f

    fi__msg INFO "exported ${FI_RESULTS_DIR}/fi_scanmap.txt (L=$L),\
                  fi_scan_cfg.vh, fi_scan_cfg.tcl"
}

# ============================================================
# 5. fi_report
# ============================================================
proc fi_report {} {
    global FI_RESULTS_DIR FI_GATE_PINS FI_EXEMPT FI_EXEMPT_CLOCKS
    global FI_GATE_NET FI_GATE_INST
    global FI_SCAN_LEN FI_N_FF FI_CHECK_SUMMARY FI_CHECK_OK

    if {![info exists FI_SCAN_LEN]}      { set FI_SCAN_LEN      "(not measured)" }
    if {![info exists FI_CHECK_SUMMARY]} { set FI_CHECK_SUMMARY "(not checked)" }
    set ok [expr {[info exists FI_CHECK_OK] && $FI_CHECK_OK}]

    # The bare token first, on its own line. The banner below is for a human
    # reading the terminal; this line is what `make dc` greps for, and what
    # any CI wrapper should key on. Keep the two spellings in step -- a
    # banner that says PASS while nothing greppable is emitted makes the
    # Makefile report a failed run that actually succeeded.
    puts ""
    puts [expr {$ok ? "FI-PASS: scan invariants hold" \
                    : "FI-FAIL: scan invariants violated"}]
    puts "============================================================"
    if {$ok} {
        puts " FI INVARIANTS: PASS -- this netlist is safe to inject into"
    } else {
        puts " FI INVARIANTS: **FAIL** -- do NOT use this netlist for FI."
        puts " fi_scan_cfg.vh / fi_scan_cfg.tcl were not written."
        puts " Scroll up for the FI-FAIL lines; they say what to change in"
        puts " syn/fi_scan_cfg.tcl. (dc_shell does not stop on a Tcl"
        puts "  error, so everything below this ran anyway.)"
    }
    puts "============================================================"
    puts " FI scan configuration report"
    puts "============================================================"
    puts [format " %-22s %s" "gate instance"   $FI_GATE_INST]
    puts [format " %-22s %s" "gated clock net" $FI_GATE_NET]
    puts [format " %-22s %s" "chain length L"  $FI_SCAN_LEN]
    puts [format " %-22s %s" "FI_N_FF / W_IDX" \
              "$FI_N_FF / [fi__clog2 $FI_N_FF]"]
    puts [format " %-22s %s" "invariants"      $FI_CHECK_SUMMARY]
    puts " frozen clock pins:"
    foreach p $FI_GATE_PINS { puts "   $p" }
    puts " exempt instances:"
    foreach i $FI_EXEMPT        { puts "   $i" }
    puts " exempt clocks:"
    foreach c $FI_EXEMPT_CLOCKS { puts "   $c" }
    puts " artefacts in ${FI_RESULTS_DIR}:"
    puts "   fi_scanmap.txt      FI_Index -> flop"
    if {$ok} {
        puts "   fi_scan_cfg.vh      copy to rtl/fi/"
        puts "   fi_scan_cfg.tcl     FI_SCAN_LEN/FI_W_IDX for host/tapename.tcl"
    } else {
        puts "   fi_scan_cfg.vh      NOT WRITTEN (invariants failed)"
        puts "   fi_scan_cfg.tcl     NOT WRITTEN (invariants failed)"
    }
    puts "   fi_scan_path.rpt    raw report_scan_path"
    puts "============================================================"
    puts ""
    # The gated branch should inherit the master clock through the AND
    # gate automatically. Only if it does NOT show up here is a
    # create_generated_clock warranted -- adding one on top of a clock
    # DC already propagated makes timing worse, not better.
    report_clocks
}
