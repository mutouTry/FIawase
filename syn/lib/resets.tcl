# SPDX-License-Identifier: Apache-2.0
# Copyright 2025-2026 the FIawase authors
# What the DUT reset puts back, and clears for what it does not: fi__insert_clears (generic netlist,
# from fi_pre_compile) and fi_restore_clears (mapped).
# Sourced by syn/fi_scan_lib.tcl.

# The level at which an asynchronous pin forces its register and the value it
# forces Q to: {0 0} active-low clear, {0 1} active-low preset, {1 0}, {1 1};
# {} unknown. Read once per library cell in a scratch design (one instance,
# every pin on a port) by case analysis on every level combination of its
# asynchronous pins: the combination that leaves Q free has every pin
# inactive, and flipping one pin from there gives its level and effect.
# (is_clear_pin / is_preset_pin are not used: both are true on QN cells and
# latches.) Cached in FI_ASYNC_ACTIVE. The probe changes the current design,
# so callers pass names, not collections.
array set FI_ASYNC_ACTIVE {}
proc fi__async_probe_libcell {ref} {
    global FI_ASYNC_ACTIVE
    set top [get_object_name [current_design]]
    set lcs [get_lib_cells -quiet */$ref]
    if {![sizeof_collection $lcs]} { fi__die "no library cell $ref" }
    set lc [index_collection $lcs 0]
    set pins {} ; set asyn {} ; set q "" ; set qn ""
    foreach_in_collection lp [get_lib_pins -of_objects $lc] {
        set pn [get_attribute $lp name]
        lappend pins $pn [get_attribute $lp pin_direction]
        if {[get_attribute -quiet $lp is_async_pin] eq "true"} { lappend asyn $pn }
        if {$pn eq "Q"} { set q Q } elseif {$pn eq "QN"} { set qn QN }
    }
    foreach a $asyn { set FI_ASYNC_ACTIVE($ref/$a) {} }
    if {![llength $asyn] || ($q eq "" && $qn eq "")} { return }
    set d fi_probe_[regsub -all {[^A-Za-z0-9_]} $ref _]
    set f [file join [pwd] $d.v]
    set ports {} ; set decl {} ; set conn {}
    foreach {pn dir} $pins {
        lappend ports p_$pn
        lappend decl "  [expr {$dir eq "in" ? "input" : ($dir eq "out" ? "output" : "inout")}] p_$pn;"
        lappend conn ".${pn}(p_${pn})"
    }
    set fh [open $f w]
    puts $fh "module $d ([join $ports {, }]);\n[join $decl \n]\n  $ref u ([join $conn {, }]);\nendmodule"
    close $fh
    read_verilog -netlist $f
    current_design $d
    link
    set seq [get_app_var case_analysis_sequential_propagation]
    set_app_var case_analysis_sequential_propagation always
    set n [llength $asyn]
    set free {}
    for {set m 0} {$m < (1 << $n)} {incr m} {
        set i 0
        foreach a $asyn { set_case_analysis [expr {($m >> $i) & 1}] [get_ports p_$a] ; incr i }
        update_timing
        set v ""
        if {$q ne ""} { set v [get_attribute -quiet [get_pins u/Q] case_value] }
        if {$v ne "0" && $v ne "1" && $qn ne ""} {
            set w [get_attribute -quiet [get_pins u/QN] case_value]
            set v [expr {$w eq "0" ? 1 : ($w eq "1" ? 0 : "")}]
        }
        set qv($m) $v
        if {$v ne "0" && $v ne "1"} { lappend free $m }
        foreach a $asyn { remove_case_analysis [get_ports p_$a] }
    }
    set_app_var case_analysis_sequential_propagation $seq
    current_design $top
    remove_design $d
    file delete $f
    if {[llength $free] != 1} {
        fi__msg WARN "library cell $ref: [llength $free] level combinations of {$asyn} leave Q free, not 1 -- the\
                      polarity of its asynchronous pins is unknown"
        return
    }
    set m0 [lindex $free 0]
    set i 0
    foreach a $asyn {
        set m [expr {$m0 ^ (1 << $i)}]
        if {$qv($m) eq "0" || $qv($m) eq "1"} { set FI_ASYNC_ACTIVE($ref/$a) [list [expr {($m >> $i) & 1}] $qv($m)] }
        incr i
    }
}
# every library cell among the cells named that is not read yet
proc fi__async_active_all {names} {
    global FI_ASYNC_ACTIVE
    array set refs {}
    foreach n $names {
        set c [get_cells -quiet $n]
        if {[sizeof_collection $c]} { set refs([get_attribute $c ref_name]) 1 }
    }
    foreach r [array names refs] {
        set lcs [get_lib_cells -quiet */$r]
        if {![sizeof_collection $lcs]} { continue }
        set lc [index_collection $lcs 0]
        set todo 0
        foreach_in_collection lp [get_lib_pins -quiet -of_objects $lc] {
            if {[get_attribute -quiet $lp is_async_pin] eq "true" && ![info exists FI_ASYNC_ACTIVE($r/[get_attribute $lp name])]} { set todo 1 }
        }
        if {$todo} { fi__async_probe_libcell $r }
    }
}
proc fi__async_active {pinname} {
    global FI_ASYNC_ACTIVE
    set ref [get_attribute [get_cells [file dirname $pinname]] ref_name]
    set k $ref/[file tail $pinname]
    if {![info exists FI_ASYNC_ACTIVE($k)]} { fi__async_probe_libcell $ref }
    if {![info exists FI_ASYNC_ACTIVE($k)]} { return {} }
    return $FI_ASYNC_ACTIVE($k)
}

