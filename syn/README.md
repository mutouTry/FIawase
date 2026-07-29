# Synthesis: RTL to an FI-ready netlist

Nothing here contains foundry data. You supply Design Compiler, a standard
cell library and, if your DUT uses macros, their `.db` files.

## Two ways in

**A. You already have a Design Compiler flow.** Bring the design to the state
described at the top of `dc_fi.tcl`: top-level current design, elaborated,
linked, uniquified, constrained, mapped by a plain `compile_ultra`. Then add
one line:

```tcl
source /path/to/FIawase/syn/scanchain.tcl
```

`scanchain.tcl` has no dependency on the Synopsys Reference Methodology.
If your shell defines `RESULTS_DIR`, `REPORTS_DIR` or the `DCRM_*` filename
variables, `fi_init_flow_vars` inherits them. Otherwise output goes to the same
filenames under `./results` and `./reports`. You do not need `Makefile`,
`dc_fi.tcl` or `tool_config.tcl`.

**B. You have Design Compiler but no flow.** Use the bundled driver:

```sh
cp tool_config.tcl.example tool_config.tcl   # libraries, top, RTL, SDC
$EDITOR tool_config.tcl
make dc
```

`dc_fi.tcl` reads the RTL, elaborates, links, uniquifies, applies
`constraints/fi_example.sdc`, runs the first `compile_ultra`, then sources
`scanchain.tcl`.

## The files

| file | DUT-specific? | what it does |
|---|---|---|
| `fi_scan_cfg.tcl` | **yes — edit this one** | which clock pins get frozen, what is exempt, the port names, where output goes |
| `fi_scan_lib.tcl` | no | the six procs that do the work |
| `fi_clk_gate.v` | no | the freeze gate, needs no library cell names |
| `scanchain.tcl` | no | the FI stage: gate, exclusion, scan insertion, assertions, export |
| `dc_fi.tcl` | no | way B only: standalone driver |
| `tool_config.tcl` | **yours, gitignored** | way B only: your libraries and paths |
| `constraints/fi_example.sdc` | example | way B only: minimal constraints |

## Where the procs go

This is the inside of `scanchain.tcl`. The ordering is required.

```tcl
source .../fi_scan_cfg.tcl
source .../fi_scan_lib.tcl

fi_init_flow_vars               ;# first: resolves where output goes

fi_insert_clock_gate            ;# before compile_ultra
fi_apply_scan_exclusion         ;# before compile_ultra

compile_ultra -scan -no_seq_output_inversion -no_autoungroup
... your existing set_dft_signal / set_dft_configuration ...
insert_dft

fi_check_invariants             ;# right after insert_dft: fail fast

optimize_netlist ...
change_names -rules verilog -hierarchy
...

fi_export_scanmap               ;# after change_names: names must be final
fi_report                       ;# last
```

Source `scanchain.tcl` directly instead of copying it. Edit only
`fi_scan_cfg.tcl`.

Keep `-no_autoungroup` on **both** compiles. It preserves the `FI_Index → flop`
map and the instance paths that A1, A2 and A5 match against.

## Two things that will bite you

**`source` does not stop on a Tcl error in dc_shell.** A failed
`fi_check_invariants` prints `Error: FI-ERROR: ...` and the rest of the script
still runs. `fi_export_scanmap` will not write `fi_scan_cfg.vh` or
`fi_scan_cfg.tcl` unless the check passed, so the simulation and the host cannot
be configured from a bad run. Grep the log for `FI-FAIL`.

**Never declare the gated clock as a `ScanClock`.** Only the free-running
functional clock may be one. Declaring the gated branch lets DFT stitch frozen
flops into the chain. A2 catches this.

## What the assertions do not catch

A netlist can pass A1–A5 and still be wrong. Ordered by how quietly they fail.
The first one prints `FI-PASS`.

1. **A pin in `FI_GATE_PINS` that was not already driven by `FI_CLK_PORT`.**
   `fi_insert_clock_gate` replaces whatever drove it, so a block fed by a divider
   or a second PLL is moved to the new domain permanently. Verify this list by
   hand before the first run.
2. **A flop from a second functional clock domain on the chain.** The executor
   counts exactly `L` edges of one clock, so a foreign-domain flop stops the
   rotation from completing and the chain is never restored. Read
   `reports/*.scanpath.rpt` and confirm one MasterClock and no SlaveClock.
3. **A stateful black-box macro outside every frozen instance.** A3 uses
   `all_registers`, which does not return black boxes. Such a macro keeps taking
   write strobes for `L` cycles while the chain is scrambled.
4. **Substituting your library's ICG without re-running `tests/run.sh`.** The
   enable in `fi_clk_gate.v` is asymmetric: engage on the registered `gate_q`,
   release on the raw input. A symmetric version masks `L+1` edges instead of `L`
   and leaves every frozen block one functional cycle out of phase, with the
   chain still restoring correctly.
5. **Any cell inserted on the gated net.** A1 compares the net by name and A5
   requires the driver set to be exactly the gate output, so one buffer fails A1
   on every pin at once. Keep `set_dont_touch` on it and let CTS do the
   buffering.
6. **Active-high reset, or a freeze input launched from another clock.** A1–A5
   test connectivity only, not polarity and not clock domains. The example SDC
   does not constrain the freeze input.

## Outputs

Written to `${RESULTS_DIR}`:

| file | for |
|---|---|
| `fi_scanmap.txt` | `FI_Index <TAB> flop`, one line per chain position. Pick targets with `grep`. |
| `fi_scan_cfg.vh` | copy over the RTL's `fi_scan_cfg.vh` (`FI_N_FF`, `FI_SCAN_LEN`) |
| `fi_scan_cfg.tcl` | the same two numbers for the host (`FI_SCAN_LEN`, `FI_W_IDX`) |
| `fi_scan_path.rpt` | the raw `report_scan_path` the map was parsed from |

These files move together with the netlist. A `CFG_SCAN_LEN` that does not match
the netlist in the simulator means the chain is not restored, and the DUT dies on
the first injection.

`FI_Index` comes from the `Cell_#` column of `report_scan_path`, which is the
built order. Do not parse the SCANDEF instead: it writes chains as `FLOATING`,
an unordered set, and DC emits it in a different order from the chain it built.

## Porting checklist

1. Set the three port names in `fi_scan_cfg.tcl`.
2. Put your DUT's frozen clock **pins** in `FI_GATE_PINS`. Pin granularity, not
   instance: a block with two clocks may need only one of them frozen.
3. Run. A3 fails and lists, grouped by instance, everything not yet classified.
   Each entry goes into `FI_GATE_PINS`, `FI_EXEMPT` or `FI_EXEMPT_CLOCKS`, with
   a reason written next to it.
4. Repeat until all five checks pass.
5. Check `report_clocks`. The gated branch normally inherits the master clock
   through the gate. Add a `create_generated_clock` only if it did not.
