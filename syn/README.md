# Synthesis

This directory has the FIawase steps that a Design Compiler flow calls. They are in
`fi_scan_lib.tcl`, which loads one file per stage from `lib/`. `fi_clk_gate.v` holds
the cells the steps add to the DUT. The steps run at a few fixed points of your flow
and read one file that describes your DUT, `fi_scan_cfg.tcl`. How the RTL is read,
the compile options and the output files are left to your flow. If your DUT has no
flow yet, [flow/](flow/) is a small one. The wrapper (`rtl/`) is not synthesised
together with the DUT.

## Calling the steps from your flow

```tcl
source <your port>/fi_scan_cfg.tcl
source <FIawase>/syn/fi_scan_lib.tcl

# ... read, elaborate, link, uniquify, load the constraints ...
fi_step fi_init_flow_vars              ;# where the output goes
fi_step fi_pre_compile                 ;# 1. on the generic netlist, BEFORE the first compile

# ... your first compile ...
fi_step fi_survey                      ;#    optional, while porting
fi_step fi_restore_clears              ;# 2. on the mapped design
fi_step fi_insert_clock_gate
fi_step fi_apply_scan_exclusion

# ... your scan compile ...
fi_step fi_dft_config                  ;# 3. the DFT settings FI needs
create_test_protocol
insert_dft

# ... any optimisation after DFT ...
fi_check_invariants                    ;# 4. on the final netlist, BEFORE change_names

change_names -rules verilog -hierarchy
# ... write the netlist, SDF, SDC ...
fi_step fi_export_scanmap              ;# 5. AFTER change_names
fi_step fi_export_clock_gates
fi_step fi_report                      ;# FI-PASS or FI-FAIL, last on screen
```

`fi_step` stops the run when a step hits a Tcl error. Without it, dc_shell's
`source` would continue with the step half done. `fi_check_invariants` is called
without `fi_step` on purpose. A failed check is reported as `FI-FAIL`, and the run
continues so that it can still write `fi_scanmap.txt` for diagnosis. In that case
`fi_export_scanmap` does not write the two files the wrapper and the host need. A
batch run should look for `FI-PASS` in the log.

[flow/scanchain.tcl](flow/scanchain.tcl) shows this sequence in a complete flow. You
can also source it into your own session after your first compile, to try FIawase
before you add the steps to your flow. It then finishes the run the way the example
flow does.

## What the steps need from your flow

| | requirement | reason |
|---|---|---|
| 1 | Design Compiler | the steps use its Tcl commands, and `fi_pre_compile` edits its generic (GTECH) netlist |
| 2 | the design is uniquified, and the constraints are loaded before `fi_pre_compile` | each tie or splice has to land in a single instance. The clocks tell apart a latch that gates a clock from one that stores data, and they define the domains named in `FI_EXEMPT_CLOCKS`. |
| 3 | each instance named in `fi_scan_cfg.tcl` keeps its hierarchy through both compiles | the checks match register paths against those instances. The example flow compiles with `-no_autoungroup`. |
| 4 | the FI netlist is a separate build, with the settings of `fi_dft_config` | the wrapper shifts one chain on one clock. A second chain, a compressor or another scan clock from a manufacturing-test setup does not fit. |
| 5 | between `fi_check_invariants` and the exports, only `change_names` modifies the netlist | the checks apply to the netlist they ran on. `fi_export_scanmap` compares the chain length and stops if it changed. |
| 6 | the freeze cells and their nets keep the `dont_touch` the steps set | checks A1 and A5 read those nets back, and a buffer inserted on one makes them fail |

The example flow runs a plain compile, adds the freeze, then runs
`compile_ultra -scan` and `insert_dft`. Other orders may work, and the checks will
tell you if they do not.

## The port: `fi_scan_cfg.tcl`

Each DUT has one. Start from the example's,
[examples/tinyriscv/port/fi_scan_cfg.tcl](../examples/tinyriscv/port/fi_scan_cfg.tcl).
Settings that it leaves out take the defaults at the top of `lib/common.tcl`.