# The registers of $cells (a collection) that the DUT reset does not put back:
# none of their asynchronous pins is held at its active level by FI_RST_PORT.
# Case analysis with the reset at 0 and at 1 (Scan_En and testmode 0, as in the
# reset window), constants carried through registers so that a reset
# synchroniser passes the reset on. A pin is held when, with the reset active,
# it sits at its active level and differs with the reset released (a tied pin,
# or a clear such as `rst_ni || x`, is not held). A register with only a
# synchronous reset is returned too: on the chain the scrub clears it, off the
# chain A11 reports it.
proc fi__unreset_regs {cells} {
    global FI_RST_PORT FI_SCAN_EN_PORT FI_TESTMODE_PORT
    set apins {}
    set names {}
    foreach_in_collection c $cells {
        lappend apins [get_object_name $c] [get_object_name [fi__async_pins_of $c]]
        lappend names [get_object_name $c]
    }
    fi__async_active_all $names
    set ports {}
    foreach pn [lsort -unique [list $FI_RST_PORT $FI_SCAN_EN_PORT $FI_TESTMODE_PORT]] {
        if {[sizeof_collection [get_ports -quiet $pn]]} { lappend ports $pn }
    }
    if {[lsearch -exact $ports $FI_RST_PORT] < 0} { fi__die "reset port '$FI_RST_PORT' not found" }
    update_timing
    set saved {}
    foreach pn $ports { lappend saved $pn [get_attribute -quiet [get_ports $pn] case_value] }
    set seq [get_app_var case_analysis_sequential_propagation]
    set_app_var case_analysis_sequential_propagation always
    foreach lvl {0 1} {
        foreach pn $ports {
            set_case_analysis [expr {$pn eq $FI_RST_PORT ? $lvl : 0}] [get_ports $pn]
        }
        update_timing
        foreach {c ps} $apins {
            foreach p $ps { set v${lvl}($p) [get_attribute -quiet [get_pins $p] case_value] }
        }
    }
    set_app_var case_analysis_sequential_propagation $seq
    fi__shift_case_end $saved
    set out {}
    foreach {c ps} $apins {
        set held 0
        foreach p $ps {
            set a [fi__async_active $p]
            if {[llength $a] && $v0($p) eq [lindex $a 0] && $v0($p) ne $v1($p)} { set held 1 }
        }
        if {!$held} { lappend out $c }
    }
    return $out
}

