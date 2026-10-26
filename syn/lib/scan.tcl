# SPDX-License-Identifier: Apache-2.0
# Copyright 2025-2026 the FIawase authors
# The freeze and the chain: fi_insert_clock_gate, fi_apply_scan_exclusion, fi_dft_config.
# Sourced by syn/fi_scan_lib.tcl.

# ============================================================
# fi_insert_clock_gate -- mapped design, before insert_dft
# ============================================================
# Mapped, so that compile's clock gates are there to be found. The frozen
# clock pins: FI_GATE_PINS as given, plus, for each FI_FREEZE instance, every
# input pin that carries a clock of FI_CLK_PORT into it.
proc fi__frozen_pins {} {
    global FI_GATE_PINS FI_FREEZE FI_CLK_PORT
    set out $FI_GATE_PINS
    if {![llength $FI_FREEZE]} { return [lsort -unique $out] }
    array set ck {}
    foreach n [get_object_name [all_registers -clock_pins]] { set ck($n) 1 }
    foreach n [fi__icg_clock_pins] { set ck($n) 1 }
    foreach e $FI_FREEZE {
        if {[sizeof_collection [get_pins -quiet $e]]} { lappend out $e ; continue }
        set c [get_cells -quiet $e]
        if {![sizeof_collection $c]} { fi__die "FI_FREEZE: '$e' is neither a pin nor an instance" }
        set found 0
        foreach_in_collection p [get_pins -quiet -of_objects $c -filter "pin_direction == in"] {
            set inside 0
            foreach ln [get_object_name [get_pins -quiet -leaf -of_objects \
                         [get_nets -quiet -segments -of_objects $p] -filter "pin_direction == in"]] {
                if {[info exists ck($ln)] && [fi__under $ln [list $e]]} { set inside 1 ; break }
            }
            if {!$inside} { continue }
            set roots [get_object_name [get_ports -quiet [all_fanin -to $p -flat -startpoints_only]]]
            if {[lsearch -exact $roots $FI_CLK_PORT] < 0} { continue }
            lappend out [get_object_name $p]
            incr found
        }
        if {!$found} {
            fi__die "FI_FREEZE: instance $e has no input pin carrying $FI_CLK_PORT to a\
                     register inside. A black box needs its clock pin listed instead."
        }
    }
    return [lsort -unique $out]
}