| setting | meaning | default |
|---|---|---|
| `FI_CLK_PORT`, `FI_RST_PORT` | the free-running functional clock, which also clocks the wrapper, and the DUT's reset (active low) | — |
| `FI_GATE_PORT` | the freeze request, Clk_Gate. The flow adds this port if the DUT does not have it. | — |
| `FI_SCAN_IN_PORT`, `FI_SCAN_EN_PORT`, `FI_SCAN_OUT_PORT` | the scan ports `fi_dft_config` adds. The names must not be in use already. | — |
| `FI_TESTMODE_PORT` | the DUT's test-mode input. The wrapper holds it high while Scan_En is high. | — |
| `FI_TESTMODE_PIN` | pins that the RTL ties off and that mean test mode, such as a `test_mode` tied to 0 or the test enable of an RTL clock gate. `fi_pre_compile` adds `FI_TESTMODE_PORT` and connects these pins to it. | none |
| `FI_TESTMODE_CREATE` | 1 for a DUT with no test-mode input and no such pins. `fi_pre_compile` then adds `FI_TESTMODE_PORT` by itself, and it drives what DFT insertion connects to TestMode. | 0 |
| `FI_TIE_PINS` | `{pin value ...}`, pins tied to 0 or 1 for the FI build, for example a clock-mux select that must not change | none |
| `FI_BLACKBOX_MODULES` | memories without a `.db`, reduced to their ports. They get an FI memory model in simulation and have to be frozen (A9). | none |
| `FI_GATE_CLOCK` | 1 if your compile inserts clock gates (`-gate_clock`). `fi_pre_compile` then keeps them out of exempt blocks and domains (A8). | 0 |
| `FI_FREEZE` | frozen blocks, by instance (their clock inputs from `FI_CLK_PORT`) or by pin (for example the clock of a black box) | none |
| `FI_GATE_PINS` | frozen blocks, by clock pin. Useful for a block with two clocks, of which only one stops. | none |
| `FI_EXEMPT` | instances that are neither shifted nor frozen. They keep running during a pass, so note the reason for each entry. | none |
| `FI_EXEMPT_CLOCKS` | clock domains that are neither shifted nor frozen, by SDC clock name. This is only safe for a clock that is idle during a pass. | none |
| `FI_SLOW_CLOCKS` | the exempt domains that the wrapper's slow clock drives (`SLOW_DIV`). That clock stops while the DUT is in reset, so `FI_CLEAR` covers their registers. | none |
| `FI_LATCH_HOLD` | adds a hold, driven by the freeze, to each latch that stores data | 1 |
| `FI_CLEAR` | makes the DUT reset clear the registers off the chain (frozen, exempt, in a slow-clock domain, or latches that store data). `fi_pre_compile` adds a clear to those that have no reset. `fi_restore_clears` connects the reset to clears that it does not already control, such as one written `rst_ni \|\| x`. | 1 |
| `FI_RESET_ACK` | `{register reason ...}`, registers off the chain that the DUT reset cannot reach (a preset, a pin of unknown polarity, no asynchronous pin), each with the reason it does no harm. For any other such register, `fi_restore_clears` stops or A11 fails. | none |
| `FI_CHAIN_HEAD_NORESET` | places the chain cells that the DUT reset does not restore at the start of the chain, so that the scrub after each trial only needs to shift those (`FI_SCRUB_LEN`, A12) | 1 |
| `FI_N_FF` | the size limit of the FI_Entry encoding, a power of two larger than L. The wrapper reads it from the generated `fi_scan_cfg.vh`. | — |

Registers that are not frozen or exempt go on the chain. Each register has to end
up in one of the three groups, and A3 lists the ones that do not.

A frozen pin driven directly by `FI_CLK_PORT` is moved onto the shared freeze gate.
A frozen pin behind a clock gate of the DUT (written in the RTL, or inserted by
compile) gets a freeze cell in series, and the DUT's gate keeps working. If a frozen
pin has any other driver, the run stops.

## The checks

`fi_check_invariants` checks that the netlist is ready for injection. Each failure
lists the registers involved, grouped by instance, and the setting to change.

