# Runbook — from a clone to a running FI campaign

Ordered steps. Everything foundry-owned comes from two config files you write;
none of it ships with the repository.

If you already have a Design Compiler flow, read
[syn/README.md](../syn/README.md) first and skip most of stage 2.

---

## What you need in hand

| item | used for |
|---|---|
| Design Compiler | scan insertion. Stage 2 only. |
| standard cell library, `.db` | synthesis |
| the same library's Verilog simulation model | stage 3 |
| VCS | stage 3. The JTAG DPI bridge does not compile under iverilog. |
| OpenOCD | stage 4 |
| macro `.db` and a simulation model per memory the DUT instantiates | only if your DUT uses memory macros |

The simulation memory model does not have to be the vendor's. Any module with
the same pin list and behaviour works. See stage 3.

---

## Stage 0 — check the invariant

```sh
cd tests && ./run.sh
```

Expect `ALL PASS` over nine chain lengths. If this fails, stop.

---

## Stage 1 — decide whether to synthesise

Skip stage 2 if you already have a scan-inserted netlist of this DUT. Point
`sim/config.mk` at it and go to stage 3. The netlist must satisfy the contract
in [syn/README.md](../syn/README.md): one scan chain, the freeze gate present,
the frozen blocks off the chain. A netlist from an earlier `scanchain.tcl` run
qualifies.

Do stage 2 if you have no netlist, or if you changed `FI_GATE_PINS`.

---

## Stage 2 — synthesis

### 2.1 Configure

```sh
cd syn
cp tool_config.tcl.example tool_config.tcl
$EDITOR tool_config.tcl
```

Fill in at minimum:

- `FI_SEARCH_PATH` — directories holding your `.db` files
- `FI_TARGET_LIBRARY` — standard cell `.db` at the corner you want
- `FI_LINK_LIBRARY` — `*`, the standard cells, and every macro `.db`. A missing
  macro `.db` leaves a black box and the scan chain is built around a hole.
- `FI_BUF_CELL` / `FI_BUF_CELL_PIN`, `FI_IO_CELL` / `FI_IO_CELL_PIN` — any
  buffer and input cell. Only the example SDC uses them.
- `FI_RTL_DEFINES` — the defines your RTL needs. The example DUT uses `T22NM` to select memory
  macros over inferred RAM.

Then [syn/fi_scan_cfg.tcl](../syn/fi_scan_cfg.tcl), already correct for the
bundled tinyriscv example. For your own DUT, set it in this order:

| | what | if it is wrong |
|---|---|---|
| 1 | `FI_CLK_PORT`, `FI_RST_PORT` | `FI-ERROR: port '...' not found on <top>` |
| 2 | `FI_GATE_PORT` | your DUT's name for the freeze input. If absent the flow creates it and warns, and you must drive it a level up. |
| 3 | `FI_TESTMODE_PORT` | must already exist on your DUT. The flow creates `io_scanin/en/out` but not this one. A missing port is a Tcl error mid-run, and `dc_shell` does not stop on those. |
| 4 | `FI_GATE_PINS` | clock pins, not instances. Each must already be driven by `FI_CLK_PORT`. The flow reconnects whatever it finds without checking. |
| 5 | `FI_EXEMPT`, `FI_EXEMPT_CLOCKS` | A3 lists what to put here on the first run |
| 6 | `FI_N_FF` | power of two, `>= L+1`. Asserted by A4. |

Use instance paths exactly as `report_scan_path` prints them.

#### Preconditions to check against your design

