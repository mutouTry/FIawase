# Workload

`application_intmix` is the program the FI campaign runs. It is an 8x8 integer
matrix multiply, an insertion sort, and an xorshift generator. It exercises the
multiplier, the ALU, load/store, and data-dependent branches, and prints one
checksum at the end.

| file | what |
|---|---|
| `application_intmix.c` | source |
| `application_intmix.verilog` | prebuilt image, loaded by the testbench |

## Image format

`$readmemh` text: an `@address` line followed by hex bytes, little-endian within
each 32-bit word.

```
@00000000
97 11 00 20 93 81 81 88 17 81 00 20 13 01 81 FF
```

The testbench takes the image as a plusarg:

```sh
make -C sim NETLIST=... FIRMWARE=/path/to/your.verilog
```

## Rebuilding

Needs a `riscv32-*-elf` toolchain and the SoC's BSP (`sim_ctrl.h`, `uart.h`,
`xprintf.h`, `pinmux.h`). The BSP is not vendored here. Build with
`-DSIMULATION`, then convert the ELF:

```sh
riscv-none-elf-objcopy -O verilog app.elf app.verilog
```

`BENCH_ROUNDS` (default 16) scales the run time. Drop it to 2-4 if RTL
simulation is too slow. Changing it changes the checksum.

## Injection outcomes

Each run ends in one of three states, visible over the UART:

- the checksum changes
- the program hangs
- nothing happens
