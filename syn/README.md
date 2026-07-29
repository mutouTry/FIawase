# Synthesis: RTL to an FI-ready netlist

Nothing here contains foundry data. You supply Design Compiler, a standard
cell library and (if your DUT uses macros) their `.db` files; everything
else is in this directory.

## Two ways in

**A. You already have a Design Compiler flow.** Then you need one line.
Get your design to the state described at the top of `dc_fi.tcl` — top-level
current design, elaborated, linked, uniquified, constrained, mapped by a
plain `compile_ultra` — and then:

```tcl
source /path/to/FIawase/syn/scanchain.tcl
```

That is exactly how this was developed: against a Synopsys DC Reference
Methodology setup, sourced by hand after `make dc && make dc_open_net`.
`scanchain.tcl` carries **no dependency on the RM**. If your shell happens
to define `RESULTS_DIR`, `REPORTS_DIR` or the `DCRM_*` filename variables,
`fi_init_flow_vars` inherits them and you get byte-identical output paths;
if it does not, it falls back to the same filenames under `./results` and
`./reports`. You do not need `Makefile`, `dc_fi.tcl` or `tool_config.tcl`.

**B. You have Design Compiler but no flow.** Then use the bundled driver:

```sh
cp tool_config.tcl.example tool_config.tcl   # libraries, top, RTL, SDC
$EDITOR tool_config.tcl
make dc
```

`dc_fi.tcl` reads the RTL, elaborates, links, uniquifies, applies
`constraints/fi_example.sdc`, runs the first `compile_ultra`, and then
sources `scanchain.tcl`. It is deliberately minimal — it exists so the
repository is runnable, not to be a synthesis methodology.

## The files

| file | DUT-specific? | what it does |
|---|---|---|
| `fi_scan_cfg.tcl` | **yes — this is the one you edit** | which clock pins get frozen, what is exempt, the port names, where output goes |
| `fi_scan_lib.tcl` | no | the six procs that do the work |
| `fi_clk_gate.v` | no | the freeze gate, written so it needs no library cell names |
| `scanchain.tcl` | no | the FI stage itself: gate, exclusion, scan insertion, assertions, export |
| `dc_fi.tcl` | no | way B only: standalone driver |
| `tool_config.tcl` | **yours, gitignored** | way B only: your libraries and paths |
| `constraints/fi_example.sdc` | example | way B only: minimal constraints |

## Where the procs go

