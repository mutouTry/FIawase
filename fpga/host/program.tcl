# SPDX-License-Identifier: Apache-2.0
# Copyright 2025-2026 the FIawase authors
# Load a bitstream into the Genesys2 over J17 (Vivado hardware manager, batch).
# usage: vivado -mode batch -nojournal -nolog -source program.tcl -tclargs <file.bit>
#
# hw_server lists J17's FT2232H as two targets: Digilent/<serial> is port A (PROG_D0..7, the host
# JTAG; no FPGA there, and with the bitstream loaded it sees the DUT's TAP instead) and
# Digilent/<serial>B is port B, the FPGA's configuration JTAG. The first target is not always port
# B, so use the target that has the xc7k325t, trying the ...B ones first.
set bit [lindex $argv 0]
open_hw_manager
connect_hw_server
set ts [get_hw_targets]
set ts [concat [lsearch -all -inline $ts *B] [lsearch -all -inline -not $ts *B]]
set dev ""
foreach t $ts {
    if {[catch {open_hw_target $t}]} { continue }
    set dev [lindex [get_hw_devices -quiet xc7k325t*] 0]
    if {$dev ne ""} { puts "TARGET $t"; break }
    close_hw_target $t
}
if {$dev eq ""} { error "no xc7k325t on any JTAG target ($ts): is the board on and J17 connected?" }
current_hw_device $dev
set_property PROGRAM.FILE $bit $dev
program_hw_devices $dev
puts "PROGRAMMED $bit"
close_hw_target
disconnect_hw_server
close_hw_manager
