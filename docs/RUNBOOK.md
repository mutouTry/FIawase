# Runbook — from a clone to a running FI campaign

Concrete, ordered steps. Everything foundry-owned comes from two config files you
write; nothing here ships with the repository.

Read [syn/README.md](../syn/README.md) first if you already have a Design Compiler
flow — you can skip most of stage 2.

---

## What you need in hand

| | why |
|---|---|
| Design Compiler | scan insertion. Only for stage 2. |
| a standard cell library, `.db` | synthesis |
| the same library's **Verilog simulation model** | stage 3. A gate-level netlist is nothing but instances of these; without them every module in it is undefined. |
| VCS | stage 3. The campaign needs the JTAG DPI bridge, which iverilog cannot compile. |
| OpenOCD | stage 4 |
| macro `.db` **and** a simulation model for each memory the DUT instantiates | only if you synthesise with `T22NM` |

> **The memory model does not have to be the vendor's.** Synthesis needs the real
> `.db` so area and timing are real, but simulation only needs *something* with the
> same pin list and the same behaviour. A short hand-written stand-in works and is
> what the reference setup actually uses. See stage 3.

---

## Stage 0 — prove the invariant (30 seconds, no tools)

```sh
cd tests && ./run.sh
```

Expect `ALL PASS` over nine chain lengths. This drives the real `fi_scan_ctrl`
through real rotate-and-restore passes and checks the freeze window masks *exactly*
`L` clock edges. If this fails, nothing downstream is meaningful.

---

## Stage 1 — decide whether you need to synthesise at all

**If you already have a scan-inserted netlist of this DUT, skip stage 2.** Point
`sim/config.mk` at it and go to stage 3. This is the fastest way to prove the
simulation and host halves work, and it isolates any synthesis problem from
everything else.

The netlist must satisfy the contract in
[syn/README.md](../syn/README.md): one scan chain, the freeze gate present, the
frozen blocks off the chain. A netlist produced by an *earlier* run of
`scanchain.tcl` qualifies.

**If you do not have one, or you changed `FI_GATE_PINS`**, do stage 2.

---

## Stage 2 — synthesis

### 2.1 Configure

```sh
cd syn
cp tool_config.tcl.example tool_config.tcl
$EDITOR tool_config.tcl
```

Fill in, at minimum:

- `FI_SEARCH_PATH` — the directories holding your `.db` files
- `FI_TARGET_LIBRARY` — your standard cell `.db` at the corner you want
- `FI_LINK_LIBRARY` — `*` plus the standard cells plus **every macro `.db`**. A
  missing macro `.db` leaves a black box, and the scan chain is then built around a
  hole in the design.
- `FI_BUF_CELL` / `FI_BUF_CELL_PIN`, `FI_IO_CELL` / `FI_IO_CELL_PIN` — any
  reasonable buffer and input cell; only the example SDC uses them
- `FI_RTL_DEFINES` — keep `T22NM` if your memories are macros

Then [syn/fi_scan_cfg.tcl](../syn/fi_scan_cfg.tcl), which is the whole DUT-specific
surface. For the bundled tinyriscv example it is already correct; for your own DUT
set it **in this order**, because that is the order the flow dies in:

| | what | if it is wrong |
|---|---|---|
| 1 | `FI_CLK_PORT`, `FI_RST_PORT` | `FI-ERROR: port '...' not found on <top>` — this is where a first run actually stops |
| 2 | `FI_GATE_PORT` | your DUT's own name for the freeze input; if absent the flow creates it and warns, and you must drive it a level up |
| 3 | `FI_TESTMODE_PORT` | **must already exist on your DUT.** The flow creates `io_scanin/en/out` for you but not this one; a missing port is a Tcl error mid-run, and `dc_shell` does not stop on those |
| 4 | `FI_GATE_PINS` | clock **pins**, not instances. Each must already be driven by `FI_CLK_PORT` — the flow reconnects whatever it finds, without checking |
| 5 | `FI_EXEMPT`, `FI_EXEMPT_CLOCKS` | A3 tells you exactly what to put here on the first run. Every entry needs a written reason |
| 6 | `FI_N_FF` | power of two, `≥ L+1`; asserted by A4 |

Avoid Tcl glob metacharacters is no longer necessary — prefixes are matched
literally — but do use the instance path exactly as `report_scan_path` prints it.