| | check | what is checked |
|---|---|---|
| A1 | the freeze is in place | each frozen pin is driven by the freeze, and each register in a frozen instance has a clock that goes through it. The freeze takes its clock, reset and request from `FI_CLK_PORT`, `FI_RST_PORT` and `FI_GATE_PORT`. Each latch that stores data is held by it. |
| A2 | nothing is both frozen and shifted | no chain cell is inside a frozen instance (except for `FI_EXEMPT`) |
| A3 | each register is classified | each register is shifted, frozen or exempt |
| A4 | the chain fits the table encoding | L ≤ `FI_N_FF` − 1 |
| A5 | DFT did not rewire the freeze | each freeze output has no other driver, and only drives pins inside frozen instances |
| A6 | the chain flops see each shift edge | with Scan_En = testmode = 1, each clock path of the chain starts at `FI_CLK_PORT` and goes only through buffers and through clock gates that are open during the shift |
| A7 | the shift does not reach a clock or a reset | while the chain shifts, no clock pin and no asynchronous clear or set can be reached from a chain cell |
| A8 | nothing outside the chain runs on Scan_En | no register of an exempt block or domain is behind a clock gate that Scan_En or testmode can open |
| A9 | black boxes are frozen | each instance in `FI_BLACKBOX_MODULES` is frozen |
| A10 | black-box outputs keep their loads | compile did not remove the logic that the outputs of a black box feed |
| A11 | the state off the chain is reset (with `FI_CLEAR`) | the DUT reset restores each register off the chain, through an asynchronous clear or set that it holds active (found as in A12), or the register is listed in `FI_RESET_ACK`. A trial then leaves nothing there for the next one. Exempt domains outside `FI_SLOW_CLOCKS`, such as the host's TCK, keep their own resets. |
| A12 | the cells without a reset come first on the chain | the chain cells that the DUT reset does not restore are FI_Index 0 to K−1, so a scrub of K = `FI_SCRUB_LEN` shifts clears all of them. They are found by case analysis, with `FI_RST_PORT` at 0 and at 1, Scan_En = testmode = 0, and constants carried through registers such as reset synchronisers. A cell counts as restored if one of its asynchronous clears or sets is active while the reset is active, and inactive once it is released. |

The checks look at the structure of the netlist.
[docs/PORTING.md](../docs/PORTING.md#what-the-checks-do-not-cover) lists what they
cannot see.

## Output files

They are written to `FI_RESULTS_DIR`:

| file | content |
|---|---|
| `fi_scanmap.txt` | `FI_Index <TAB> flop`, one line per position on the chain. Search it to pick targets. |
| `fi_scan_cfg.vh` | for the wrapper: `FI_N_FF`, which sets W_IDX, `FI_SCAN_LEN`, and `FI_SCRUB_LEN`, the number of scrub shifts |
| `fi_scan_cfg.tcl` | for the host: `FI_SCAN_LEN` and `FI_W_IDX` |
| `fi_scan_path.rpt` | the `report_scan_path` output that the map is parsed from |
| `fi_clock_gates.txt` | the clock gates on the registers' clock paths, for an FPGA build |
| `fi_survey.rpt` | written by `fi_survey`: clocks, clock gates, latches, black boxes and registers without a reset |

`fi_scan_cfg.vh` and `fi_scan_cfg.tcl` are written only when the checks pass, and
each run first removes the ones left by an earlier run. The simulation
(`sim/fi_sim.mk`) and the host (`host/fi_openocd.cfg`) read them from the directory
of the netlist.

`FI_Index` comes from the `Cell_#` column of `report_scan_path`, which follows the
order of the chain that was built. The SCANDEF file is not suitable: it describes
the chain as `FLOATING`, an unordered set, and Design Compiler writes it in a
different order.

## The example flow

For a DUT that has no flow yet, [flow/](flow/) goes from RTL to the netlist:

```sh
make -C syn/flow dc                                       # the example DUT
make -C syn/flow dc PORT=/path/to/port RUN=/path/to/run   # yours
make -C syn/flow dc PORT=... RUN=... SURVEY=only          # the survey only
```

A port directory holds `fi_scan_cfg.tcl`, `design.tcl` (the top module, RTL
directories, defines and SDC, see [the example's](../examples/tinyriscv/port/design.tcl))
and the SDC. Relative paths in `design.tcl` are relative to the port directory, and
the output goes to the run directory. The libraries and `DC_SHELL` come from
`site.mk` at the top of FIawase. `dc_fi.tcl` reads the RTL with `analyze -autoread`,
uniquifies the design, applies the SDC, runs `fi_pre_compile` and a plain
`compile_ultra`. `scanchain.tcl` does the rest. `make dc` fails if a step reports
`FI-ERROR` or if `FI-PASS` is missing.

The flow is kept simple, with one SDC, fixed compile options and no physical
synthesis. If you already have a flow, it is better to use yours.
