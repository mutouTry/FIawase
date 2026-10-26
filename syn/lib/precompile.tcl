# SPDX-License-Identifier: Apache-2.0
# Copyright 2025-2026 the FIawase authors
# fi_pre_compile, on the generic netlist, and fi_survey, after the first compile.
# Sourced by syn/fi_scan_lib.tcl.

# ============================================================
# fi_pre_compile -- after link/uniquify, before the first compile (its
# helpers first)
# ============================================================

# No compile-inserted clock gates on registers that keep a clock through the
# window (FI_EXEMPT blocks, FI_EXEMPT_CLOCKS domains): insert_dft gives such a
# gate TE = Scan_En, which can open it on an edge it should block.
proc fi__exclude_clock_gating {} {
    global FI_GATE_CLOCK FI_EXEMPT FI_EXEMPT_CLOCKS
    if {$FI_GATE_CLOCK} {
        set ex {}
        if {[llength $FI_EXEMPT]} {
            set ec [get_cells -quiet $FI_EXEMPT]
            if {[sizeof_collection $ec] != [llength $FI_EXEMPT]} {
                fi__die "FI_EXEMPT: some instance does not exist: $FI_EXEMPT"
            }
            set ex $ec
        }
        set nx 0
        foreach {c xr} [fi__exempt_clock_regs] {
            incr nx [sizeof_collection $xr]
            set ex [add_to_collection $ex $xr]
        }
        if {[sizeof_collection $ex]} {
            set_clock_gating_objects -exclude $ex
            fi__msg INFO "clock gating excluded from FI_EXEMPT {$FI_EXEMPT} and from $nx register(s)\
                          of FI_EXEMPT_CLOCKS {$FI_EXEMPT_CLOCKS}"
        }
    }
}

# The latches that store data: no clock reaches their enable (its fan-in
# starts at no clock source). On the generic netlist, where every latch has
# an active-high pin "enable"; needs the clocks of the SDC.
proc fi__storage_latches {} {
    set ckports {}
    foreach_in_collection c [all_clocks] {
        foreach n [get_object_name [get_ports -quiet [get_attribute -quiet $c sources]]] { lappend ckports $n }
    }
    set store {}
    foreach_in_collection l [all_registers -level_sensitive] {
        set en [get_pins -quiet -of_objects $l -filter "pin_direction == in && name == enable"]
        if {![sizeof_collection $en]} { continue }
        set roots [get_object_name [get_ports -quiet [all_fanin -to $en -flat -startpoints_only]]]
        set clocked 0
        foreach r $roots { if {[lsearch -exact $ckports $r] >= 0} { set clocked 1 } }
        if {!$clocked} { lappend store [get_object_name $l] }
    }
    return $store
}

