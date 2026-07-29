# SPDX-License-Identifier: Apache-2.0
# Copyright 2025-2026 the FIawase authors
# ============================================================
# Load the FI table, program the FI config and start FI through the
# FI wrapper private DMI window (base 0x60).
# ------------------------------------------------------------
# Requires: source tapename.tcl
#           (provides fi_dmi_write / fi_entry / fi_pattern)
#
# Optional probes (fi_idcode / fi_dmi_read) live in tapename.tcl and
# can be typed by hand at the telnet prompt; they are NOT used here.
# ============================================================

# 1) cutover into FI mode and point the FI Table loader at word 0.
proc fi_mode_and_loader {} {
    fi_dmi_write 0x60 0x00000001
    echo "-> FI_MODE = 1"
    sleep 100

    # 0x70 = TBL_CTRL, bit0 = AUTOINC
    fi_dmi_write 0x70 0x00000001
    echo "-> TBL_CTRL AUTOINC = 1"

    # 0x71 = TBL_ADDR start pointer
    fi_dmi_write 0x71 0x00000000
    echo "-> TBL_ADDR = 0"
}

# 3) program the config and arm the loop. $n is the entry count that the
# fi_pattern calls returned.
#
# The order here is not free:
#   - CFG_TO_THR must be LAST. It is the source of to_hit_en and it
#     compares with >=, so the moment it lands clock_counter is already
#     far past it -> immediate first stop -> reset window -> resolver_rst
#     rise (cfg_en_able=1) -> resolver_rst fall (table prefetch starts) ->
#     counter cleared -> first injection at CLK_FI.
#   - CFG_TBL_LEN and CFG_FI_CYCLE must therefore be in before it.
#   - Writing CFG_FI_CYCLE also RE-ARMS the running FI_Cycle accumulator
#     (write strobe, so rewriting the same value still resets a sweep).
proc fi_config_and_arm {n {clk_fi 0x000073F0} {clk_to 0x00080000}} {
    global FI_SCAN_LEN

    fi_dmi_write 0x62 0x00000001   ;# CFG0: AUTO=1, END=0
    echo "-> CFG0"

    # CFG_SCAN_LEN must equal the real scan chain length of the netlist that is
    # compiled into the simulation, or the chain is not restored and the
    # DUT dies on the first injection.
    #
    # FI_SCAN_LEN comes from tapename.tcl. Synthesis emits the matching
    # value in syn/results/fi_scan_cfg.tcl (fi_export_scanmap);
    # copy that file here, or paste the number into tapename.tcl, every
    # time the netlist is regenerated. Runs differ: 4721 / 4727 / 5025
    # have all been seen, and moving blocks off the chain moves it again.
    #
    # It does NOT affect the table encoding -- that is fixed by FI_W_IDX.
    fi_dmi_write 0x63 $FI_SCAN_LEN ;# LEN
    echo "-> CFG_SCAN_LEN = $FI_SCAN_LEN"

    fi_dmi_write 0x64 0x00000000   ;# WRCNT = 0 (static single-flip path off)
    echo "-> CFG_FI_INDEX"

    # CFG_TBL_LEN is how the hardware finds the end of the table. There is
    # no end-of-table sentinel any more: 0x00000000 is a legal FI_Entry
    # (EOP=0, Cycle_Offset=0, FI_Index=0). Its reset value is 0, so forgetting this
    # write means nothing is ever injected -- deliberately a visible
    # failure rather than a wrong one.
    fi_dmi_write 0x68 $n
    echo "-> CFG_TBL_LEN = $n"

    fi_dmi_write 0x65 $clk_fi      ;# CLK_FI base target cycle
    echo "-> CFG_FI_CYCLE = $clk_fi"

    fi_dmi_write 0x66 $clk_to      ;# CLK_TO
    echo "-> CFG_TO_THR = $clk_to"

    # CFG_TO_THR is the write that actually arms the loop, and being the
    # last write it has no successor transaction to clock it across the
    # CDC. Without this flush it stays pending until something else
    # touches JTAG - an OpenOCD poll, or a manually typed fi_idcode.
    fi_dmi_flush
    echo "-> flushed"
}

