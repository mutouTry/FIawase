# Runbook: the example SoC

This page takes [examples/tinyriscv](../examples/tinyriscv/) from a fresh clone to a
running campaign. For your own SoC, see [PORTING.md](PORTING.md). Commands run from
the top of the repository unless a step says otherwise.

## What you need

| | for |
|---|---|
| Design Compiler, a standard cell library (`.db`), the `.db` of the example's two SRAM macros | synthesis |
| VCS, the Verilog models of the same library, a simulation model of each SRAM | simulation |
| OpenOCD | the campaign |

The SRAM models do not have to come from the vendor. A module with the same pins and
the same behaviour also works.

---

## 0. Your machine

```sh
cp site.mk.example site.mk
$EDITOR site.mk
```

`site.mk` describes your machine. Git ignores it. To keep it outside the repository,
set `FI_SITE=/path/to/site.mk`.

- `DC_SHELL`, `VCS`, `OPENOCD`: the command for each tool. A container or a site
  wrapper can be part of the command.
- `FI_SEARCH_PATH`: the directories with your `.db` files
- `FI_TARGET_LIBRARY`: the standard cell `.db` at the corner you want
- `FI_MACRO_LIBRARY`: the `.db` of each macro. If one is missing, that macro becomes
  a black box.
- `FI_BUF_CELL` / `FI_BUF_CELL_PIN`, `FI_IO_CELL` / `FI_IO_CELL_PIN`: a buffer and an
  input cell, used by the example SDC
- `STDCELL_MODELS`, `MEM_MODELS`: the Verilog models of the same library and macros.
  The testbench writes the program into the ROM through a hierarchical reference to
  a 32-bit reg array called `ram`. If your model names it differently, set
  `DEFINES := +define+T22NM +define+FI_ROM_MEM=<path>`.

---

## 1. Synthesise

```sh
make -C syn/flow dc
```

A successful run ends with `FI-PASS`. Otherwise `make` stops with an error. To try a
change without compiling the RTL again, add `INPUT_DDC=` with the
`<top>.compiled.ddc` of an earlier run.

The results are in `syn/flow/results/`:

| file | |
|---|---|
| `tinyriscv_soc_top.mapped.v` | the netlist |
| `fi_scan_cfg.vh`, `fi_scan_cfg.tcl` | chain length, scrub length and index width, read by the simulation and the host |
| `fi_scanmap.txt` | which flop each `FI_Index` is. Search it to pick targets. |
| `fi_scan_path.rpt` | the Design Compiler report the map comes from |
| `fi_clock_gates.txt` | the clock gates on the registers' clock paths, for an FPGA build |

`fi_scan_cfg.vh` and `fi_scan_cfg.tcl` are written only when the checks pass. A new
synthesis run can change the chain length and the position of each flop, so pick
targets from the current `fi_scanmap.txt`.

---

## 2. Simulate

```sh
cd examples/tinyriscv/sim
make echo-config     # shows the settings it found
make                 # builds and runs
```

By default the simulation uses the netlist in `syn/flow/results/`, and
`make NETLIST=<file>` uses another one. `make wave` also writes a waveform, and
`make run` runs again without rebuilding. Campaigns normally run without timing,
but `make SDF=<file>` adds it.

The simulator then waits for OpenOCD and prints `jtag0: Accepted client connection`
when it connects. Leave it running.

---

## 3. Run a campaign

In a second shell, in `examples/tinyriscv/sim`:

```sh
make openocd
```

In a third shell:

```sh
telnet localhost 4444
> poll off
> fi_idcode
```

Run `poll off` first. Otherwise OpenOCD keeps polling in the background, and its
DMI accesses get mixed with yours. `fi_idcode` shows which TAP answers. Before the
wrapper takes over, it is the DUT's own TAP. After that, it is the wrapper's,
`f17e0007`.

### Trials

A trial is `{<FI_Cycle> {<FI_Index> ...}}`, the cycle to inject at and the flops to
flip. To find the index of a flop, search for its name in
`syn/flow/results/fi_scanmap.txt`.