Three of these come from [README.md](../README.md#what-your-dut-has-to-provide):
the freeze input, one free-running functional clock, and an observation channel
that survives a freeze. The rest are properties the flow assumes and does not
verify.

| what | why | if your design differs |
|---|---|---|
| the reset on `FI_RST_PORT` is **active low** | hardcoded in `fi_clk_gate.v`, `fi_scan_lib.tcl`, `scanchain.tcl` and `fi_wrapper_top.v` | edit those four places. Nothing warns you. |
| a **testmode input already exists** | declared with `-view existing_dft`; only the three scan ports are created for you | add the port to your top level |
| **hierarchy survives both compiles** | `-no_autoungroup`. Flattening destroys the `FI_Index → flop` map and the instance paths the checks match on | keep `-no_autoungroup` |
| exactly **one clock domain needs freezing** | one gate is built on one net | a second domain cannot be expressed |
| every stateful **black-box macro** sits under a frozen instance | `all_registers` does not return black boxes, so A3 cannot see them | freeze the parent, or prove the macro is idle |
| the JTAG TAP has a **5-bit IR** | both TAPs share one IR shift under a single OpenOCD `-irlen` | edit `FI_JTAG_IR_BITS` in `rtl/fi/fi_transporter.v` |
| **TRSTn**, if your TAP has one | the wrapper does not pass it through | wire it outside the wrapper |

### 2.2 Run

```sh
make dc
```

To reuse an existing mapped `.ddc`, set `FI_INPUT_DDC` in `tool_config.tcl`.
`make dc` then skips analyze/elaborate/compile and reads it back.

### 2.3 Read the verdict

The last thing printed is a PASS/FAIL banner. `make dc` exits non-zero if
`FI-PASS` is absent.

A first run on a new DUT normally fails assertion A3 with a list of registers
that are neither shifted, nor frozen, nor exempt. Each entry belongs in
`FI_GATE_PINS`, `FI_EXEMPT` or `FI_EXEMPT_CLOCKS`. Fix them and re-run.

`dc_shell`'s `source` does not stop on a Tcl error, so a failed run still writes
a netlist. **If `fi_scan_cfg.vh` and `fi_scan_cfg.tcl` are missing from
`results/`, the checks did not pass. Do not use the netlist.**

### 2.4 What you get

In `results/`:

| file | goes where |
|---|---|
| `<top>.mapped.v` | `NETLIST` in `sim/config.mk` |
| `fi_scan_cfg.vh` | copy over `rtl/fi/fi_scan_cfg.vh` |
| `fi_scan_cfg.tcl` | its two values go into `host/tapename.tcl` |
| `fi_scanmap.txt` | `FI_Index -> flop`. Grep it to pick targets. |
| `fi_scan_path.rpt` | the raw report the map was parsed from |

### 2.5 Sync the three files

```sh
cp results/fi_scan_cfg.vh ../rtl/fi/fi_scan_cfg.vh
$EDITOR ../host/tapename.tcl        # FI_SCAN_LEN and FI_W_IDX, from results/fi_scan_cfg.tcl
make sync-check
```

`sync-check` prints the chain length found in all three places and fails if they
disagree. A `CFG_SCAN_LEN` that does not match the netlist means the chain is
never restored and the DUT dies on the first injection, with no error message.

Re-synthesis moves `L` and every `FI_Index`. Targets picked from an older
netlist are invalid.

---

## Stage 3 — gate-level simulation

### 3.1 Configure

```sh
cd sim
cp config.mk.example config.mk
$EDITOR config.mk
```

- `NETLIST` — from stage 2, or your existing one
- `STDCELL_MODELS` — your library's behavioural `.v`. Required.
- `MEM_MODELS` — a simulation model for each macro in the netlist. A plain
  behavioural module with the same port list is enough. The testbench
  back-door-loads the ROM through a hierarchical reference, so the model must
  hold its array in a 32-bit-wide reg. If it is not called `ram`, override the
  path:
  ```make
  DEFINES += +define+FI_ROM_MEM=u_tinyriscv_soc_top.u_rom.uMYROM.mem
  ```
- `DEFINES` — must match what you synthesised with, exactly.
- `UDP_MODELS` — only if your library ships its primitives separately
- `SDF` — leave empty. Timing-annotated runs are much slower and are not needed.

```sh
make echo-config     # check what it resolved before building
```

### 3.2 Run

```sh
make            # build and run
make wave       # same, dumping a waveform
make run        # re-run without rebuilding
```

The simulator opens the `remote_bitbang` TCP server and waits. Expect
`jtag0: Accepted client connection` once OpenOCD attaches. Leave it running.

---

## Stage 4 — drive the campaign

In a second shell:

```sh
openocd -f host/fi_openocd.cfg
```

`fi_openocd.cfg` creates the TAP, brings the target up, and sources the FI
procs. In a third shell:

```sh
telnet localhost 4444
> poll off
> fi_idcode
```

Run `poll off` first. Otherwise OpenOCD's background polling interleaves DMI
transactions with yours. `fi_idcode` tells you which TAP owns TDO: your DUT's own
IDCODE before the FI cutover, and `f17e0006` (the wrapper's) after.

### Trials

`fi_campaign` is the only entry point. One trial is
`{<FI_Cycle> {<FI_Index> ...}}`: an absolute injection cycle and the set of
flops to flip in it. Pick indices with
`grep <flop-name> syn/results/fi_scanmap.txt`.

```
> fi_campaign { {30000 {2354}} {90000 {2354}} {90000 {2354 2355 2356}} {150000 {17 600 4100}} }
> fi_mbu 90000 {2354 2355 2356}
```

`fi_mbu` is the single-shot form of one trial. Pass a second argument to
`fi_campaign` to set `CFG_TO_THR` yourself for a longer workload.

Keep the campaign on one line. Tcl does no comment processing inside `{ ... }`,
so a `;#` note between trials becomes a list element and `fi_campaign` rejects
the campaign with `got ';#'`. Annotate around the command, not inside the
braces.

One trial is one scan pass. An n-bit upset costs `L` shifts, not n·`L`. Bits in
the same trial flip together. Two trials at the same cycle stay two trials, with
separate resets and separate program runs.

Cycles are absolute, counted from reset release, on the same scale as
`fi_exec_window.txt`. Draw them from the `[exec start, exec end)` range printed
in stage 3.

Limits are checked before the first DMI write:

| limit | value |
|---|---|
| `Cycle_Offset` | 18 bits, max gap 262143 cycles between consecutive trials |
| `FI_Index` | 13 bits |
| FI Table | 256 entries |
| index past chain length | warns; it would flip nothing |

### Which log to score

Use `uart_txo.log`. It taps `uart_tx[0]`, the DUT's own UART output. The pad
(`stdout` and `uart_pad_fi.log`) also carries GPIO0 between reset and the
firmware's pinmux setup, which fabricates bytes. Keep the pad taps as a sanity
check.

### Check the campaign took

```
> fi_status_dump
```

Reads back `FI_VERSION`, `CFG_SCAN_LEN`, `CFG_TBL_LEN`, `CFG_FI_CYCLE`, the
running `FI_CYCLE` and `FI_STATUS`. Each register is read twice: the response
lags by one transaction, so the second value is the real one.

---

## Where it usually goes wrong

| symptom | cause |
|---|---|
| `make` in `sim/` errors about `NETLIST` / `STDCELL_MODELS` | no `config.mk`, or it is incomplete |
| thousands of undefined modules | `STDCELL_MODELS` wrong, or `MEM_MODELS` missing while the netlist uses macros |
| the DUT dies the moment FI is armed | the three files are out of sync. Run `make -C syn sync-check`. |
| nothing is injected at all | `CFG_TBL_LEN` (DMI `0x68`) was not written. `0x0000_0000` is a legal table entry, so the end of the table is a count, not a sentinel. |
| `FI_STATUS` bit 2 set (`err_order`) | a pattern's `FI_Index` values were not in descending order. Use `fi_pattern`, which sorts for you. |
| injection lands on the wrong flop | `FI_Index` taken from an older netlist, or from the SCANDEF instead of `fi_scanmap.txt` |
| telnet and OpenOCD both hang | a `runtest` count above ~8 in a host proc. 2 and 8 are known good; 80 and 100 kill the session. Unexplained. |
| garbled UART | compare `uart_txo.log` against `uart_pad_fi.log` first. Clean tx_o with dirty pad is the pad path, not the injection. |
| extra bytes only in `uart_pad_fi.log` / stdout | the firmware drives GPIO0 on a pad shared with UART0_TX before it sets `io0_mux`. Expected; score `uart_txo.log`. The `[PAD-EDGE]` lines say when. |
| a monitor keyed on `fi_rst` behaves like one keyed on `rst_ni` | it will, until a campaign is armed. `fi_rst = aon_rst_ni & ~resolver_rst_w` is combinational. |
| `fi_campaign` refuses to load | the message says which limit. A gap over 262143 cycles or over 256 entries means splitting the campaign in two. |

[syn/README.md](../syn/README.md) lists what the five synthesis invariants do
not cover.
