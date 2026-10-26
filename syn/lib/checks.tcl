# SPDX-License-Identifier: Apache-2.0
# Copyright 2025-2026 the FIawase authors
# fi_check_invariants: A1..A12 on the final netlist.
# Sourced by syn/fi_scan_lib.tcl.

# ============================================================
# fi_check_invariants -- the final netlist, before change_names
# ============================================================
# After insert_dft and every later netlist change, before change_names (the
# config's names are the elaborated ones). Called directly, not through
# fi_step: a violation is a verdict (FI-FAIL); fi_scanmap.txt is still
# written, and fi_export_scanmap refuses the files the wrapper and host use.
# A2 uses only the scan path report and instance names; the other checks
# walk the netlist, and a config name that matches nothing ends the run.
proc fi_check_invariants {} {
    global FI_FROZEN_PINS FI_FREEZE_CELLS FI_EXEMPT FI_EXEMPT_CLOCKS FI_BLACKBOX_LOADED_OUTS
    global FI_CLEAR FI_SLOW_CLOCKS FI_LATCH_HOLD
    global FI_GATE_INST FI_GATE_NET FI_N_FF
    global FI_CLK_PORT FI_RST_PORT FI_GATE_PORT
    global FI_SCAN_LEN FI_CHECK_SUMMARY FI_CHECK_OK FI_HOLD_MODULE
    global FI_CHAIN_HEAD_NORESET FI_SCRUB_LEN

    set FI_CHECK_OK 0
    set fails {}
    set order [fi__scan_order]
    set L     [llength $order]
    array set on_chain {}
    foreach c $order { set on_chain($c) 1 }

    set owners {}
    foreach p $FI_FROZEN_PINS { lappend owners [file dirname $p] }
    set tool [concat [list $FI_GATE_INST] $FI_FREEZE_CELLS]

    # -- A1: every frozen pin is driven by the gate or a freeze cell -----
    foreach p $FI_FROZEN_PINS {
        set pin [get_pins -quiet $p]
        if {![sizeof_collection $pin] || ![fi__frozen_driver $pin]} {
            lassign [fi__drivers $pin] d pt
            lappend fails "A1 \[frozen-pins-are-gated\]  $p is driven by {[get_object_name $d]}\
                           {[get_object_name $pt]}, not by $FI_GATE_INST or a freeze cell"
        }
    }

    # -- A1b: every latch hold is driven by the freeze window --------------
    set holds [fi__hold_cells]
    array set held {}
    foreach hc $holds {
        lassign [fi__drivers [get_pins -quiet $hc/hold_i]] d pt
        if {[sizeof_collection $d] != 1 || ![fi__under [get_object_name $d] [list $FI_GATE_INST]]} {
            lappend fails "A1 \[latch-holds-are-driven-by-the-freeze\]  $hc/hold_i is driven by\
                           {[get_object_name $d]} {[get_object_name $pt]}, not by $FI_GATE_INST"
        }
        foreach_in_collection lp [get_pins -quiet -leaf -of_objects [get_nets -quiet -segments -of_objects [get_pins -quiet $hc/en_o]] -filter "pin_direction == in"] {
            set held([get_object_name [get_cells -of_objects $lp]]) 1
        }
    }

    # -- A2: nothing is both frozen and shifted ----------------------
    # Pure string work (nothing a DC version can change); conservative: a gated
    # owner is flagged whole. FI_EXEMPT is the escape for an instance with two
    # clocks of which only one is frozen.
    set both {}
    foreach c $order {
        if {[fi__under $c $owners] && ![fi__under $c $FI_EXEMPT]} { lappend both $c }
    }
    if {[llength $both]} {
        lappend fails "A2 \[nothing-both-frozen-and-shifted\]  [llength $both] cell(s) are BOTH under a frozen\
                       instance and on the scan chain -- the chain cannot be\
                       restored bit-perfect. [fi__group $both]"
    }

    # -- classify every register, for A3 -----------------------------
    # Priority: chain > exempt clock > exempt instance > frozen > tool. The
    # exempt clock goes first: a foreign domain (a JTAG TCK) often lives
    # inside a frozen instance.
    array set on_xclk {}
    foreach {ec xr} [fi__exempt_clock_regs] {
        foreach_in_collection r $xr { set on_xclk([lindex [get_object_name $r] 0]) 1 }
    }

    array set is_cg {}
    foreach n [fi__gate_latches] { set is_cg($n) 1 }

    set n_chain 0; set n_xclk 0; set n_exempt 0; set n_frozen 0; set n_tool 0; set n_cg 0; set n_held 0
    set orphans {}
    set frozen_regs {}
    foreach_in_collection r [all_registers] {
        set n [lindex [get_object_name $r] 0]
        if {[info exists on_chain($n)]}          { incr n_chain  ; continue }
        if {[info exists is_cg($n)]}             { incr n_cg     ; continue }
        if {[info exists held($n)]}              { incr n_held   ; continue }
        if {[info exists on_xclk($n)]}           { incr n_xclk   ; continue }
        if {[fi__under $n $FI_EXEMPT]}           { incr n_exempt ; continue }
        if {[fi__under $n $owners]}              { incr n_frozen ; lappend frozen_regs $n ; continue }
        if {[fi__under $n $tool]}                { incr n_tool   ; continue }
        lappend orphans $n
    }

    # -- A3: nothing unaccounted for ---------------------------------
    if {[llength $orphans]} {
        lappend fails "A3 \[every-flop-accounted-for\]  [llength $orphans] register(s) are neither shifted\
                       nor frozen nor exempt: they keep running during the scan\
                       window and cannot be restored. Per group below decide:\
                       add its clock pin to FI_GATE_PINS, its instance to\
                       FI_EXEMPT, or -- if it is a whole foreign clock domain\
                       that is idle during the window -- its clock to\
                       FI_EXEMPT_CLOCKS. [fi__group $orphans][expr {[llength $orphans] <= 40 ? " : [join $orphans { }]" : ""}]"
    }

    array set latches {}
    foreach n [get_object_name [all_registers -level_sensitive]] { set latches($n) 1 }

    # -- A1: every frozen register is behind the freeze -----------------
    # Its clock path must pass the freeze gate or a freeze cell (a second clock
    # inside a frozen block would run through the window). A clock divided by a
    # register inside the block is not followed: list its pins in FI_GATE_PINS.
    # A macro is left to the frozen-pin check above (its model need not mark a
    # clock pin).
    array set fz_ok {}
    set unfrozen {}
    foreach n $frozen_regs {
        set lc [get_lib_cells -quiet -of_objects [get_cells $n]]
        if {[sizeof_collection $lc] && [get_attribute -quiet $lc is_macro_cell] eq "true"} { continue }
        set cps [fi__clock_pins_of [get_cells $n]]
        if {![sizeof_collection $cps]} { lappend unfrozen $n ; continue }
        foreach_in_collection cp $cps {
            set key [fi__net_key $cp]
            if {![info exists fz_ok($key)]} {
                lassign [fi__clock_path $cp latches] root steps
                set fz_ok($key) 0
                foreach st $steps { if {[lindex $st 0] eq "fi"} { set fz_ok($key) 1 } }
            }
            if {!$fz_ok($key)} { lappend unfrozen $n ; break }
        }
    }
    if {[llength $unfrozen]} {
        lappend fails "A1 \[frozen-registers-are-behind-the-freeze\]  [llength $unfrozen] register(s) under a\
                       frozen instance have a clock that passes no freeze gate: they run through the\
                       window. Put their clock in FI_EXEMPT_CLOCKS, or their clock pins in FI_GATE_PINS.\
                       [fi__group $unfrozen]"
    }

    # -- A1: the freeze is fed from the right ports ---------------------
    # Its clock, reset and request each come from exactly their port, and
    # every freeze cell takes the freeze from the gate. (Fan-in start
    # points, so the buffers DC puts on port nets do not matter.)
    foreach {pin port} [list $FI_GATE_INST/clk_i $FI_CLK_PORT $FI_GATE_INST/rst_ni $FI_RST_PORT \
                             $FI_GATE_INST/clk_gate_i $FI_GATE_PORT] {
        set sp [get_object_name [all_fanin -to [get_pins -quiet $pin] -flat -startpoints_only]]
        if {$sp ne $port} {
            lappend fails "A1 \[the-freeze-is-wired\]  $pin is fed from {$sp}, not from port $port alone"
        }
    }
    foreach fc $FI_FREEZE_CELLS {
        lassign [fi__drivers [get_pins -quiet $fc/freeze_i]] d pt
        if {[sizeof_collection $d] != 1 || ![fi__under [get_object_name $d] [list $FI_GATE_INST]]} {
            lappend fails "A1 \[the-freeze-is-wired\]  $fc/freeze_i is driven by {[get_object_name $d]}\
                           {[get_object_name $pt]}, not by $FI_GATE_INST"
        }
    }

    # -- A1: every latch that stores data is held -------------------------
    # A latch that neither gates a clock nor sits behind fi_latch_hold has a
    # data enable that follows the scrambled logic while the chain shifts.
    # The holds are put in by fi_pre_compile (an entry from a .ddc needs one
    # that went through it).
    if {$FI_LATCH_HOLD} {
        set loose {}
        foreach n [array names latches] {
            if {[info exists is_cg($n)] || [info exists held($n)] || [info exists on_xclk($n)]
                || [info exists on_chain($n)] || [fi__under $n $tool]} { continue }
            set lc [get_lib_cells -quiet -of_objects [get_cells $n]]
            if {[sizeof_collection $lc] && ([get_attribute -quiet $lc clock_gating_integrated_cell] ne ""
                                            || [get_attribute -quiet $lc is_macro_cell] eq "true")} { continue }
            lappend loose $n
        }
        if {[llength $loose]} {
            lappend fails "A1 \[latches-that-store-data-are-held\]  [llength $loose] latch(es) neither gate a\
                           clock nor sit behind $FI_HOLD_MODULE. [fi__group $loose]"
        }
    }

    # -- A4: the chain still fits the FI_Entry encoding --------------
    set w_idx [fi__clog2 $FI_N_FF]
    if {$L > $FI_N_FF - 1} {
        lappend fails "A4 \[chain-fits-the-table-encoding\]  L=$L exceeds FI_N_FF-1=[expr {$FI_N_FF-1}].\
                       Raise FI_N_FF in the port's fi_scan_cfg.tcl."
    }

    # -- A5: DFT did not rewire the gated clock ----------------------
    # -fix_clock would make the gated branch "shiftable" and silently disable
    # the freeze. Checked on the whole electrical net behind every gate output,
    # at leaf level: one driver (that output), every load in a frozen instance.
    set outs [list $FI_GATE_INST/clk_o]
    foreach fc $FI_FREEZE_CELLS { lappend outs $fc/clk_o }
    foreach o $outs {
        set segs [get_nets -quiet -segments -of_objects [get_pins $o]]
        set drv  [get_object_name [get_pins -quiet -leaf -of_objects $segs -filter "pin_direction == out"]]
        set drvp [get_object_name [get_ports -quiet -of_objects $segs]]
        if {[llength $drv] != 1 || ![fi__under [lindex $drv 0] [list [file dirname $o]]] || [llength $drvp]} {
            lappend fails "A5 \[gate-not-rewired-by-dft\]  the net of $o is driven by {$drv} {$drvp},\
                           expected only [file dirname $o] itself. Something re-drove the gated clock -- most\
                           likely -fix_clock. Try 'set_dft_configuration -fix_clock disable'."
        }
        set stray {}
        foreach l [get_object_name [get_pins -quiet -leaf -of_objects $segs -filter "pin_direction == in"]] {
            if {![fi__under $l $owners]} { lappend stray $l }
        }
        if {[llength $stray]} {
            lappend fails "A5 \[gate-not-rewired-by-dft\]  $o also clocks [llength $stray] pin(s) outside\
                           every frozen instance. [fi__group $stray]"
        }
    }

    # -- A9: every black box is frozen ----------------------------------
    # all_registers does not see inside a black box, so A3 cannot tell a
    # stateful macro that keeps running through the window from one that
    # is frozen. Its clock pin has to be one of the frozen pins.
    set bb_free {}
    foreach b [fi__blackbox_insts] {
        if {![fi__under $b $owners]} { lappend bb_free $b }
    }
    if {[llength $bb_free]} {
        lappend fails "A9 \[black-boxes-are-frozen\]  [llength [lsort -unique $bb_free]] black box(es) not frozen:\
                       [lsort -unique $bb_free]. Put each one's clock pin in FI_FREEZE."
    }

    # -- A10: black-box outputs still feed the DUT --------------------------
    # Compile cannot see what a black box drives; if it decided an output is
    # constant, it removed the logic behind it, and the netlist no longer
    # reads the memory. Every output that had loads before the first compile
    # (fi_pre_compile) must still have some.
    if {[info exists FI_BLACKBOX_LOADED_OUTS]} {
        set bb_cut [fi__blackbox_cut_outputs]
        if {[llength $bb_cut]} {
            lappend fails "A10 \[black-box-outputs-keep-their-loads\]  [llength $bb_cut] black-box output\
                           pin(s) lost every load in compile: [fi__group $bb_cut]. The black box was\
                           probably left with undriven internal nets."
        }
    } elseif {[llength [fi__blackbox_insts]]} {
        fi__msg WARN "A10 not checked: no record of the black boxes' loaded outputs\
                      (they are taken in fi_pre_compile, i.e. on the RTL entry path)"
    }

    # -- A11: state off the chain starts every trial where the reference does --
    # With FI_CLEAR, the DUT reset puts back every register off the chain --
    # frozen, FI_EXEMPT, in an FI_SLOW_CLOCKS domain, a latch that stores data
    # -- so nothing a trial leaves in it survives into the next one. The other
    # FI_EXEMPT_CLOCKS domains are left to their own resets and not checked.
    if {$FI_CLEAR} {
        array set noclear {}
        foreach {ec xr} [fi__exempt_clock_regs] {
            if {[lsearch -exact $FI_SLOW_CLOCKS $ec] >= 0} { continue }
            foreach_in_collection r $xr { set noclear([lindex [get_object_name $r] 0]) 1 }
        }
        # the reset must put each one back: an asynchronous pin held at its
        # active level by FI_RST_PORT (fi__unreset_regs); a driver alone is not
        # enough (a tie cell, a clear such as `rst_ni || x`). FI_RESET_ACK lists
        # the ones a port accepts, each with a reason.
        array set ack [fi__reset_ack]
        set cand {}
        foreach_in_collection r [all_registers] {
            set n [lindex [get_object_name $r] 0]
            if {[info exists on_chain($n)] || [info exists is_cg($n)] || [info exists noclear($n)]
                || [fi__under $n $tool] || [info exists ack($n)]} { continue }
            # clock-gating cells hold nothing; a macro (a memory) is restored by its
            # FI model and must be frozen (A9)
            set lc [get_lib_cells -quiet -of_objects $r]
            if {[sizeof_collection $lc] && ([get_attribute -quiet $lc clock_gating_integrated_cell] ne ""
                                            || [get_attribute -quiet $lc is_macro_cell] eq "true")} { continue }
            lappend cand $n
        }
        set a11 {}
        if {[llength $cand]} { set a11 [fi__unreset_regs [get_cells $cand]] }
        if {[llength $a11]} {
            foreach n $a11 { puts "FI-UNRESET: $n" }
            lappend fails "A11 \[state-off-the-chain-is-reset\]  [llength $a11] register(s) off the chain are not\
                           put back by the DUT reset: whatever a trial leaves in them carries into the next one.\
                           Give each an asynchronous reset the DUT reset drives (fi_restore_clears does it for a\
                           clear the reset does not hold), or list it in FI_RESET_ACK with the reason it is\
                           harmless; a domain whose clock runs while the DUT is in reset belongs in\
                           FI_EXEMPT_CLOCKS and not in FI_SLOW_CLOCKS. [fi__group $a11]"
        }
    }

    # A6 and A7 are read under the shift condition (Scan_En = testmode = 1).
    # It is undone whatever happens in them: write_sdc would ship it.
    set shift_case [fi__shift_case_begin]
    set shift_rc [catch {

    # -- A6: every chain flop sees every shift edge ----------------------
    # Each chain clock path, walked back to its root, may hold only buffers,
    # inverters and clock gates the shift opens, and must start at
    # FI_CLK_PORT; a mux, a divider or a freeze cell costs shift edges. A chain
    # cell without a clock pin fails too.
    array set net_why {}
    array set net_bad {}
    array set gate_open {}
    set noclk {}
    foreach c $order {
        set cps [fi__clock_pins_of [get_cells $c]]
        if {![sizeof_collection $cps]} { lappend noclk $c ; continue }
        foreach_in_collection cp $cps {
            set key [fi__net_key $cp]
            if {![info exists net_why($key)]} {
                lassign [fi__clock_path $cp latches] root steps
                set why ""
                if {$root ne $FI_CLK_PORT} { append why " starts at '$root', not $FI_CLK_PORT;" }
                foreach st $steps {
                    set k [lindex $st 0]
                    if {$k eq "buf"} { continue }
                    if {$k eq "icg" || $k eq "lgate"} {
                        set g [lindex $st 1]
                        if {![info exists gate_open($g)]} { set gate_open($g) [fi__shift_opens $st] }
                        if {!$gate_open($g)} { append why " $k $g is not opened by the shift;" }
                    } elseif {$k eq "fi"} {
                        append why " behind the freeze [lindex $st 1];"
                    } else {
                        append why " $k [lindex $st 1] on the clock path;"
                    }
                }
                set net_why($key) $why
            }
            if {$net_why($key) ne ""} { lappend net_bad($key) $c }
        }
    }
    if {[llength $noclk]} {
        lappend fails "A6 \[chain-flops-see-every-shift-edge\]  [llength $noclk] chain cell(s) have no clock\
                       pin in the library. [fi__group $noclk]"
    }
    foreach key [array names net_bad] {
        lappend fails "A6 \[chain-flops-see-every-shift-edge\]  [llength $net_bad($key)] chain cell(s)\
                       on the clock net driven by {$key}:$net_why($key) [fi__group $net_bad($key)]"
    }

    # -- A7: the shift reaches no clock and no clear/set -----------------------
    # Chain outputs toggle while the chain shifts; under the shift condition
    # none may reach a register clock pin (chain, FI_EXEMPT and FI_EXEMPT_CLOCKS
    # registers) or any asynchronous clear/set pin. A reset synchroniser on the
    # chain is fine when testmode bypasses it. (An ICG has no arc from its
    # enable; gate enables are left to A6 and A8.)
    foreach {kind pins_of} {clock fi__clock_pins_of clear/set fi__async_pins_of} {
        array unset rep
        array unset regs
        foreach_in_collection r [all_registers] {
            set n [lindex [get_object_name $r] 0]
            if {$kind eq "clock" && !([info exists on_chain($n)] || [info exists on_xclk($n)]
                                      || ([fi__under $n $FI_EXEMPT] && ![info exists held($n)]
                                          && ![info exists is_cg($n)]))} { continue }
            foreach_in_collection p [$pins_of $r] {
                set k [fi__net_key $p]
                if {![info exists rep($k)]} { set rep($k) [get_object_name $p] }
                lappend regs($k) $n
            }
        }
        foreach k [array names rep] {
            set src {}
            foreach s [get_object_name [all_fanin -to [get_pins $rep($k)] -flat -startpoints_only]] {
                if {[info exists on_chain([file dirname $s])]} { lappend src [file dirname $s] }
            }
            if {[llength $src]} {
                set src [lsort -unique $src]
                lappend fails "A7 \[the-shift-reaches-no-clock-or-reset\]  the $kind net driven by {$k}\
                               ([llength $regs($k)] register(s)) is reachable from [llength $src] chain\
                               cell(s) with Scan_En = testmode = 1, e.g. [lrange $src 0 2]. Bypass the path\
                               in test mode, or take its source off the chain. [fi__group $regs($k)]"
            }
        }
    }
    } shift_err shift_opts]
    fi__shift_case_end $shift_case
    if {$shift_rc} { return -options $shift_opts $shift_err }

    # -- A8: nothing outside the chain runs on Scan_En ----------------------
    # A block neither shifted nor frozen keeps its clock through the window; a
    # clock gate of it that Scan_En or testmode can open would let it step where
    # it was gated. Exempt clock domains are checked too (they tick on the
    # first edge, where Scan_En rises).
    array set gate_reach {}
    set a8 {}
    foreach_in_collection r [all_registers] {
        set n [lindex [get_object_name $r] 0]
        if {[info exists on_chain($n)]} { continue }
        if {![info exists on_xclk($n)] && ![fi__under $n $FI_EXEMPT]} { continue }
        foreach_in_collection cp [fi__clock_pins_of $r] {
            lassign [fi__clock_path $cp latches] root steps
            foreach st $steps {
                set k [lindex $st 0]
                if {$k ne "icg" && $k ne "lgate"} { continue }
                set g [lindex $st 1]
                if {![info exists gate_reach($g)]} { set gate_reach($g) [fi__shift_reaches $st] }
                if {$gate_reach($g)} { lappend a8 $n }
            }
        }
    }
    set a8 [lsort -unique $a8]
    if {[llength $a8]} {
        lappend fails "A8 \[nothing-outside-the-chain-runs-on-scan-enable\]  [llength $a8] register(s) in\
                       FI_EXEMPT or FI_EXEMPT_CLOCKS sit behind a clock gate that Scan_En or testmode can open; they\
                       step during the window or on its first edge. Exclude the block from clock gating or freeze it. [fi__group $a8]"
    }

    # -- A12: the cells without a reset lead the chain ----------------
    # The scrub shifts zeros into FI_Index 0 .. K-1 and the DUT reset puts back
    # every other cell, so K = 1 + the largest FI_Index of a cell the reset does
    # not put back (fi__unreset_regs, the same test fi_dft_config ordered by).
    # That K is what the wrapper's scrub shifts (FI_SCRUB_LEN). With
    # FI_CHAIN_HEAD_NORESET those cells must be exactly the first K.
    array set at {}
    set i 0
    foreach c $order { set at($c) $i ; incr i }
    set unreset [fi__unreset_regs [get_cells $order]]
    set K 0
    foreach c $unreset { if {$at($c) + 1 > $K} { set K [expr {$at($c) + 1}] } }
    set FI_SCRUB_LEN $K
    if {$FI_CHAIN_HEAD_NORESET && $K != [llength $unreset]} {
        set late {}
        foreach c $unreset { if {$at($c) >= [llength $unreset]} { lappend late "$at($c):$c" } }
        lappend fails "A12 \[cells-without-reset-lead-the-chain\]  [llength $unreset] chain cell(s) have no\
                       reset the DUT reset drives, but they are not the first ones: the scrub would need\
                       K = $K shifts. Not first, e.g. [lrange $late 0 4]"
    }

    # -- verdict --------------------------------------------------
    set FI_SCAN_LEN $L
    set FI_CHECK_SUMMARY [list L $L scrub $K chain $n_chain frozen $n_frozen \
                               exempt_clk $n_xclk exempt_inst $n_exempt \
                               gate $n_tool clock_gate_latches $n_cg held_latches $n_held \
                               orphans [llength $orphans] w_idx $w_idx]
    fi__msg INFO "register partition: $FI_CHECK_SUMMARY"

    if {[llength $fails]} {
        foreach f $fails { fi__msg FAIL $f }
        # dc_shell's `source` goes on after a Tcl error: FI_CHECK_OK is what
        # keeps fi_export_scanmap from writing the config. The error is for
        # the log and for sh_continue_on_error false.
        fi__die "[llength $fails] scan invariant(s) violated -- see FI-FAIL above"
    }
    set FI_CHECK_OK 1
    fi__msg INFO "invariants OK: L=$L, scrub K=$K, $n_frozen flop(s) frozen, W_IDX=$w_idx"
}