```
> fi_campaign { {30000 {37}} {90000 {37}} {90000 {37 38 39}} {150000 {17 600 2600}} }
> fi_mbu 90000 {37 38 39}
```

`fi_mbu` runs a single trial. For a longer workload, give `fi_campaign` a second
argument, the timeout `CFG_TO_THR`. Write a campaign on one line. Tcl does not treat
`;#` inside `{ ... }` as a comment, so a comment between trials makes the campaign
invalid.

The bits of one trial are flipped in the same scan pass, so a multi-bit upset takes
`L` shifts, like a single one. Two trials with the same cycle are still two
separate trials, each with its own reset and run.

Cycles are counted from the release of reset, the same way as in
`fi_exec_window.txt`. Choose them from the `[exec start, exec end)` range that the
testbench writes there.

When you start a campaign, the program that is already running continues until its
cycle counter reaches `CFG_TO_THR`. The campaign's trials come after it. OpenOCD
halts the DUT when it starts (`FI_DUT_TARGET 1`, the default), so this first run
prints nothing and the testbench reports it as a timeout.

`fi_campaign` checks these limits before it writes anything:

| limit | value |
|---|---|
| `Cycle_Offset` | 18 bits, so at most 262143 cycles between two trials |
| `FI_Index` | 13 bits |
| FI Table | 256 entries |

### Reading the results

Use `uart_txo.log`. It records `uart_tx[0]`, the output of the UART itself. The pad
(`stdout`, `uart_pad_fi.log`) also carries GPIO0 until the firmware switches the pin
mux, which adds some bytes before the real output.

The testbench prints one `[FI-TRIAL n]` line for each trial. It says whether the
program printed its output, finished without printing, or timed out. Classifying a
trial as Masked, SDC or DUE is left to the host, by comparing its output with that of
a run without faults.

`fi_status_dump` reads `FI_VERSION`, `CFG_SCAN_LEN`, `CFG_TBL_LEN`, `CFG_FI_CYCLE`,
the current `FI_CYCLE` and `FI_STATUS`. Each register is read twice, because the
answer comes one access late. The second value is the right one.

Results depend on the netlist and on the simulation seed. Flops without a reset
start at a random value, and `SEED` (1 by default) fixes that value. After a new
synthesis run, the results can differ.

---

## When something goes wrong

| what you see | likely cause |
|---|---|
| `make` stops at `STDCELL_MODELS` | `site.mk` is missing or incomplete |
| `fi_scan_cfg.vh not found` | synthesis did not pass its checks, or the netlist was moved away from its results |
| thousands of undefined modules | `STDCELL_MODELS` is wrong, or `MEM_MODELS` is missing while the netlist uses macros |
| nothing is injected | `CFG_TBL_LEN` (DMI `0x68`) was not written. The table has no end marker, only this length. |
| the loop stops after the first trial | `RTC_ALIGN_EN = 1` while `aon_lfclk_i` is tied to 0 ([DESIGN §7](DESIGN.md#7-pacing-the-reset-window-and-the-duts-slow-clock)) |
| `FI_STATUS` bit 2 (`err_order`) | the `FI_Index` values of a trial were not in descending order. `fi_pattern` sorts them. |
| `FI_STATUS` bit 3 (`err_malformed`) | the last entry of the table has `EOP = 0`. `fi_pattern` ends each trial with one. |
| `FI_STATUS` bit 5, and the campaign stopped | the DUT wrote to a memory while it was being restored. Something reaches that memory while the DUT should be frozen or in reset. |
| `FI_STATUS` bit 6 | the trial changed a memory more often than its undo log can hold, and was ended. Count it as DUE. If a run without faults sets it too, that memory needs FILL or a larger log. |
| the injection hits the wrong flop | the `FI_Index` came from an older netlist, or from the SCANDEF instead of `fi_scanmap.txt` |
| telnet and OpenOCD both hang | a host procedure uses a `runtest` count much larger than 8 |
