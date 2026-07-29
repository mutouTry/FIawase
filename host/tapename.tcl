# SPDX-License-Identifier: Apache-2.0
# Copyright 2025-2026 the FIawase authors
# ============================================================
# Access primitives for the FI wrapper private DMI window
# ============================================================
# TAPNAME must match exactly the tap created by fi_openocd.cfg:
#     jtag newtap $_CHIPNAME tap ...
# CHIPNAME defaults to "riscv", so the full tap name is "riscv.tap".
# If it does not match, irscan fails with "Tap '<name>' could not be
#  found" -- that is the symptom of editing one file and not the other.
set TAPNAME riscv.tap
# The FI wrapper TAP deliberately mirrors the RISC-V DTM IR contract:
#   IDCODE = 0x01, DTMCS = 0x10, DMI = 0x11, irlen = 5
# so OpenOCD needs no reconfiguration across the FI cutover.
proc fi_ir_dmi {} {
    global TAPNAME
    irscan $TAPNAME 0x11
}

# The DMI DR is 41 bits: {addr[6:0], data[31:0], op[1:0]}.
# drscan fields are given in shift-in order, so op comes first.
#   op: 0 = NOP, 1 = READ, 2 = WRITE
#
# NOTE on the trailing "runtest 8": it is one TCK edge short. Counting
# rising edges after the TAP reaches UPDATE_DR (fi_transporter.v):
#   n+1  tap_req_q <= 1                      (fi_jtag_tap)
#   n+2  DTM S_IDLE -> S_SEND                (fi_jtag_dtm_v6)
#   n+3  DTM S_SEND -> S_WAIT_RESP, req_pulse_q <= 1
#   n+4  u_cdc_req src side samples src_valid_i, src_toggle_q flips
#        <- only here does the request leave the TCK domain
# n+1 is the last edge of the drscan itself, so RUN/IDLE still owes the
# request 3 more edges and only gets 2. req_pulse_q is a held register,
# so nothing is lost: each write simply waits until the next JTAG
# transaction clocks TCK again. Writes therefore land one transaction
# late, which is harmless in the middle of a sequence but leaves the
# LAST write of a sequence hanging forever. Hence fi_dmi_flush below.
proc fi_dmi_write {addr data} {
    global TAPNAME
    fi_ir_dmi
    drscan $TAPNAME 2 0x2 32 $data 7 $addr -endstate RUN/IDLE
    runtest 8
}

# Push the last pending write across the TCK->AON CDC.
# A DMI NOP is the cheapest safe way to do this: fi_jtag_dtm_v6 gates
# request capture on req_is_active_w = (op==READ)||(op==WRITE), so a NOP
# packet never enters the DTM state machine at all. It only supplies the
# ~50 TCK edges the pending request is waiting for.
proc fi_dmi_flush {} {
    global TAPNAME
    fi_ir_dmi
    drscan $TAPNAME 2 0x0 32 0 7 0 -endstate RUN/IDLE
    runtest 8
}

# A read takes two scans: the first issues the READ request, then we
# idle so the DTM can get the response across the CDC, and the second
# scan (NOP) captures the result.
# Returns {status data addr}; status 0 = OK, 2 = FAIL, 3 = BUSY.
#
# NOTE on the idle count. This used to be "runtest 80", which sits
# squarely in the range that hangs telnet + OpenOCD: 2 and 8 are known
# good, 80 and 100 kill the session. The mechanism is unexplained; this
# value is empirical, not understood. That made
# fi_dmi_read a trap that took the session down on the first status
# read-back, which is what it looks like when "reads during FI do not
# work".
#
# Idling less is harmless here: the response lags by one transaction
# regardless (A.1.6), which is exactly why the documented usage is to
# read the same address twice and keep the second result.
# fi_status_dump already does that.
proc fi_dmi_read {addr} {
    global TAPNAME
    fi_ir_dmi
    drscan $TAPNAME 2 0x1 32 0 7 $addr -endstate RUN/IDLE
    runtest 8
    set r [drscan $TAPNAME 2 0x0 32 0 7 0 -endstate RUN/IDLE]
    runtest 8
    return $r
}

