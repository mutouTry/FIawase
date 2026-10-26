# Example: tinyriscv

This directory ports FIawase to [tinyriscv](https://gitee.com/liangkangnan/tinyriscv),
a small RV32IM SoC. [docs/RUNBOOK.md](../../docs/RUNBOOK.md) runs it from a fresh
clone to a campaign.

| | |
|---|---|
| `rtl/` | the SoC. The comments from upstream are in Chinese. |
| `port/` | `fi_scan_cfg.tcl` freezes 14 clock pins and exempts `u_rst`, `uart0` and the JTAG clock domain. `design.tcl` says how the flow reads the SoC. The SDC is next to them. |
| `tb/` | the testbench, with the wrapper around the netlist, the JTAG bridge, three UART monitors and one line of output per trial |
| `sim/` | the simulation Makefile |
| `firmware/` | the program, as source and as a prebuilt image |
| `fpga/` | the same system on a Digilent Genesys2 board ([fpga/README.md](../../fpga/README.md)) |

## Changes to the SoC

- `rtl/top/tinyriscv_soc_top.sv` has a `scan_gate` input for the wrapper's freeze
  request.
- `uart0` is replaced by `scan_uart_top`. Its serialiser runs on a clock that is not
  gated, behind a FIFO and a clock-domain crossing, so the UART keeps sending while
  the rest of the SoC is frozen.
- The core uses the test-mode input `io_testmode` as `scan_en`, and does not issue
  data-memory requests while it is high (`rtl/core/exu_mem.sv`).
- `rtl/core/tracer.sv` is wrapped in `` `ifndef SYNTHESIS ``.

## The program

`firmware/application_intmix.c` multiplies two 8x8 integer matrices, runs an
insertion sort and an xorshift generator, and prints a checksum. It uses the
multiplier, the ALU, loads and stores, and branches that depend on data. A fault can
change the checksum, make the program hang, or have no visible effect.

The prebuilt image, `application_intmix.verilog`, is in `$readmemh` format: an
`@address` line, then the bytes, little-endian within each 32-bit word. To run
another image, use `make FIRMWARE=/path/to/your.verilog`.

To rebuild it you need a `riscv32-*-elf` toolchain and the SoC's BSP (`sim_ctrl.h`,
`uart.h`, `xprintf.h`, `pinmux.h`), which is not included here. Build with
`-DSIMULATION`, then convert with `riscv-none-elf-objcopy -O verilog app.elf
app.verilog`. `BENCH_ROUNDS` (16 by default) sets the run time, and changing it
changes the checksum.