**Before any of this**, your DUT's RTL has to satisfy the contract in
[README.md](../README.md#what-your-dut-has-to-provide) — in particular an
observation channel that survives a freeze. That is design work, not
configuration, and nothing in the flow will tell you it is missing.

### 2.2 Run

```sh
make dc
```

This runs `dc_fi.tcl`: analyze → elaborate → link → uniquify → SDC →
`compile_ultra` → then `scanchain.tcl`, which splices in the freeze gate, excludes
the frozen blocks, runs `insert_dft`, asserts five invariants, and exports the map.

**Reusing an existing mapped design instead.** If your flow already produced a
mapped `.ddc`, set `FI_INPUT_DDC` in `tool_config.tcl` and `make dc` skips
analyze/elaborate/compile entirely and just reads it back. That is the same shape as
`make dc && make dc_open_net && source scanchain.tcl` in a Reference-Methodology
flow, and it is much faster than a full resynthesis.

### 2.3 Read the verdict

The last thing printed is a PASS/FAIL banner. `make dc` exits non-zero if `FI-PASS`
is absent.

**A first run on a new DUT is expected to fail assertion A3** with a list of
registers that are neither shifted, nor frozen, nor exempt. That is the assertion
doing its job. Work through the list — each entry belongs in `FI_GATE_PINS`,
`FI_EXEMPT` or `FI_EXEMPT_CLOCKS` — and re-run. Write down why for each.

> `dc_shell`'s `source` does not stop on a Tcl error, so a failed run still writes a
> netlist. What protects you is that `fi_export_scanmap` refuses to write
> `fi_scan_cfg.vh` / `fi_scan_cfg.tcl` unless the checks passed. **If those two files
> are missing, do not use the netlist.**

### 2.4 What you get

In `results/`:

| file | goes where |
|---|---|
| `<top>.mapped.v` | `NETLIST` in `sim/config.mk` |
| `fi_scan_cfg.vh` | copy over `rtl/fi/fi_scan_cfg.vh` |
| `fi_scan_cfg.tcl` | its two values go into `host/tapename.tcl` |
| `fi_scanmap.txt` | `FI_Index → flop`; grep it to pick targets |
| `fi_scan_path.rpt` | the raw report the map was parsed from |

### 2.5 Sync the three files — do not skip this

```sh
cp results/fi_scan_cfg.vh ../rtl/fi/fi_scan_cfg.vh
$EDITOR ../host/tapename.tcl        # FI_SCAN_LEN and FI_W_IDX, from results/fi_scan_cfg.tcl
make sync-check
```

`sync-check` prints the chain length found in all three places and fails if they
disagree. **A `CFG_SCAN_LEN` that does not match the netlist means the chain is
never restored and the DUT dies on the first injection** — with no error message,
which is why this check exists.

Re-synthesis moves `L`, and it moves every `FI_Index`. Any target you calibrated
against an older netlist is invalid.

---

## Stage 3 — gate-level simulation

### 3.1 Configure

```sh
cd sim
cp config.mk.example config.mk
$EDITOR config.mk
```

- `NETLIST` — from stage 2 (or your existing one)
- `STDCELL_MODELS` — your library's behavioural `.v`. **Required**; `make` refuses
  to build without it rather than letting you discover it during elaboration.
- `MEM_MODELS` — a simulation model for each macro the netlist instantiates. This
  does **not** have to be the vendor's encrypted model: a plain behavioural module
  with the same port list is enough, and is what the reference setup uses. The
  testbench back-door-loads the ROM through a hierarchical reference, so whatever
  you supply must hold its array in a 32-bit-wide reg. If it is not called `ram`,
  override the path instead of editing the testbench:
  ```make
  DEFINES += +define+FI_ROM_MEM=u_tinyriscv_soc_top.u_rom.uMYROM.mem
  ```
- `DEFINES` — must match what you synthesised with. `T22NM` on both sides or neither.
- `UDP_MODELS` — only if your library ships its primitives separately
- `SDF` — leave empty. Timing-annotated runs are much slower and an injection is
  defined at a cycle boundary, so the campaign does not need them.

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

`fi_openocd.cfg` creates the TAP, brings the target up, and sources the FI procs
itself. In a third shell:

```sh
telnet localhost 4444
> poll off
> fi_idcode
```

`poll off` first — OpenOCD's background polling will otherwise interleave DMI
transactions with yours. `fi_idcode` returns `1e200a6f` before the FI cutover and
`f17e0006` after; it is the reliable way to tell which TAP owns TDO.

### Arbitrary cycles and arbitrary bits

`fi_campaign` is the only entry point, and one trial is
`{<FI_Cycle> {<FI_Index> ...}}`: an absolute injection cycle and the set of flops
to flip in it. Everything is a shape of that — one flop marching through time, a
multi-bit upset at one instant, a control run that flips nothing that matters.
Pick indices with `grep <flop-name> syn/results/fi_scanmap.txt`.

```
> fi_campaign { {30000 {2354}} {90000 {2354}} {90000 {2354 2355 2356}} {150000 {17 600 4100}} }
> fi_mbu 90000 {2354 2355 2356}
```

Four trials: an SBU early in the program, the same flop later, a 3-bit upset at
that same later cycle, and a 3-bit upset scattered across the chain. `fi_mbu` is
the single-shot form of one trial.

> Keep the campaign on **one line**. Tcl does no comment processing inside
> `{ ... }`, so a `;#` note between trials is not a comment — it becomes a list
> element and `fi_campaign` rejects the campaign with `got ';#'`. Annotate around
> the command, not inside the braces.

One trial is **one scan pass**, so an n-bit upset costs `L` shifts, not n·`L`. Bits
in the same trial flip together; two trials at the same cycle stay two trials —
separate resets, separate program runs — which is how you compare an SBU against an
MBU at the same instant.

Cycles are absolute, on the same scale as `fi_exec_window.txt` (counted from reset
release), so the `[exec start, exec end)` range printed in stage 3 is what to draw
from. The proc sorts the trials, converts the gaps into the hardware's
`Cycle_Offset` increments, picks `CFG_FI_CYCLE`, orders each pattern's indices
descending, and sizes `CFG_TO_THR`. Pass a second argument to set `CFG_TO_THR`
yourself for a longer workload.

Every limit is checked **before** the first DMI write, so a campaign that does not
fit is refused rather than half-loaded: `Cycle_Offset` is 18 bits (max gap 262143
cycles between consecutive trials), `FI_Index` is 13 bits, the FI Table holds 256
entries, and an index past the chain length warns because it would flip nothing.

### Which log to score

Use **`uart_txo.log`**. It taps `uart_tx[0]`, the DUT's own UART output. The pad
(`stdout` and `uart_pad_fi.log`) additionally carries GPIO0 between reset and the
firmware's pinmux setup, which fabricates bytes that no monitor reset can remove.
See [DEBUG_NOTES.md](DEBUG_NOTES.md) A.3; keep the pad taps as a sanity check.

Check it took:

```
> fi_status_dump
```

Reads back `FI_VERSION`, `CFG_SCAN_LEN`, `CFG_TBL_LEN`, `CFG_FI_CYCLE`, the running
`FI_CYCLE` and `FI_STATUS`. Each register is read twice on purpose — the response
lags by one transaction, so the second value is the real one.

---

## Where it usually goes wrong

| symptom | cause |
|---|---|
| `make` in `sim/` errors about `NETLIST` / `STDCELL_MODELS` | no `config.mk`, or it is incomplete. That is the guard working. |
| thousands of undefined modules | `STDCELL_MODELS` wrong, or `MEM_MODELS` missing while `T22NM` is defined |
| the DUT dies the moment FI is armed | the three files are out of sync. `make -C syn sync-check`. |
| nothing is injected at all | `CFG_TBL_LEN` (DMI `0x68`) was not written. `0x0000_0000` is a legal table entry, so the end of the table is a **count**, not a sentinel. |
| `FI_STATUS` bit 2 set (`err_order`) | a pattern's `FI_Index` values were not in descending order. Use `fi_pattern`, which sorts for you. |
| injection lands on the wrong flop | `FI_Index` taken from an older netlist, or from the SCANDEF instead of `fi_scanmap.txt` |
| telnet and OpenOCD both hang | a `runtest` count above ~8 in a host proc. Unexplained; see pitfall #7 in [DEBUG_NOTES.md](DEBUG_NOTES.md). |
| garbled UART | see [DEBUG_NOTES.md](DEBUG_NOTES.md) A.3. Compare `uart_txo.log` against `uart_pad_fi.log` first: clean tx_o + dirty pad is the pad path, not the injection. |
| extra bytes only in `uart_pad_fi.log` / stdout | the firmware drives GPIO0 on a pad shared with UART0_TX before it sets `io0_mux`. Expected; score `uart_txo.log`. The `[PAD-EDGE]` lines say exactly when. |
| a monitor keyed on `fi_rst` behaves exactly like one keyed on `rst_ni` | it will, until a campaign is armed — `fi_rst = aon_rst_ni & ~resolver_rst_w` is combinational. A bare run proves nothing about it. |
| `fi_campaign` refuses to load | it validates before writing anything, and the message says which limit. A gap over 262143 cycles or over 256 entries means splitting the campaign in two. |

[docs/DEBUG_NOTES.md](DEBUG_NOTES.md) has the waveform probe points and a numbered
list of every pitfall hit so far. Read it before debugging anything.