This is the inside of `scanchain.tcl`, reproduced here so you can see the
ordering constraints if you ever need to split it up:

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
fi_report                       ;# last, so the verdict is the last thing printed
```

`scanchain.tcl` is not a template to copy from -- source it directly. The
only thing you should be editing is `fi_scan_cfg.tcl`.

## Two things that will bite you

**`source` does not stop on a Tcl error in dc_shell.** A failed
`fi_check_invariants` prints `Error: FI-ERROR: ...` and the rest of your script
runs anyway, netlist and all. What actually stops you from using a bad result is
that `fi_export_scanmap` refuses to write `fi_scan_cfg.vh` / `fi_scan_cfg.tcl`
unless the check passed — without those two files the simulation and the host
cannot be configured. Grep the log for `FI-FAIL`.

**Never declare the gated clock as a `ScanClock`.** Only the free-running
functional clock may be one. Declaring the gated branch would let DFT stitch
frozen flops into the chain, which is precisely the failure A2 exists to catch.

## What the assertions do not catch

A1–A5 are worth what they check and nothing more. Below are the ways to get a
netlist that passes all five and is still wrong, ordered by **how quietly they
fail** — the first one prints `FI-PASS`.

**1. A pin in `FI_GATE_PINS` was not already driven by `FI_CLK_PORT`.**
`fi_insert_clock_gate` disconnects whatever was there and connects the gated net,
without checking what it replaced. A block hanging off a divider or a second PLL
output is silently re-domained — **permanently, not just during injection**. A1
then passes by construction, because it asks only whether the pin is on the gated
net, which it now is. *Verify this list by hand before your first run.* It is the
single most important thing on this page.

**2. A flop from a second functional clock domain on the chain.** The executor
counts exactly `L` edges of one clock; a foreign-domain flop shifts at its own
rate, the rotation never completes, and the chain is never restored. No assertion
covers it: A2 does not fire (it is not under a frozen owner), A3 does not fire (it
*is* on the chain), A5 does not fire (it is nowhere near the gated net). The flow
runs `-clock_mixing mix_clocks` and *asserts* rather than checks that one coherent
domain is left. `report_scan_path` prints MasterClock/SlaveClock per chain — read
`reports/*.scanpath.rpt` and confirm there is one master and no slave.

**3. A stateful black-box macro outside every frozen instance.** A3 enumerates
state with `all_registers`, which does not return black boxes. The example SoC's
two SRAMs are invisible to it and are safe only because their parents are in
`FI_GATE_PINS`. A macro at top level, or under a block you chose not to freeze,
keeps taking write strobes for `L` cycles while the chain is scrambled — with
`FI-PASS` in the log.

**4. Substituting your library's ICG without re-running `tests/run.sh`.**
`fi_clk_gate.v` invites the swap, and the enable is asymmetric *on purpose*:
engage on the registered `gate_q`, release on the raw input. The obvious "clean"
symmetric form masks `L+1` edges instead of `L`. The chain still restores
perfectly and the waveform still looks right — every frozen block is simply one
functional cycle out of phase, forever. `tests/run.sh` is the only thing that
detects this.

**5. Any cell inserted on the gated net.** `set_dont_touch` on it is load-bearing
for the *assertions*, not only for structure: A1 compares the net by name and A5
requires the driver set to be exactly the gate's output. A buffer splits the net
and fails A1 on every pin at once, on a netlist that is functionally fine. The
gated branch must reach P&R as a single unbuffered net; CTS is downstream, and DC
is forbidden from solving it here.

**6. Active-high reset, or a freeze input launched from another clock.** A1–A5
test connectivity, not polarity and not clock domains. Neither is checked
anywhere, and the example SDC does not even constrain the freeze input.

Keep `-no_autoungroup` on **both** compiles. It is usually justified by the
`FI_Index → flop` map, which undersells it: on the second compile it also
preserves the instance paths A1, A2 and A5 are matching against.

## Outputs

Written to `${RESULTS_DIR}`:

| file | for |
|---|---|
| `fi_scanmap.txt` | `FI_Index <TAB> flop`, one line per chain position. Pick targets with `grep`. |
| `fi_scan_cfg.vh` | copy over the RTL's `fi_scan_cfg.vh` (`FI_N_FF`, `FI_SCAN_LEN`) |
| `fi_scan_cfg.tcl` | the same two numbers for the host (`FI_SCAN_LEN`, `FI_W_IDX`) |
| `fi_scan_path.rpt` | the raw `report_scan_path` the map was parsed from |

These three move **together** with the netlist. A `CFG_SCAN_LEN` that does not match
the netlist in the simulator means the chain is not restored and the DUT dies on
the first injection.

## Why `FI_Index` comes from `report_scan_path` and not the SCANDEF

SCANDEF writes chains as `FLOATING`, i.e. an *unordered* set that place-and-route
is free to reorder, and DC emits it in a different order from the chain it
actually built. Parsing it produces a `FI_Index → flop` map that looks perfectly normal
and is entirely wrong. The `Cell_#` column of `report_scan_path` is the built
order; that is what `fi_export_scanmap` parses, and it has been calibrated against
a measured injection.

## Porting checklist

1. Set the three port names in `fi_scan_cfg.tcl`.
2. Put your DUT's frozen clock **pins** in `FI_GATE_PINS` — pin granularity, not
   instance: a block with two clocks may need only one of them frozen.
3. Run. A3 will fail and list, grouped by instance, everything you have not
   classified. Work through it: each entry goes into `FI_GATE_PINS`,
   `FI_EXEMPT`, or `FI_EXEMPT_CLOCKS`, with a reason written next to it.
4. Repeat until all five checks pass.
5. Check `report_clocks`: the gated branch normally inherits the master clock
   through the gate automatically. Add a `create_generated_clock` **only** if it
   demonstrably did not — adding one on top of a clock DC already propagated makes
   timing worse, not better.
