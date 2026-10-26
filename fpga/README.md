# FPGA

The FI netlist can run on an FPGA in the same way as in simulation, with the
wrapper, the SoC netlist and its memories. The difference is that each clock gate
becomes a clock enable. This directory has the parts that do not depend on the SoC.
[examples/tinyriscv/fpga](../examples/tinyriscv/fpga/) is the example SoC on a
Digilent Genesys2 board (xc7k325t), which you can adapt to another board or SoC.

## Converting the netlist

An FPGA has no clock primitive for a latch followed by an AND gate.
`tools/fi_fpga_ce.py` therefore turns the clock gates on the registers' clock paths
(library ICGs, latch gates written in RTL, and the FIawase freeze) into clock
enables. Each flop behind a gate becomes a `<cell>_FICE` flop, enabled by the gate's
own condition, so a frozen block still loses the same `L` edges as in simulation.
Each memory gets an `fi_ce_i` input, and the restore signals of the memories are
brought up to the top level (`--glue`). `tools/cells.py` tells the tools how your
library names its clock gates, latches, buffers and pins.

Vivado then reads the converted netlist, the cell models and the wrapper (`rtl/`) as
RTL. The scan chain is the same as in the netlist, so `fi_scanmap.txt` still
applies.

## What you need to provide

- Your standard cells as synthesisable Verilog. Vendor models use `specify` blocks,
  UDPs and timing checks that synthesis does not accept, so write the function of
  each cell:

  ```verilog
  module AOI22 (A1, A2, B1, B2, ZN);
      output ZN;  input A1, A2, B1, B2;
      assign ZN = ~((A1 & A2) | (B1 & B2));
  endmodule

  module SDFF (SI, D, SE, CP, Q);         // a scan flop is a 2:1 mux and a flop
      output reg Q;  input SI, D, SE, CP;
      always @(posedge CP) Q <= SE ? SI : D;
  endmodule
  ```

  For each flop that sits behind a clock gate, also write a `<cell>_FICE` version:
  the same flop with a clock enable `FICE`, which holds Q while `FICE = 0`.
- `tools/cells.py` for your library. The values in it are only an illustration.
- For each memory macro, a wrapper around `rtl/fi_sram_fpga.v`, a block-RAM memory
  with the FI restore (UNDO or FILL). A FILL memory uses one bank per block RAM, so
  it is cleared in as many cycles as one block RAM has rows.
- The top level, constraints and host connection of your board.

The other files are `rtl/fi_board_uart.v`, which sends the SoC's output to the host
with a header before each trial, `host/board_campaign.py`, which loads campaigns
over JTAG (OpenOCD) and classifies each trial as Masked, SDC or DUE, and
`host/fi_board.cfg`, `host/program.sh` and `host/program.tcl`, which program the
example board with OpenOCD and Vivado. `tests/run.sh` tests `fi_board_uart` with
Icarus Verilog.

## The example's flow

1. Synthesise the FI netlist (`make -C syn/flow dc`).
2. `examples/tinyriscv/fpga/prep.sh <netlist.v> <cell models.v> <cells.py> <image.verilog> <gen dir>`
   writes the converted netlist, its memory glue, `fi_scan_cfg.vh` and the ROM
   image. The UART divisor that the program sets is `TINY_UART_CPB` in
   `examples/tinyriscv/fpga/fi_dut_core.vh`.
3. `vivado -mode batch -source examples/tinyriscv/fpga/build.tcl -tclargs <gen dir> <cell models.v> <FICE models.v> <out dir>`
4. `fpga/host/program.sh <out dir>/fpga_top.bit`, then
   `fpga/host/board_campaign.py run --golden-text ... --end-newlines N <campaign.json> ...`

The board runs the trials of a campaign one after another without the host. The
host then classifies each trial by looking for the program's end marker in its
output.