# ============================================================
# Netlist edits a port may ask for, none of them in the DUT's RTL:
#   FI_TESTMODE_PIN      pins the RTL ties off for test mode, re-driven from a
#                        new top port FI_TESTMODE_PORT
#   FI_TESTMODE_CREATE   that port alone, for a DUT with no test-mode input
#   FI_TIE_PINS          {pin value ...}: pins tied to 0/1, e.g. a clock-mux
#                        select that must not move
#   FI_BLACKBOX_MODULES  modules emptied to pin-compatible black boxes
#                        (memories without a .db; A9, A10)
#   FI_LATCH_HOLD        a hold in front of each data latch's enable (A1)
#   FI_CLEAR             a clear for each register off the chain with no
#                        reset (A11)
#   FI_GATE_CLOCK        no compile clock gates in FI_EXEMPT blocks and
#                        FI_EXEMPT_CLOCKS domains (A8)
# Before the first compile, which would propagate a tie-off and delete the
# logic behind it. Every edit is read back: dc_shell's netlist commands report
# a failure as an Error message and still return normally.
proc fi_pre_compile {} {
    global FI_TESTMODE_PIN FI_TESTMODE_PORT FI_TIE_PINS FI_BLACKBOX_MODULES
    global FI_GATE_CLOCK FI_EXEMPT FI_BLACKBOX_INSTS FI_BLACKBOX_LOADED_OUTS
    global FI_LATCH_HOLD FI_HOLD_MODULE FI_HOLD_PORT FI_HOLD_CELLS FI_GATE_SRC
    global FI_FREEZE FI_GATE_PINS
    global FI_TESTMODE_CREATE
    set top [get_object_name [current_design]]
    set FI_BLACKBOX_INSTS {}
    # a reference without a definition must not become a silently missing block
    if {![link]} { fi__die "link failed: an unresolved reference (LINK-5 / UID-341 above) -- every module the design uses needs its source in the RTL list" }

    # -- the config's names, before anything is edited: a typo must not
    # quietly leave a block out of the freeze or the exemptions
    foreach x [concat $FI_FREEZE $FI_GATE_PINS $FI_EXEMPT] {
        if {![sizeof_collection [get_cells -quiet $x]] && ![sizeof_collection [get_pins -quiet $x]]} {
            fi__die "fi_scan_cfg.tcl: no instance or pin '$x' in $top"
        }
    }
    fi__exempt_clock_regs

    # -- a test-mode pin the RTL ties off -> new top port ---------------
    if {[llength $FI_TESTMODE_PIN]} {
        if {[sizeof_collection [get_ports -quiet $FI_TESTMODE_PORT]]} {
            fi__die "FI_TESTMODE_PIN is set but $top already has a port\
                     $FI_TESTMODE_PORT -- give one or the other"
        }
        create_port $FI_TESTMODE_PORT -direction in
        create_net  $FI_TESTMODE_PORT
        connect_net [get_nets $FI_TESTMODE_PORT] [get_ports $FI_TESTMODE_PORT]
        foreach p $FI_TESTMODE_PIN {
            set pin [get_pins -quiet $p]
            if {![sizeof_collection $pin]} { fi__die "FI_TESTMODE_PIN: no pin $p in $top" }
            set old [all_connected $pin]
            set was [get_object_name $old]
            if {[sizeof_collection $old]} { disconnect_net $old $pin }
            if {[file dirname [file dirname $p]] eq "."} {
                connect_net [get_nets $FI_TESTMODE_PORT] $pin
            } else {
                connect_pin -from [get_ports $FI_TESTMODE_PORT] -to $pin \
                            -port_name $FI_TESTMODE_PORT
            }
            lassign [fi__drivers $pin] d pt
            if {[sizeof_collection $d] || [lsearch -exact [get_object_name $pt] $FI_TESTMODE_PORT] < 0} {
                fi__die "FI_TESTMODE_PIN: $p is not driven by port $FI_TESTMODE_PORT after the splice"
            }
            fi__msg INFO "testmode: $p (was $was) now driven by port $FI_TESTMODE_PORT"
        }
    }
    # -- a DUT with no test-mode input at all: the port, for DFT's TestMode signal only
    if {$FI_TESTMODE_CREATE} {
        if {[llength $FI_TESTMODE_PIN]} { fi__die "FI_TESTMODE_CREATE and FI_TESTMODE_PIN are both set -- give one or the other" }
        if {[sizeof_collection [get_ports -quiet $FI_TESTMODE_PORT]]} {
            fi__die "FI_TESTMODE_CREATE is set but $top already has a port $FI_TESTMODE_PORT -- name it in FI_TESTMODE_PORT instead"
        }
        create_port $FI_TESTMODE_PORT -direction in
        fi__msg WARN "created top port '$FI_TESTMODE_PORT' (FI_TESTMODE_CREATE): it drives only what DFT insertion\
                      connects to TestMode"
    }

    # -- pins tied to a constant for the FI build -------------------------
    foreach {p v} $FI_TIE_PINS {
        if {$v ne "0" && $v ne "1"} { fi__die "FI_TIE_PINS: value of $p must be 0 or 1, got '$v'" }
        set pin [get_pins -quiet $p]
        if {![sizeof_collection $pin]} { fi__die "FI_TIE_PINS: no pin $p in $top" }
        set cell [file dirname $p]
        set pd   [fi__parent_design $cell]
        if {[sizeof_collection [get_cells -quiet -hierarchical -filter "ref_name == $pd"]] > 1} {
            fi__die "FI_TIE_PINS: $p sits in design $pd, which has several instances;\
                     uniquify first"
        }
        set old [all_connected $pin]
        set was [get_object_name $old]
        if {[sizeof_collection $old]} { disconnect_net $old $pin }
        set const [expr {$v ? "*Logic1*" : "*Logic0*"}]
        # a constant net exists per design: connect from inside the parent
        current_design $pd
        connect_net $const [get_pins [file tail $cell]/[file tail $p]]
        current_design $top
        set now [get_object_name [all_connected $pin]]
        if {[string first $const $now] < 0} {
            fi__die "FI_TIE_PINS: $p is on '$now' after the tie, not $const"
        }
        fi__msg INFO "tie: $p (was $was) now $v"
    }

    # -- memories without a .db -> black boxes, emptied to their ports: no cells
    # and no nets (an output port left on an undriven net reads as a constant to
    # compile, which then deletes the logic it feeds; A10 checks)
    foreach m $FI_BLACKBOX_MODULES {
        set ds [get_designs -quiet [list $m ${top}_${m}_*]]
        if {![sizeof_collection $ds]} { fi__die "FI_BLACKBOX_MODULES: no design $m" }
        foreach_in_collection d $ds {
            set dn [get_object_name $d]
            current_design $dn
            set c [get_cells -quiet *]
            if {[sizeof_collection $c]} { remove_cell $c }
            set nn [get_nets -quiet *]
            if {[sizeof_collection $nn]} { remove_net $nn }
            if {[sizeof_collection [get_cells -quiet *]] || [sizeof_collection [get_nets -quiet *]]} {
                fi__die "could not empty design $dn down to its ports"
            }
            current_design $top
            set insts [get_cells -quiet -hierarchical -filter "ref_name == $dn"]
            set_dont_touch $insts
            foreach n [get_object_name $insts] { lappend FI_BLACKBOX_INSTS $n }
        }
    }
    current_design $top
    link
    # The black-box outputs that feed something now, for A10.
    set FI_BLACKBOX_LOADED_OUTS {}
    foreach b $FI_BLACKBOX_INSTS {
        foreach_in_collection p [get_pins -quiet -of_objects [get_cells $b] -filter "pin_direction == out"] {
            if {[sizeof_collection [get_pins -quiet -leaf -of_objects \
                    [get_nets -quiet -segments -of_objects $p] -filter "pin_direction == in"]]} {
                lappend FI_BLACKBOX_LOADED_OUTS [get_object_name $p]
            }
        }
    }
    if {[llength $FI_BLACKBOX_INSTS]} {
        fi__msg INFO "black boxes ([llength $FI_BLACKBOX_INSTS]): $FI_BLACKBOX_INSTS --\
                      each must be frozen (A9); [llength $FI_BLACKBOX_LOADED_OUTS] output pin(s)\
                      with loads, which must keep them (A10)"
    }

    # -- holds on latches that store data (no clock reaches their enable): the
    # enable follows the scrambled logic while the chain shifts. fi_latch_hold
    # goes in front of it here, where every latch enable is active high; its
    # hold input is a temporary port until fi_insert_clock_gate drives it.
    set FI_HOLD_CELLS {}
    set store [fi__storage_latches]
    if {$FI_LATCH_HOLD} {
        if {[llength $store]} {
            if {[sizeof_collection [get_designs -quiet $FI_HOLD_MODULE]] == 0} {
                analyze -format verilog $FI_GATE_SRC
                elaborate $FI_HOLD_MODULE
                current_design $FI_HOLD_MODULE
                compile_ultra
                set_dont_touch [get_designs $FI_HOLD_MODULE]
                current_design $top
                link
            }
            create_port $FI_HOLD_PORT -direction in
            set k 0
            foreach ln $store {
                set en  [get_pins $ln/enable]
                set par [file dirname $ln]
                set hc  [expr {$par eq "." ? "" : "$par/"}]u_fi_latch_hold_$k
                set hd  ${FI_HOLD_MODULE}_$k
                copy_design $FI_HOLD_MODULE $hd
                set_dont_touch [get_designs $hd]
                create_cell $hc $hd
                set old [all_connected $en]
                disconnect_net $old $en
                connect_net $old [get_pins $hc/en_i]
                connect_pin -from [get_pins $hc/en_o] -to $en -port_name [file tail $hc]_en
                connect_pin -from [get_ports $FI_HOLD_PORT] -to [get_pins $hc/hold_i] -port_name $FI_HOLD_PORT
                lassign [fi__drivers $en] d pt
                if {[sizeof_collection $d] != 1 || ![fi__under [get_object_name $d] [list $hc]]} {
                    fi__die "latch hold: $ln/enable is not driven by $hc after the insertion"
                }
                # no buffers on either side: the checks read these nets back
                set_dont_touch [get_nets -segments -of_objects [get_pins $hc/en_o]]
                lappend FI_HOLD_CELLS $hc
                incr k
            }
            set_dont_touch [get_nets -segments -of_objects [get_ports $FI_HOLD_PORT]]
            current_design $top
            link
            fi__msg INFO "latch holds: [llength $store] latch(es) that store data, each behind\
                          $FI_HOLD_MODULE. [fi__group $store]"
        }
    }

    fi__insert_clears $store
    fi__exclude_clock_gating
}