# FI_RESET_ACK {instance reason ...}: registers off the chain that the DUT
# reset does not put back, accepted by the port with a reason (e.g. a reset-
# cause register set by a watchdog). fi_restore_clears and A11 leave them.
proc fi__reset_ack {} {
    global FI_RESET_ACK
    if {[llength $FI_RESET_ACK] % 2} { fi__die "FI_RESET_ACK must be {instance reason ...}" }
    array set ack {}
    foreach {n why} $FI_RESET_ACK {
        set cs [get_cells -quiet $n]
        if {![sizeof_collection $cs]} { fi__die "FI_RESET_ACK: no cell $n" }
        if {[string trim $why] eq ""} { fi__die "FI_RESET_ACK: $n needs a reason" }
        foreach_in_collection c $cs { set ack([get_object_name $c]) $why }
    }
    return [array get ack]
}

# The registers off the chain whose state the next trial would inherit if
# nothing restored it (as fi__insert_clears picks them: under a frozen
# instance, in FI_EXEMPT, in an FI_SLOW_CLOCKS domain, a latch that stores
# data; not the other FI_EXEMPT_CLOCKS domains), with an asynchronous pin, on
# a mapped netlist. Latches that store data are those behind a latch hold.
proc fi__offchain_async_regs {} {
    global FI_FREEZE FI_GATE_PINS FI_EXEMPT FI_SLOW_CLOCKS
    set owners $FI_EXEMPT
    foreach x [concat $FI_FREEZE $FI_GATE_PINS] {
        lappend owners [expr {[sizeof_collection [get_pins -quiet $x]] ? [file dirname $x] : $x}]
    }
    array set slow {}
    array set skip {}
    foreach {c xr} [fi__exempt_clock_regs] {
        set kind [expr {[lsearch -exact $FI_SLOW_CLOCKS $c] >= 0 ? "slow" : "skip"}]
        foreach_in_collection r $xr { set ${kind}([get_object_name $r]) 1 }
    }
    array set store {}
    foreach hc [fi__hold_cells] {
        foreach_in_collection lp [get_pins -quiet -leaf -of_objects [get_nets -quiet -segments -of_objects [get_pins -quiet $hc/en_o]] -filter "pin_direction == in"] {
            set store([get_object_name [get_cells -of_objects $lp]]) 1
        }
    }
    set out {}
    foreach_in_collection r [all_registers] {
        set n [get_object_name $r]
        if {[info exists skip($n)]} { continue }
        set lc [get_lib_cells -quiet -of_objects $r]
        if {![sizeof_collection $lc]} { continue }
        if {[get_attribute -quiet $lc clock_gating_integrated_cell] ne "" || [get_attribute -quiet $lc is_macro_cell] eq "true"} { continue }
        if {![sizeof_collection [fi__async_pins_of $r]]} { continue }
        if {[info exists slow($n)] || [info exists store($n)] || [fi__under $n $owners]} { lappend out $n }
    }
    return $out
}