# ============================================================
# fi_campaign -- any cycle, any set of bits. The only entry point.
# ============================================================
# A campaign is a list of
# trials, and one trial is
#
#     { <FI_Cycle> { <FI_Index> ... } }
#
# an ABSOLUTE injection cycle -- the same scale as fi_exec_window.txt,
# counted from reset release -- and the set of flops to flip in it. One
# trial is ONE scan pass, so an n-bit upset costs L shifts, not n*L.
#
#   fi_campaign {
#       {  30000 {2354} }               ;# SBU, early in the program
#       {  90000 {2354} }               ;# the same flop, later
#       {  90000 {2354 2355 2356} }     ;# MBU-3 at that same cycle
#       { 150000 {17 600 4100} }        ;# MBU-3, scattered across the chain
#   }
#
# What it derives, which is the whole reason it exists:
#   CFG_FI_CYCLE   the earliest cycle in the list
#   Cycle_Offset   the gap to the next trial. The hardware only has a
#                  non-negative increment applied AFTER a trial, so
#                  absolute cycles are what you want to think in and
#                  increments are what the table has to store.
#   entry order    descending FI_Index inside each pattern, or the
#                  hardware sets err_order and drops targets
#   CFG_TBL_LEN    the entry count, which has no sentinel
#   CFG_TO_THR     long enough for the last trial
#
# Trials are sorted by cycle. Two trials at the same cycle stay two
# trials -- two resets, two program runs -- which is how you compare an
# SBU against an MBU at the same instant. To flip bits TOGETHER, put
# them in one trial.
#
# Limits, all checked before anything is written to the hardware:
#   FI_Index      0 .. 2**FI_W_IDX-1, and > FI_SCAN_LEN never flips
#   Cycle_Offset  0 .. 2**(31-FI_W_IDX)-1 between consecutive trials
#   entries       <= the FI Table depth (TBL_WORDS in fi_wrapper_top)
#
# to_thr is the length of EVERY trial and defaults to something that
# clears both the last injection and this workload's UART tail. Pass it
# explicitly for a longer program.
proc fi_campaign {trials {to_thr 0}} {
    global FI_W_IDX FI_SCAN_LEN

    set max_off   [expr {(1 << (31 - $FI_W_IDX)) - 1}]
    set max_idx   [expr {(1 << $FI_W_IDX) - 1}]
    set tbl_words 256

    if {[llength $trials] == 0} {
        error "fi_campaign: empty campaign"
    }
    if {![string is integer -strict $to_thr] || $to_thr < 0} {
        error "fi_campaign: to_thr must be a non-negative integer, got '$to_thr'"
    }
    # Normalise 0x... to decimal so the comparison below, the summary line
    # and the DMI write all agree on one form.
    set to_thr [expr {$to_thr}]

    # --- normalise and validate BEFORE touching the hardware ---------
    # A half-loaded table is worse than a refused one: CFG_TBL_LEN would
    # still be written and the run would look legitimate.
    set norm   {}
    set nentry 0
    foreach t $trials {
        if {[llength $t] != 2} {
            error "fi_campaign: a trial is {<cycle> {<FI_Index> ...}}, got '$t'"
        }
        set cyc [lindex $t 0]
        set idx [lsort -integer -decreasing -unique [lindex $t 1]]
        if {![string is integer -strict $cyc] || $cyc < 0} {
            error "fi_campaign: cycle must be a non-negative integer, got '$cyc'"
        }
        if {[llength $idx] == 0} {
            error "fi_campaign: the trial at cycle $cyc flips nothing"
        }
        foreach p $idx {
            if {![string is integer -strict $p] || $p < 0 || $p > $max_idx} {
                error "fi_campaign: FI_Index '$p' outside 0..$max_idx (FI_W_IDX = $FI_W_IDX)"
            }
            if {$p > $FI_SCAN_LEN} {
                echo "fi_campaign: WARNING FI_Index $p is past the end of the chain ($FI_SCAN_LEN); that entry flips nothing"
            }
        }
        incr nentry [llength $idx]
        lappend norm [list $cyc $idx]
    }
    set norm [lsort -integer -index 0 $norm]
    set n_tr [llength $norm]

    if {$nentry > $tbl_words} {
        error "fi_campaign: $nentry entries exceeds the FI Table depth ($tbl_words). Split the campaign."
    }

    for {set k 0} {$k < $n_tr - 1} {incr k} {
        set gap [expr {[lindex [lindex $norm [expr {$k + 1}]] 0] -
                       [lindex [lindex $norm $k] 0]}]
        if {$gap > $max_off} {
            error "fi_campaign: the $gap-cycle gap between trial [expr {$k + 1}] and [expr {$k + 2}] exceeds the Cycle_Offset field ($max_off). Split the campaign."
        }
    }

    set base [lindex [lindex $norm 0]   0]
    set last [lindex [lindex $norm end] 0]

    if {$to_thr == 0} {
        set to_thr [expr {0x00080000}]
        if {$last + 0x00040000 > $to_thr} {
            set to_thr [expr {$last + 0x00040000}]
        }
    }
    if {$last >= $to_thr} {
        error "fi_campaign: the last injection cycle $last is at or past CFG_TO_THR $to_thr, so that trial would end before its injection"
    }

    # --- load --------------------------------------------------------
    fi_mode_and_loader
    echo [format "  %-5s %10s %10s  %s" trial cycle offset FI_Index]
    set n 0
    for {set k 0} {$k < $n_tr} {incr k} {
        set cyc [lindex [lindex $norm $k] 0]
        set idx [lindex [lindex $norm $k] 1]
        if {$k < $n_tr - 1} {
            set off [expr {[lindex [lindex $norm [expr {$k + 1}]] 0] - $cyc}]
        } else {
            set off 0
        }
        incr n [fi_pattern $off $idx]
        echo [format "  %-5d %10d %10d  %s" [expr {$k + 1}] $cyc $off $idx]
    }
    echo "-> $n_tr trials, $n entries, cycles $base .. $last, CFG_TO_THR $to_thr"

    fi_config_and_arm $n $base $to_thr
}

# One multi-bit upset at one cycle: the single-shot form of fi_campaign.
#   fi_mbu 90000 {2354 2355 2356}
proc fi_mbu {cycle indexlist} {
    fi_campaign [list [list $cycle $indexlist]]
}

# Read back everything that matters after arming. Response lags by one
# transaction, hence the double reads.
proc fi_status_dump {} {
    echo "FI_VERSION   [fi_dmi_read 0x6F] [fi_dmi_read 0x6F]"
    echo "CFG_SCAN_LEN [fi_dmi_read 0x63] [fi_dmi_read 0x63]"
    echo "CFG_TBL_LEN  [fi_dmi_read 0x68] [fi_dmi_read 0x68]"
    echo "CFG_FI_CYCLE [fi_dmi_read 0x65] [fi_dmi_read 0x65]"
    echo "FI_CYCLE     [fi_dmi_read 0x69] [fi_dmi_read 0x69]"
    echo "FI_STATUS    [fi_dmi_read 0x61] [fi_dmi_read 0x61]"
}
