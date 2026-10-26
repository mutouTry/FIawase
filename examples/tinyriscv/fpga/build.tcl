# SPDX-License-Identifier: Apache-2.0
# Copyright 2025-2026 the FIawase authors
# Vivado batch build of the example FI system for the Genesys2 (xc7k325tffg900-2), non-project mode.
# usage: vivado -mode batch -source build.tcl -tclargs <gen dir> <cell models.v> <FICE models.v> <out dir>
#   gen dir     prep.sh's output: the converted netlist, its memory glue, fi_scan_cfg.vh, rom.hex
#   cell models FPGA-synthesizable models of the standard cells, and of their <cell>_FICE flops
# Writes to <out dir>: reports (utilization by hierarchy, timing, methodology, DRC), the checkpoints
# and fpga_top.bit.
lassign $argv GEN CELLS FICE OUT
set E [file dirname [file normalize [info script]]]
set R [file normalize $E/../../..]
set F $R/fpga
set_param general.maxThreads 4
file mkdir $OUT

read_verilog $CELLS $FICE $GEN/tinyriscv_soc_top.fpga.v \
             $F/rtl/fi_sram_fpga.v $E/fi_sram_example.v $F/rtl/fi_board_uart.v $E/uart_rx_tap.v
foreach f {fi_wrapper_top fi_transporter fi_executor fi_executor_core fi_time_ctrl fi_scan_ctrl fi_table_ctrl fi_table} {
    read_verilog $R/rtl/$f.v
}
read_verilog $E/fpga_top.v
read_xdc $E/genesys2.xdc

synth_design -top fpga_top -part xc7k325tffg900-2 \
    -include_dirs [list $GEN $E $R/rtl] \
    -verilog_define [list FI_ROM_INIT=\"$GEN/rom.hex\"]
write_checkpoint -force $OUT/post_synth.dcp
report_utilization -file $OUT/util_synth.rpt
opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force $OUT/post_route.dcp
report_utilization -file $OUT/util.rpt
report_utilization -hierarchical -hierarchical_depth 4 -file $OUT/util_hier.rpt
report_timing_summary -max_paths 20 -file $OUT/timing.rpt
report_clock_utilization -file $OUT/clock_util.rpt
report_methodology -file $OUT/methodology.rpt
report_drc -file $OUT/drc.rpt
write_bitstream -force $OUT/fpga_top.bit
puts "FPGA-BUILD: done $OUT/fpga_top.bit"