# ============================================================
# fi_survey -- what a port has to classify, before writing the config
# ============================================================
# Read-only, after the first compile (the example flow: FI_SURVEY 1|only).
# Writes ${FI_RESULTS_DIR}/fi_survey.rpt: the clocks and the registers each
# reaches; every register clock net with its root ports and the gates and
# latches on the way; clock-gating cells and latches (gating or storing);
# black boxes; the test-mode port's fan-out; registers without an
# asynchronous reset or set.
proc fi_survey {} {
    global FI_RESULTS_DIR FI_CLK_PORT FI_TESTMODE_PORT
    set dir [expr {$FI_RESULTS_DIR ne "" ? $FI_RESULTS_DIR : "."}]
    file mkdir $dir
    set fn  $dir/fi_survey.rpt
    set out [open $fn w]
    set top [get_object_name [current_design]]
    puts $out "# fi_survey of $top"

    # -- clocks and their registers --------------------------------------
    set regs [all_registers]
    puts $out "\n## registers: [sizeof_collection $regs] (edge-triggered\
               [sizeof_collection [all_registers -edge_triggered]], level-sensitive\
               [sizeof_collection [all_registers -level_sensitive]])"
    array set clocked {}
    foreach_in_collection c [all_clocks] {
        set cn  [get_object_name $c]
        set src [get_object_name [get_attribute -quiet $c sources]]
        set per [get_attribute -quiet $c period]
        if {[catch {set r [all_registers -clock $c]} e]} {
            puts $out "\n## clock $cn ($src, $per ns): all_registers failed: $e"
            continue
        }
        set names [get_object_name $r]
        foreach n $names { set clocked($n) 1 }
        puts $out "\n## clock $cn ($src, $per ns): [llength $names] registers"
        puts $out "   [fi__group $names 4 40]"
    }
    set unclocked {}
    foreach n [get_object_name $regs] { if {![info exists clocked($n)]} { lappend unclocked $n } }
    puts $out "\n## registers no clock reaches: [llength $unclocked]"
    if {[llength $unclocked]} { puts $out "   [fi__group $unclocked 4 40]" }

    # -- library clock-gating cells -----------------------------------------
    set icg_refs [get_object_name [get_lib_cells -quiet */* -filter "clock_gating_integrated_cell =~ *"]]
    set icg_names {}
    foreach r $icg_refs { lappend icg_names [file tail $r] }
    set icgs {}
    foreach r [lsort -unique $icg_names] {
        foreach n [get_object_name [get_cells -quiet -hierarchical -filter "ref_name == $r"]] { lappend icgs $n }
    }
    puts $out "\n## library clock-gating cells: [llength $icgs] instance(s) of [lsort -unique $icg_names]"
    if {[llength $icgs]} { puts $out "   [fi__group $icgs 4 40]" }

    # -- register clock nets: roots and what lies between ---------------------
    # One all_fanin per distinct clock net, not per register.
    array set net_regs {}
    array set net_pin  {}
    if {[catch {set ckp [all_registers -clock_pins]} e]} {
        puts $out "\n## clock nets: all_registers -clock_pins failed: $e"
        set ckp {}
    }
    foreach_in_collection p $ckp {
        set nn [get_object_name [get_nets -quiet -of_objects $p]]
        if {![info exists net_pin($nn)]} { set net_pin($nn) $p ; set net_regs($nn) 0 }
        incr net_regs($nn)
    }
    array set kind_regs {}
    array set kind_nets {}
    foreach nn [array names net_pin] {
        set p $net_pin($nn)
        set sp [all_fanin -to $p -flat -startpoints_only]
        set roots [lsort [get_object_name [get_ports -quiet $sp]]]
        set cells [all_fanin -to $p -flat -only_cells]
        set kinds {}
        foreach_in_collection c $cells {
            set ref [get_attribute -quiet $c ref_name]
            if {[lsearch -exact $icg_names $ref] >= 0} { lappend kinds icg ; continue }
            if {[get_attribute -quiet $c is_sequential] eq "true"} { lappend kinds seq:$ref ; continue }
        }
        set key "roots={$roots} through={[lsort -unique $kinds]}"
        if {![info exists kind_regs($key)]} { set kind_regs($key) 0 ; set kind_nets($key) 0 }
        incr kind_regs($key) $net_regs($nn)
        incr kind_nets($key)
    }
    puts $out "\n## register clock nets by root and by what gates them (registers, nets)"
    foreach key [lsort [array names kind_regs]] {
        puts $out "   $kind_regs($key) regs on $kind_nets($key) net(s): $key"
    }

    # -- latches: clock gates or storage -------------------------------------
    set gate_l [fi__gate_latches]
    array set is_g {}
    foreach n $gate_l { set is_g($n) 1 }
    set store_l {}
    foreach n [get_object_name [all_registers -level_sensitive]] {
        if {![info exists is_g($n)]} { lappend store_l $n }
    }
    puts $out "\n## latches gating a clock (latch + AND on the latch's own enable net): [llength $gate_l]"
    if {[llength $gate_l]} { puts $out "   [fi__group $gate_l 5 40]" }
    puts $out "\n## latches storing data (not a clock gate; neither scannable nor frozen by a clock): [llength $store_l]"
    foreach n $store_l { puts $out "   $n" }

    # -- black boxes -----------------------------------------------------------
    set bb [fi__blackbox_insts]
    puts $out "\n## black boxes (FI_BLACKBOX_MODULES): [llength [lsort -unique $bb]]"
    foreach n [lsort -unique $bb] { puts $out "   $n" }

    # -- the test-mode port's fan-out ---------------------------------------
    if {[sizeof_collection [get_ports -quiet $FI_TESTMODE_PORT]]} {
        set ep [all_fanout -from [get_ports $FI_TESTMODE_PORT] -flat -endpoints_only]
        set epn [get_object_name $ep]
        puts $out "\n## $FI_TESTMODE_PORT reaches [llength $epn] endpoint(s)"
        if {[llength $epn]} { puts $out "   [fi__group $epn 5 40]" }
    } else {
        puts $out "\n## no port $FI_TESTMODE_PORT"
    }

    # -- registers without an asynchronous reset or set ---------------------
    # On the chain the scrub sets them; off the chain nothing does.
    set nr {}
    foreach_in_collection r [all_registers -edge_triggered] {
        if {![sizeof_collection [fi__async_pins_of $r]]} { lappend nr [get_object_name $r] }
    }
    puts $out "\n## edge-triggered registers without an async reset/set: [llength $nr]"
    if {[llength $nr]} { puts $out "   [fi__group $nr 5 40]" }

    close $out
    fi__msg INFO "survey written to $fn"
}