# Clears for the registers off the chain whose asynchronous pins the DUT reset
# does not hold (e.g. a clear written `rst_ni || x`); fi__insert_clears covers
# the ones with none. On the mapped netlist, where a pin's polarity is known:
# FI_RST_PORT is and-ed into an active-low clear (or-ed, inverted, into an
# active-high one), one GTECH gate per driving net; compile_ultra -scan maps
# it, and with the reset released it passes the DUT's own drive. A register
# with a preset, or a pin of unknown polarity, stops the run unless
# FI_RESET_ACK lists it. Every spliced register must then be held.
proc fi_restore_clears {} {
    global FI_RST_PORT FI_CLEAR
    if {!$FI_CLEAR} { fi__msg INFO "restore clears: off (FI_CLEAR 0)" ; return }
    set top [get_object_name [current_design]]
    array set ack [fi__reset_ack]
    set regs [fi__offchain_async_regs]
    if {![llength $regs]} { fi__msg INFO "restore clears: no register off the chain with an asynchronous pin" ; return }
    set un [fi__unreset_regs [get_cells $regs]]
    set todo {} ; set acked {} ; set bad {}
    foreach n $un {
        if {[info exists ack($n)]} { lappend acked $n ; continue }
        # only registers whose asynchronous pins are all clears: with a preset, or a pin of unknown polarity, the
        # value the reset should give them is not known
        set cp {}
        set other 0
        foreach pn [get_object_name [fi__async_pins_of [get_cells $n]]] {
            set a [fi__async_active $pn]
            if {[llength $a] && [lindex $a 1] == 0} { lappend cp $pn [lindex $a 0] } else { set other 1 }
        }
        if {[llength $cp] && !$other} { lappend todo $n $cp } else { lappend bad $n }
    }
    if {[llength $bad]} {
        foreach n $bad { puts "FI-UNRESET: $n" }
        fi__die "restore clears: [llength $bad] register(s) off the chain (FI-UNRESET lines above) are not put back\
                 by the DUT reset, and not every asynchronous pin of theirs is a clear one can be added to: give them\
                 a reset in the DUT, or list each in FI_RESET_ACK with the reason it may keep its state across\
                 trials. [fi__group $bad]"
    }
    set k 0
    array set gate {}
    set spliced {}
    foreach {n cp} $todo {
        foreach {pn lvl} $cp {
            set p [get_pins $pn]
            set old [all_connected $p]
            set par [file dirname [file dirname $pn]]
            set key "[get_object_name $old]@$par/$lvl"
            if {![info exists gate($key)]} {
                set pre [expr {$par eq "." ? "" : "$par/"}]
                set g ${pre}fi_rc_$k ; incr k
                if {$lvl == 0} {
                    create_cell $g gtech/GTECH_AND2
                    connect_pin -from [get_ports $FI_RST_PORT] -to [get_pins $g/B] -port_name fi_rc_rst_n
                } else {
                    create_cell $g gtech/GTECH_OR2
                    set gi ${pre}fi_rc_$k ; incr k
                    create_cell $gi gtech/GTECH_NOT
                    connect_pin -from [get_ports $FI_RST_PORT] -to [get_pins $gi/A] -port_name fi_rc_rst_n
                    connect_pin -from [get_pins $gi/Z] -to [get_pins $g/B]
                }
                connect_net $old [get_pins $g/A]
                set gate($key) $g
            }
            set g $gate($key)
            disconnect_net $old $p
            connect_pin -from [get_pins $g/Z] -to $p
        }
        lappend spliced $n
    }
    current_design $top
    link
    if {[llength $spliced]} {
        set still [fi__unreset_regs [get_cells $spliced]]
        if {[llength $still]} { fi__die "restore clears: still not put back after the splice: [fi__group $still]" }
    }
    fi__msg INFO "restore clears: [llength $regs] register(s) off the chain with an asynchronous pin;\
                  [llength $spliced] not put back by the DUT reset now get $FI_RST_PORT on their clear\
                  ([array size gate] gate(s)); [llength $acked] accepted by FI_RESET_ACK.\
                  [fi__group $spliced]"
    foreach n $spliced { puts "FI-RESTORE-CLEAR: $n" }
    foreach n $acked { puts "FI-RESET-ACK: $n -- $ack($n)" }
}

