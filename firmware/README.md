# Workload

`application_intmix` is the program the FI campaign runs. It is an 8x8 integer
matrix multiply plus an insertion sort and an xorshift generator, chosen so that
one workload exercises the multiplier, the ALU, load/store, and data-dependent
branches, and so that a single checksum at the end tells you whether an injected
fault mattered.

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

The testbench takes it as a plusarg, so you can swap workloads without rebuilding:

```sh
make -C sim NETLIST=... FIRMWARE=/path/to/your.verilog
```

## Rebuilding

Needs a `riscv32-*-elf` toolchain and the SoC's BSP (`sim_ctrl.h`, `uart.h`,
`xprintf.h`, `pinmux.h`), neither of which is vendored here. Build with
`-DSIMULATION`, then convert the ELF:

```sh
riscv-none-elf-objcopy -O verilog app.elf app.verilog
```

`BENCH_ROUNDS` (default 16) scales the run time; drop it to 2-4 if RTL simulation
is too slow. Changing it changes the checksum.

## Why the checksum matters for FI

The program has one long IO-free compute window and one observable output. A
flipped bit therefore lands in one of three buckets that are trivial to tell apart
over the UART: the checksum changes, the program hangs, or nothing happens. Rounds
are chained through a loop-carried dependency, so a fault injected early cannot be
optimised away or masked by a later round recomputing the same thing.
