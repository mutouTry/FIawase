# Porting FIawase to your SoC

A port is a directory of its own, like [examples/tinyriscv](../examples/tinyriscv/).
The FIawase files themselves do not need to change. A port has three parts:

| | | in the example |
|---|---|---|
| 1 | the port directory. `fi_scan_cfg.tcl` says which flops are shifted, frozen or exempt, `design.tcl` says how to read the RTL, and the SDC constrains it. | `port/` |
| 2 | a testbench and a simulation Makefile | `tb/`, `sim/` |
| 3 | a program whose output the testbench can read | `firmware/` |

## 1. What the SoC needs to provide

| needed | if your SoC differs |
|---|---|
| one free-running functional clock (`FI_CLK_PORT`), which also clocks the wrapper | the clock generation can be tied off for the FI build with `FI_TIE_PINS`, for example a PLL bypass select |
| an asynchronous reset, active low (`FI_RST_PORT`) | the flow and the wrapper assume active low and do not check it. Another polarity needs changes in `syn/fi_clk_gate.v`, `syn/lib/` and `rtl/fi_wrapper_top.v`. |
| a single clock domain to freeze | another domain has to be exempt. It must then be idle during a pass, or be clocked by the wrapper's slow clock (`FI_SLOW_CLOCKS`). |
| a JTAG TAP with a 5-bit instruction register | the wrapper's TAP and the SoC's share one IR shift. Set `FI_IRLEN` for OpenOCD and `FI_JTAG_IR_BITS` in `rtl/fi_transporter.v`. |
| the instances named in the port keep their hierarchy through both compiles | compile with `-no_autoungroup`, as `syn/flow` does |
| an output that can still be read across a freeze | for a UART, `rtl/fi_uart_obs.v` reads the TX pin in the SoC's own time. Other outputs need a FIFO and a clock-domain crossing into a transmit domain that is not frozen, like the example's `scan_uart_top`. |
| memories that can be restored between trials | each memory model includes `rtl/fi_sram_restore.vh`, and its restore signals are connected to `fi_mem_*` ([DESIGN §5.1](DESIGN.md#51-fi-time-controller-fi_time_ctrlv)). Without such memories, tie `fi_mem_done_i` to 1. |

The SoC does not need a freeze input, because the flow can add one. It does not
need a test-mode input either, if its RTL ties off the pins that mean test mode. The
flow then adds the input and connects those pins to it. If your TAP has a TRSTn,
connect it outside the wrapper, which does not pass it through.

## 2. The port directory

Start from a copy of `examples/tinyriscv/port/`. In `design.tcl`, set the top
module, the RTL directories, the defines and the SDC. In `fi_scan_cfg.tcl`, go
through the settings in this order:

1. `FI_CLK_PORT` and `FI_RST_PORT`.
2. `FI_GATE_PORT`, the freeze input. The flow adds it if the SoC has none.
3. `FI_TESTMODE_PORT`. If the SoC has none, use `FI_TESTMODE_PIN` (the pins the RTL
   ties off for test mode) or `FI_TESTMODE_CREATE`.
4. `FI_GATE_PINS` and `FI_FREEZE`, the frozen blocks, by clock pin or by instance.
5. `FI_EXEMPT` and `FI_EXEMPT_CLOCKS`, which are neither shifted nor frozen. Note the
   reason next to each entry.
6. `FI_N_FF`, a power of two larger than the chain length.

Flops that are not frozen or exempt go on the chain. [syn/README.md](../syn/README.md)
lists the other settings.

```sh
make -C syn/flow dc PORT=/path/to/port RUN=/path/to/run SURVEY=only
make -C syn/flow dc PORT=/path/to/port RUN=/path/to/run
```

The survey lists the clocks, clock gates, latches and memories you need to
classify. The first full run usually fails and lists the registers that are not
classified yet, grouped by instance. Classify them and run again, until the run
prints `FI-PASS`.

If you already have a Design Compiler flow, you can call the FIawase steps from it
instead ([syn/README.md](../syn/README.md)).

## 3. The testbench

Copy [sim/fi_tb_template.sv](../sim/fi_tb_template.sv) and fill in the lines marked
`EDIT`: the module and port names of your SoC, how the program is loaded, and the
UART bit period. Next to it, write a Makefile like this one:

```make
NETLIST      := /path/to/run/results/my_dut.mapped.v
TB_SRC       := $(CURDIR)/my_tb.sv
SDF_INSTANCE := fi_tb.u_dut
include /path/to/FIawase/sim/fi_sim.mk
```

The simulator and the library models come from `site.mk`. The wrapper's
`fi_scan_cfg.vh` is read from the directory of the netlist.

## 4. A campaign

```sh
make            # the simulation
make openocd    # in a second shell
telnet localhost 4444
> poll off
> fi_campaign { {<cycle> {<FI_Index> ...}} ... }
```

The `FI_Index` values come from `fi_scanmap.txt`, next to the netlist.
[RUNBOOK.md](RUNBOOK.md#3-run-a-campaign) explains trials, limits and the logs.

## What the checks do not cover

The synthesis checks look at the structure of the netlist. Some things they cannot
see:

- How many clock edges the freeze gate removes. If you replace `syn/fi_clk_gate.v`
  with a clock gate from your library, run `tests/run.sh`. A gate that removes
  `L+1` edges instead of `L` still restores the chain, but leaves the frozen blocks
  one cycle behind.
- The clock domain of the freeze request. The flow assumes it is that of
  `FI_CLK_PORT`.
- Whether an exemption is safe. An exempt block keeps running while the chain is
  being shifted, and an exempt clock domain has to be idle during a pass.