# Clears for the state nothing else restores (FI_CLEAR; generic netlist). At a
# trial start the chain is restored by the scrub, the memories by their restore
# and every register with a reset by the DUT reset; a register off the chain
# with no clear or preset of any kind keeps what the last trial left, while the
# reference starts it at 0. fi_clear (one cell at the top, fed by FI_RST_PORT)
# clears it at power-on and at every trial start.
#   off the chain:  under a frozen instance, in FI_EXEMPT, in an FI_SLOW_CLOCKS
#                   domain, or a latch that stores data
#   left alone:     the other FI_EXEMPT_CLOCKS domains (their clock may run
#                   while the DUT is in reset), latches that gate a clock,
#                   registers with a synchronous reset
proc fi__insert_clears {store} {
    global FI_CLEAR FI_CLEAR_MODULE FI_CLEAR_INST FI_RST_PORT FI_GATE_SRC
    global FI_FREEZE FI_GATE_PINS FI_EXEMPT FI_EXEMPT_CLOCKS FI_SLOW_CLOCKS
    if {!$FI_CLEAR} { return }
    set top [get_object_name [current_design]]
    foreach c $FI_SLOW_CLOCKS {
        if {[lsearch -exact $FI_EXEMPT_CLOCKS $c] < 0} { fi__die "FI_SLOW_CLOCKS: $c is not one of FI_EXEMPT_CLOCKS" }
    }
    set owners $FI_EXEMPT
    foreach x [concat $FI_FREEZE $FI_GATE_PINS] {
        lappend owners [expr {[sizeof_collection [get_pins -quiet $x]] ? [file dirname $x] : $x}]
    }
    array set slow {}
    array set skip {}
    foreach {c xr} [fi__exempt_clock_regs] {
        set kind [expr {[lsearch -exact $FI_SLOW_CLOCKS $c] >= 0 ? "slow" : "skip"}]
        foreach_in_collection r $xr { set ${kind}([get_object_name $r]) 1 }
    }
    # generic registers only: a memory macro has its own restore (the FI memory
    # models), and anything else A11 reports
    set regs {}
    foreach_in_collection r [all_registers -edge_triggered] {
        set n [get_object_name $r]
        if {[get_attribute -quiet $r ref_name] ne "**SEQGEN**"} { continue }
        if {![info exists skip($n)] && ([info exists slow($n)] || [fi__under $n $owners])} { lappend regs $n }
    }
    foreach n $store { if {![info exists skip($n)]} { lappend regs $n } }
    set pins {}
    set cleared {}
    foreach n $regs {
        set none 1
        foreach pn {clear preset synch_clear synch_preset} {
            set p [get_pins -quiet $n/$pn]
            if {[sizeof_collection $p] && ![string match "*Logic0*" [get_object_name [all_connected $p]]]
                && [get_object_name [all_connected $p]] ne ""} { set none 0 }
        }
        if {!$none} { continue }
        set p [get_pins -quiet $n/clear]
        if {![sizeof_collection $p]} { fi__die "FI_CLEAR: $n has no generic clear pin" }
        lappend pins [get_object_name $p]
        lappend cleared $n
    }
    if {![llength $pins]} { fi__msg INFO "clears: no register off the chain is without a reset" ; return }
    if {[sizeof_collection [get_designs -quiet $FI_CLEAR_MODULE]] == 0} {
        analyze -format verilog $FI_GATE_SRC
        elaborate $FI_CLEAR_MODULE
        current_design $top
        link
    }
    create_cell $FI_CLEAR_INST $FI_CLEAR_MODULE
    connect_net [fi__port_net $FI_RST_PORT] [get_pins $FI_CLEAR_INST/rst_ni]
    foreach p $pins {
        set pp [get_pins $p]
        set old [all_connected $pp]
        if {[sizeof_collection $old]} { disconnect_net $old $pp }
    }
    connect_pin -from [get_pins $FI_CLEAR_INST/clear_o] -to [get_pins $pins] -port_name fi_clear
    set bad {}
    foreach p $pins {
        lassign [fi__drivers [get_pins $p]] d pt
        if {[sizeof_collection $d] != 1 || ![fi__under [get_object_name $d] [list $FI_CLEAR_INST]]} { lappend bad $p }
    }
    if {[llength $bad]} {
        fi__die "FI_CLEAR: [llength $bad] clear pin(s) not driven by $FI_CLEAR_INST after the splice, e.g. [lrange $bad 0 2]"
    }
    current_design $top
    link
    fi__msg INFO "clears: [llength $cleared] register(s) off the chain without a reset now cleared by\
                  $FI_RST_PORT through $FI_CLEAR_INST. [fi__group $cleared]"
}
