#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2025-2026 the FIawase authors
# The inputs of the Vivado build (build.tcl): the netlist with its clock gates turned into clock enables
# and its memories' restore wires (fi_fpga_ce.py), the netlist's fi_scan_cfg.vh, and the program image
# as the ROM's power-on content. uart0's TX before the pin mux (uart_tx[0]) comes out as
# fi_obs_uart_tx_o, the line fi_dut_core.vh decodes.
# usage: prep.sh <netlist.v> <cell models.v> <cells.py> <image.verilog> <out dir>
set -eu
E=$(cd "$(dirname "$0")" && pwd); T=$E/../../../fpga/tools
NET=$(readlink -f "$1"); MODELS=$(readlink -f "$2"); CELLS=$(readlink -f "$3"); IMG=$(readlink -f "$4")
OUT=$(readlink -m "$5")
mkdir -p "$OUT"
python3 "$T/fi_fpga_ce.py" "$NET" tinyriscv_soc_top --cells "$CELLS" \
  --models "$MODELS" "$E/fi_sram_example.v" \
  --out "$OUT/tinyriscv_soc_top.fpga.v" --glue "$OUT/fi_mem_glue_fpga.vh" \
  --mem-cell sram_sp_16384x32 sram_sp_8192x32 \
  --observe 'uart_tx[0]=fi_obs_uart_tx_o'
cp "$(dirname "$NET")/fi_scan_cfg.vh" "$OUT/"
python3 "$T/mkrom.py" "$IMG" "$OUT/rom.hex" 16384