# ============================================================
# FI_Entry encoding
# ============================================================
# One 32-bit table word:
#
#   bit  31 30                W_IDX W_IDX-1      0
#       +---+--------------------+--------------+
#       |EOP|    Cycle_Offset    |   FI_Index   |
#       +---+--------------------+--------------+
#
#   EOP          1 = last entry of this replay pattern
#   Cycle_Offset ONLY read from the EOP entry: non-negative increment
#                added to FI_Cycle after this pattern's trial finishes.
#                Entries of patterns that stay on the same cycle put 0.
#   FI_Index     tail-relative scan position. The hardware flips at
#                shift step L-1-FI_Index, so FI_Index 0 = no flip.
#
# One pattern = ONE scan pass that flips all of its bits, so all of a
# pattern's entries are consumed inside a single L-cycle shift loop.
#
# FI_W_IDX must match the RTL's $clog2(N_FF)
# (rtl/fi/fi_scan_cfg.vh: FI_N_FF = 8192 -> 13). It is a power
# of two on purpose, so re-synthesis moving L around does not move the
# field boundaries. Read DMI 0x6F (FI_VERSION) to confirm the wrapper
# speaks this format: 0x00020000 = EOP/Cycle_Offset, 0x00010000 = the
# older {N[31:24], FI_Index[23:0]}.
#
# FI_SCAN_LEN is the measured chain length of the netlist in the sim
# tree; fi_config_and_arm writes it to CFG_SCAN_LEN (DMI 0x63). Unlike
# FI_W_IDX it changes on every re-synthesis, and getting it wrong means
# the chain is not restored -- the DUT dies on the first injection.
#
# Both values are emitted by synthesis into
#   syn/results/fi_scan_cfg.tcl
# (fi_scan_lib.tcl / fi_export_scanmap). Copy that file over these two
# lines after every `make dc` + scanchain.tcl run. The flop names behind
# each FI_Index are in results/fi_scanmap.txt.
set FI_W_IDX    13
set FI_SCAN_LEN 4143

proc fi_entry {eop off fi_index} {
    global FI_W_IDX
    return [format 0x%08X [expr {($eop << 31) | ($off << $FI_W_IDX) | $fi_index}]]
}

# Emit one whole replay pattern and return how many entries it used.
#   off       : Cycle_Offset applied to FI_Cycle after this pattern's trial
#   indexlist : the FI_Index values to flip together, in any order
#
# The hardware walks run_cnt upwards, so a pattern's entries must arrive
# in DESCENDING FI_Index (= ascending shift step). Sorting here is what
# keeps that invariant: getting it wrong sets FI_STATUS bit2 (err_order)
# and silently drops the out-of-order targets. Duplicates are removed
# for the same reason.
proc fi_pattern {off indexlist} {
    set sorted [lsort -integer -decreasing -unique $indexlist]
    set n [llength $sorted]
    set k 0
    foreach p $sorted {
        incr k
        if {$k == $n} {
            fi_dmi_write 0x72 [fi_entry 1 $off $p]
        } else {
            fi_dmi_write 0x72 [fi_entry 0 0 $p]
        }
    }
    return $n
}

# Read the IDCODE of whichever TAP currently owns TDO. This is the most
# reliable way to tell whether the FI cutover has happened:
#   before cutover = 1e200a6f  (the DUT's own TAP)
#   after  cutover = f17e0006  (the FI wrapper TAP)
proc fi_idcode {} {
    global TAPNAME
    irscan $TAPNAME 0x01
    set r [drscan $TAPNAME 32 0 -endstate RUN/IDLE]
    runtest 8
    return $r
}