# Clock input pins of the library clock-gating cells in the design.
proc fi__icg_clock_pins {} {
    set out {}
    foreach lc [get_lib_cells -quiet */* -filter "clock_gating_integrated_cell =~ *"] {
        set ref [file tail [get_object_name $lc]]
        foreach_in_collection c [get_cells -quiet -hierarchical -filter "ref_name == $ref"] {
            foreach_in_collection p [get_pins -quiet -of_objects $c -filter "pin_direction == in"] {
                set lp [get_lib_pins -quiet [get_object_name $lc]/[file tail [get_object_name $p]]]
                if {[get_attribute -quiet $lp clock_gate_clock_pin] eq "true"} {
                    lappend out [get_object_name $p]
                }
            }
        }
    }
    return $out
}

# Is a pin driven by the freeze gate or one of the freeze cells? Its net has
# exactly one leaf driver, and that driver lies inside one of them (the leaf
# is the gate's own AND cell, not its clk_o pin).
proc fi__frozen_driver {pin} {
    global FI_GATE_INST FI_FREEZE_CELLS
    lassign [fi__drivers $pin] d p
    if {[sizeof_collection $d] != 1 || [sizeof_collection $p]} { return 0 }
    set cells [list $FI_GATE_INST]
    if {[info exists FI_FREEZE_CELLS]} { set cells [concat $cells $FI_FREEZE_CELLS] }
    return [fi__under [get_object_name $d] $cells]
}

proc fi_insert_clock_gate {} {
    global FI_CLK_PORT FI_RST_PORT FI_GATE_PORT FI_HOLD_PORT
    global FI_GATE_MODULE FI_FREEZE_MODULE FI_GATE_INST FI_GATE_NET FI_FREEZE_NET FI_GATE_SRC
    global FI_FROZEN_PINS FI_FREEZE_CELLS

    set top [lindex [get_object_name [current_design]] 0]
    set FI_FROZEN_PINS [fi__frozen_pins]
    if {[llength $FI_FROZEN_PINS] == 0} {
        fi__die "FI_GATE_PINS and FI_FREEZE are empty -- nothing would ever be frozen"
    }

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

    # -- compile the portable gate modules, then freeze them -------
    # Compiled standalone so set_dont_touch can protect their structure
    # from the top-level compile_ultra and from insert_dft.
    if {[sizeof_collection [get_designs -quiet [list $FI_GATE_MODULE $FI_FREEZE_MODULE]]] < 2} {
        analyze -format verilog $FI_GATE_SRC
        foreach m [list $FI_GATE_MODULE $FI_FREEZE_MODULE] {
            elaborate $m
            current_design $m
            compile_ultra
            set_dont_touch [get_designs $m]
        }
        current_design $top
        link
    }

    # -- instantiate and wire the synchroniser + shared gate ------
    if {[sizeof_collection [get_cells -quiet $FI_GATE_INST]] == 0} {
        create_cell $FI_GATE_INST $FI_GATE_MODULE
        link
    }
    if {[sizeof_collection [get_pins -quiet $FI_GATE_INST/clk_o]] == 0} {
        fi__die "$FI_GATE_INST has no clk_o pin -- $FI_GATE_MODULE did not\
                 link. Check that analyze/elaborate of $FI_GATE_SRC succeeded."
    }
    foreach n [list $FI_GATE_NET $FI_FREEZE_NET] {
        if {[sizeof_collection [get_nets -quiet $n]] == 0} { create_net $n }
    }
    connect_net [fi__port_net $FI_CLK_PORT]  [get_pins $FI_GATE_INST/clk_i]
    connect_net [fi__port_net $FI_RST_PORT]  [get_pins $FI_GATE_INST/rst_ni]
    connect_net [fi__port_net $FI_GATE_PORT] [get_pins $FI_GATE_INST/clk_gate_i]
    connect_net [get_nets $FI_GATE_NET]      [get_pins $FI_GATE_INST/clk_o]
    # Latch holds (fi_pre_compile) wait on a temporary port; the freeze
    # window drives their net from here on, and the port goes.
    if {[sizeof_collection [get_ports -quiet $FI_HOLD_PORT]]} {
        set hn [all_connected [get_ports $FI_HOLD_PORT]]
        disconnect_net $hn [get_ports $FI_HOLD_PORT]
        remove_port [get_ports $FI_HOLD_PORT]
        connect_net $hn [get_pins $FI_GATE_INST/freeze_o]
        fi__msg INFO "latch holds now driven by $FI_GATE_INST/freeze_o"
    } else {
        connect_net [get_nets $FI_FREEZE_NET] [get_pins $FI_GATE_INST/freeze_o]
    }

    # -- every frozen pin -------------------------------------------
    # On the free-running clock itself: re-driven from the shared gate.
    # Behind anything else (the DUT's own clock gate, an ICG compile
    # inserted): a freeze cell spliced in series right in front of the pin,
    # so that gate keeps working; the freeze window reaches it from the
    # synchroniser. Ports are created through the hierarchy as needed.
    set FI_FREEZE_CELLS {}
    set moved 0 ; set series 0 ; set kept 0
    foreach p $FI_FROZEN_PINS {
        set pin [get_pins -quiet $p]
        if {[sizeof_collection $pin] == 0} {
            fi__die "frozen pin '$p' does not exist in $top"
        }
        if {[fi__frozen_driver $pin]} { incr kept ; continue }
        lassign [fi__drivers $pin] dp dpt
        set dn  [get_object_name $dp]
        set dtn [get_object_name $dpt]
        set old [all_connected $pin]
        if {[llength $dn] == 0 && $dtn eq $FI_CLK_PORT} {
            if {[sizeof_collection $old]} { disconnect_net $old $pin }
            if {[file dirname [file dirname $p]] eq "."} {
                connect_net [get_nets $FI_GATE_NET] $pin
            } else {
                connect_pin -from [get_pins $FI_GATE_INST/clk_o] -to $pin -port_name $FI_GATE_NET
            }
            incr moved
        } elseif {[llength $dn] == 1 && $dtn eq ""} {
            set par [file dirname [file dirname $p]]
            set k   [llength $FI_FREEZE_CELLS]
            set fc  [expr {$par eq "." ? "" : "$par/"}]u_fi_clk_freeze_$k
            # one design per cell: connect_pin refuses an instance whose design
            # has several instances (UID-399)
            set fd  ${FI_FREEZE_MODULE}_$k
            if {![sizeof_collection [get_designs -quiet $fd]]} {
                copy_design $FI_FREEZE_MODULE $fd
                set_dont_touch [get_designs $fd]
            }
            create_cell $fc $fd
            disconnect_net $old $pin
            connect_net $old [get_pins $fc/clk_i]
            connect_pin -from [get_pins $fc/clk_o] -to $pin -port_name [file tail $fc]_clk
            connect_pin -from [get_pins $FI_GATE_INST/freeze_o] -to [get_pins $fc/freeze_i] \
                        -port_name $FI_FREEZE_NET
            lappend FI_FREEZE_CELLS $fc
            incr series
        } else {
            fi__die "frozen pin $p: its net is driven by {$dn} {$dtn}; expected $FI_CLK_PORT\
                     or exactly one driver pin"
        }
        if {![fi__frozen_driver $pin]} {
            lassign [fi__drivers $pin] d2 p2
            fi__die "frozen pin $p is driven by {[get_object_name $d2]} {[get_object_name $p2]}\
                     after the insertion"
        }
    }

    # The gate itself must never be scanned: its synchronizer flop is
    # clocked by the ScanClock, so DC would happily stitch it in, and
    # then shifting would drive the freeze signal with scan data.
    set_scan_element false [get_cells $FI_GATE_INST]
    set_dont_touch         [get_cells $FI_GATE_INST]
    set_dont_touch         [get_nets -segments -of_objects [get_pins $FI_GATE_INST/clk_o]]
    set_dont_touch         [get_nets -segments -of_objects [get_pins $FI_GATE_INST/freeze_o]]
    foreach fc $FI_FREEZE_CELLS {
        set_dont_touch [get_cells $fc]
        set_dont_touch [get_nets -segments -of_objects [get_pins $fc/clk_o]]
    }

    fi__msg INFO "clock gate inserted: $FI_GATE_INST -> $FI_GATE_NET, $moved pin(s)\
                  re-routed, $series behind a gate of the DUT ($series freeze cell(s)),\
                  $kept already gated"
}

# ============================================================
# fi_apply_scan_exclusion -- mapped design, before insert_dft
# ============================================================
# The instances kept off the chain: the owners of the frozen pins, the exempt
# instances and the freeze gate.
proc fi__scan_off_insts {} {
    global FI_FROZEN_PINS FI_EXEMPT FI_GATE_INST
    set insts {}
    foreach p $FI_FROZEN_PINS { lappend insts [file dirname $p] }
    foreach i $FI_EXEMPT    { lappend insts $i }
    lappend insts $FI_GATE_INST
    return [lsort -unique $insts]
}

proc fi_apply_scan_exclusion {} {
    global FI_EXEMPT_CLOCKS

    set n 0
    foreach i [fi__scan_off_insts] {
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

    # The registers of an exempt clock domain stay off the chain wherever they
    # sit. Left alone, DFT would make them scannable by muxing the scan clock
    # into their clock path in test mode.
    set nx 0
    foreach {ec xr} [fi__exempt_clock_regs] {
        if {[sizeof_collection $xr]} { set_scan_element false $xr ; incr nx [sizeof_collection $xr] }
    }
    if {$nx} { fi__msg INFO "set_scan_element false applied to $nx register(s) of FI_EXEMPT_CLOCKS" }
}

# The registers insert_dft will stitch, on the mapped design before it: the
# scan cells (a pin with signal_type test_scan_in in the library) that
# fi_apply_scan_exclusion did not keep off the chain.
proc fi__scan_candidates {} {
    set off [fi__scan_off_insts]
    array set xclk {}
    foreach {ec xr} [fi__exempt_clock_regs] {
        foreach n [get_object_name $xr] { set xclk($n) 1 }
    }
    set out {}
    foreach_in_collection r [all_registers -edge_triggered] {
        set n [get_object_name $r]
        if {[info exists xclk($n)] || [fi__under $n $off]} { continue }
        if {[sizeof_collection [fi__lib_attr_pins_eq $r signal_type test_scan_in]]} { lappend out $n }
    }
    return [get_cells -quiet $out]
}

# ============================================================
# fi_dft_config -- the DFT settings FI needs, before insert_dft
# ============================================================
# One chain, shifted by the functional clock while testmode is high. A flow
# that also does manufacturing-test DFT builds the FI netlist separately: the
# executor cannot shift a second chain, a compressor or a second scan clock.
proc fi_dft_config {} {
    global FI_CLK_PORT FI_RST_PORT FI_TESTMODE_PORT
    global FI_SCAN_IN_PORT FI_SCAN_EN_PORT FI_SCAN_OUT_PORT
    global FI_CHAIN_HEAD_NORESET FI_CHAIN_NAME
    set top [get_object_name [current_design]]
    foreach p [list $FI_CLK_PORT $FI_RST_PORT] {
        if {![sizeof_collection [get_ports -quiet $p]]} { fi__die "port '$p' not found on $top (fix fi_scan_cfg.tcl)" }
    }
    if {![sizeof_collection [get_ports -quiet $FI_TESTMODE_PORT]]} {
        fi__die "no port $FI_TESTMODE_PORT on $top: name the DUT's test-mode port in FI_TESTMODE_PORT,\
                 or the pins it should drive in FI_TESTMODE_PIN, or set FI_TESTMODE_CREATE 1 when the DUT has\
                 none (fi_pre_compile then creates it)"
    }
    foreach p [list $FI_SCAN_IN_PORT $FI_SCAN_EN_PORT $FI_SCAN_OUT_PORT] {
        if {[sizeof_collection [get_ports -quiet $p]]} {
            fi__die "$top already has a port $p; the scan ports are created here, so give\
                     FI_SCAN_IN_PORT / FI_SCAN_EN_PORT / FI_SCAN_OUT_PORT names that are free"
        }
    }

    # Keep the design name, and let insert_dft stitch the chain without
    # re-optimising the design around it: the cells and nets the freeze
    # insertion placed stay as they are.
    set_dft_insertion_configuration -preserve_design_name true
    set_dft_insertion_configuration -synthesis_optimization none

    # One chain across the DUT, so clocks mix. Safe here: every domain that
    # cannot be shifted is already off the chain (frozen or exempt).
    set_scan_configuration -clock_mixing mix_clocks

    # Only the free-running clock is a ScanClock, never the gated branch: a
    # frozen flop then has no test clock either (besides set_scan_element
    # false, fi_apply_scan_exclusion).
    set_dft_signal -view existing_dft -type ScanClock -timing [list 45 55] -port $FI_CLK_PORT
    set_dft_signal -view spec         -type ScanClock -port $FI_CLK_PORT

    set_dft_signal -view existing_dft -type Reset -active_state 0 -port $FI_RST_PORT
    set_dft_signal -view spec         -type Reset -active_state 0 -port $FI_RST_PORT

    set_dft_signal -view existing_dft -type TestMode -active_state 1 -port $FI_TESTMODE_PORT
    set_dft_signal -view spec         -type TestMode -active_state 1 -port $FI_TESTMODE_PORT

    set_dft_configuration -fix_reset enable
    set_dft_configuration -fix_set enable
    # No clock AutoFix: its mux selects the scan clock while testmode is high.
    # Manufacturing test holds testmode still; FI raises it on every pass,
    # inside a clock's high phase, and a register behind a closed gate would
    # shift once too often. A6 requires every chain clock to be opened by the
    # shift itself instead; a register whose clock is not stays off the chain.
    set_dft_configuration -fix_clock disable
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
    fi__msg INFO "DFT settings for FI: one chain on $FI_CLK_PORT, TestMode $FI_TESTMODE_PORT, ports\
                  $FI_SCAN_IN_PORT / $FI_SCAN_EN_PORT / $FI_SCAN_OUT_PORT"

    # FI_CHAIN_HEAD_NORESET: the cells the DUT reset does not put back go first,
    # next to Scan_In. The scrub at the end of a trial then needs only as many
    # shifts as there are of them (FI_SCRUB_LEN, checked by A12): they take its
    # zeros, and the reset that follows puts back every cell after them.
    # (-head_elements, not -ordered_elements: insert_dft puts the cells it adds
    # to a scan path in front of an ordered list, but after the head.)
    if {$FI_CHAIN_HEAD_NORESET} {
        set heads [lsort -dictionary [fi__unreset_regs [fi__scan_candidates]]]
        if {[llength $heads]} {
            set_scan_path $FI_CHAIN_NAME -head_elements $heads -complete false \
                -scan_data_in $FI_SCAN_IN_PORT -scan_data_out $FI_SCAN_OUT_PORT
        }
        fi__msg INFO "chain head: [llength $heads] cell(s) without a reset first on the chain. [fi__group $heads]"
    }
}

# ============================================================
# internal: the chain in shift order, index 0 = the first cell after scan-in,
# from report_scan_path. Not from the scandef, which lists the chain as
# FLOATING and in another order (syn/README.md).
# ============================================================
proc fi__scan_order {} {
    global FI_RESULTS_DIR

    set f ${FI_RESULTS_DIR}/fi_scan_path.rpt
    redirect $f { report_scan_path }

    set fh [open $f r]
    set txt [read $fh]
    close $fh

    # The per-cell listing of the chain AS BUILT BY insert_dft. With a scan path
    # given (FI_CHAIN_HEAD_NORESET's head) the report first lists that
    # specification under the same Cell_# header; it is not the chain.
    array set seen {}
    set built 0
    set collecting 0
    foreach line [split $txt "\n"] {
        if {!$collecting} {
            if {[string first "AS BUILT BY insert_dft" $line] >= 0} { set built 1 }
            if {$built && [string first "Cell_#" $line] >= 0} { set collecting 1 }
            continue
        }
        set l [string trim $line]
        if {$l eq "" || [string index $l 0] eq "-"} { continue }
        # drop the "I <chain>" prefix that only the first row carries
        regsub {^[A-Za-z]+[ \t]+[A-Za-z0-9_]+[ \t]+([0-9])} $l {\1} l
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
