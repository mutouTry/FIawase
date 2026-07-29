# FIawase

A **sustained hardware fault-injection wrapper** for RISC-V SoCs. It bolts onto an
existing DUT, borrows the DUT's own scan chain, and flips bits in real flops while
the processor runs — thousands of trials per simulation, driven from a host over
JTAG.

The wrapper itself adds **no fault-injection logic inside your design**: all of the
clock gating it needs is spliced into the netlist by the synthesis flow, not written
into RTL. What the DUT does have to provide is a small, explicit contract — one
freeze input, the scan ports, and a reset it will accept — plus whatever it takes to
keep an observation channel alive across a freeze. In the example SoC that second
part meant one real modification: `uart0` was replaced with a FIFO+CDC variant so the
UART keeps transmitting while the core is frozen. Budget for the equivalent in your
design; see [docs/DESIGN.md §6](docs/DESIGN.md) and [NOTICE](NOTICE).

It was built around [tinyriscv](https://gitee.com/liangkangnan/tinyriscv), which
ships here as a worked example, but the wrapper itself is DUT-independent.

> **Status: usable, not polished.** It is verified in gate-level simulation on one
> SoC and one PDK. Expect to iterate the first time you port it.

---

## How it works

The wrapper does not add fault-injection hardware to your logic. It reuses the
scan chain that DFT insertion already built:

```
        ┌── host (OpenOCD/telnet) ── JTAG ──┐
        │                                   ▼
        │              ┌─────────── fi_wrapper_top ───────────┐
        │              │  FI Transporter: TAP → DTM → CDC → DMI│
        │              │  FI Executor:  time / scan / table    │
        │              └───────┬──────────────────┬───────────┘
        │      Scan_In/En/Out  │                  │ Clk_Gate
        │                      ▼                  ▼
        └──────────────  ┌──── DUT ────────────────────┐
                         │ scan chain (L flops)        │  shifted and restored
                         │ frozen blocks (ROM/RAM/...) │  clock-gated, untouched
                         └─────────────────────────────┘
```

One injection is **one rotation of the chain**: shift `L` times, invert the bit as
it passes the scan-out pin, and after `L` steps every flop is back where it was
except the targeted one. The DUT then keeps executing from a state that differs by
exactly the injected fault.

Blocks that must not be disturbed (memories, the debug TAP, the pad mux) are
**clock-gated** for exactly the same `L` cycles instead of being shifted. Getting
that edge account wrong by even one cycle makes the chain unrestorable, so the
synthesis flow asserts it (see below) and a simulation regression proves the gate
itself is cycle-equivalent to the reference implementation.

A campaign is a **table**, not a single shot. The host writes a list of entries;
the wrapper walks it autonomously — inject, let the program run, reset, next entry
— so a single simulation covers a whole batch. Each entry carries a cycle offset,
so one table can sweep the same fault across time, and several entries can share
one rotation to model a multi-bit upset.

---

## Repository layout

| path | what |
|---|---|
| `rtl/fi/` | **the wrapper.** FI Transporter, FI Executor, the three controllers, the FI Table |
| `syn/` | **the synthesis-side flow.** Inserts the freeze gate, keeps frozen blocks off the chain, asserts the invariants, exports the `FI_Index → flop` map |
| `host/` | OpenOCD Tcl: the DMI primitives, the FI-entry encoder, ready-made campaigns |
| `tb/` | testbench for the example SoC, with UART observation taps |
| `tests/` | self-checking regression for the freeze gate — needs only `iverilog` |
| `sim/` | Makefile for the gate-level campaign (point `NETLIST=` at your own netlist) |
| `firmware/` | the workload the campaign runs, with source |
| `rtl/soc/` | the example DUT (tinyriscv SoC), vendored — see note below |
| `docs/` | the runbook and the architecture description |

---

## What you need

|  | for what | required? |
|---|---|---|
| `iverilog` | the gate regression in `tests/` | no other tool needed |
| Synopsys Design Compiler | scan insertion + the flow in `syn/` | yes, for the gate-level path |
| a standard-cell library | synthesis | yes — **bring your own, none is shipped** |
| a Verilog simulator (VCS…) | the gate-level campaign | yes |
| OpenOCD | driving the wrapper over JTAG | yes |
| a RISC-V toolchain | building firmware for the example SoC | only for the example |

**No foundry data is distributed with this repository** — no `.lib`/`.db`/`.lef`,
no memory macros, no gate-level netlist, no SDF. That is a deliberate licensing
boundary, and it means the gate-level flow is not reproducible out of the box:
you run synthesis with your own PDK. See [NOTICE](NOTICE).

**Two config files stand between a clone and a run.** Both are gitignored, both
have a checked-in, fully commented `.example` next to them, and neither contains
anything but paths — copy, point at your own environment, done. No file in this
repository hard-codes an absolute path.

| copy this | to this | and fill in |
|---|---|---|
| `syn/tool_config.tcl.example` | `syn/tool_config.tcl` | your `.db` libraries, the RTL directories, the SDC |
| `sim/config.mk.example` | `sim/config.mk` | your netlist, your standard-cell and SRAM **simulation models**, defines |

A gate-level netlist is nothing but instances of your standard cells, so
`sim/config.mk` needs their behavioural `.v` models as well as the netlist —
without them every module in it is undefined. `sim/Makefile` fails immediately
and says so rather than letting elaboration discover it.

**If your tools live behind a container or a site wrapper**, say so in the same
two places — both take a full command, not just a path, so anything that ends up
exec'ing the tool works:

```make
# sim/config.mk
VCS := singularity exec /path/to/vcs.sif vcs
```
```sh
# synthesis: dc_shell has to be running before it can read tool_config.tcl,
# so this one is a make variable rather than a line in that file
make -C syn dc DC_SHELL='singularity exec /path/to/syn.sif dc_shell'
```

`make -C sim echo-config` prints everything as resolved. It is the first thing
to check when a build fails.

The example SoC's memories have a behavioural fallback: with `T22NM` **not**
defined, `rom.sv`/`ram.sv` instantiate `gen_ram` instead of macros, so the
design elaborates from a bare clone with no PDK memories at all. That path is
convenient for a first look but is **not** what any result here was measured
on, and 16k×32 of inferred flops makes synthesis impractical — the shipped
configs define `T22NM`. It is one switch, in `DEFINES` / `FI_RTL_DEFINES`, and
it has to match between synthesis and simulation.

> **A note on `rtl/soc/`.** It is vendored from upstream tinyriscv and keeps that
> project's original Chinese source comments, deliberately: rewriting them would
> produce a large gratuitous diff against upstream and make future syncs harder,
> for code that is an *example* here rather than part of the wrapper. Everything
> under `rtl/fi/`, `syn/`, `host/`, `tb/` and `tests/` — the wrapper itself and its
> flow — is English.

---

## Quick start

**1. Prove the freeze gate — 30 seconds, `iverilog` only**

```sh
cd tests && ./run.sh
```

Drives the real `fi_scan_ctrl` through real rotate-and-restore passes and
checks, for chain lengths from 1 to 4143, that the freeze window masks *exactly*
`L` clock edges and that the chain comes back bit-perfect. This is the invariant
everything else rests on.

**2. Synthesise with scan + the freeze gate**

Edit `syn/fi_scan_cfg.tcl` — that is the only file that is DUT-specific:

```tcl
set FI_CLK_PORT   clk_50m_i        ;# free-running functional clock
set FI_RST_PORT   rst_ext_ni       ;# async reset, active low
set FI_GATE_PORT  scan_gate        ;# freeze request from the wrapper

set FI_GATE_PINS { u_rom/clk_i u_ram/clk_i u_jtag/clk_i uart0/clk_i ... }
set FI_EXEMPT        { u_rst uart0 }
set FI_EXEMPT_CLOCKS { jtag_TCK }
```

Then either source `syn/scanchain.tcl` into your own DC session after the first
`compile_ultra`, or use the bundled driver:

```sh
cd syn
cp tool_config.tcl.example tool_config.tcl   # your libraries and paths
make dc
```

Either way it will:

1. compile `syn/fi_clk_gate.v` and splice one instance into the netlist,
2. re-route every pin in `FI_GATE_PINS` onto the gated clock,
3. keep those blocks off the scan chain (`set_scan_element false`),
4. run `insert_dft`,
5. **assert five invariants** and fail loudly if any is violated,
6. export `fi_scanmap.txt` (`FI_Index → flop`) plus matching config for the RTL and the
   host.

### What your DUT has to provide

The freeze input is the only thing you *add*; the rest are properties your design
has to already have. Check these before you start — most are unverifiable by the
flow, so getting one wrong shows up much later as a broken campaign, not as a
synthesis error.

| | requirement | if it is wrong |
|---|---|---|
| 1 | a top-level **freeze input**, named in `FI_GATE_PORT`, launched by a clock 1:1 synchronous with the functional clock | the L-edge account collapses; nothing checks it |
| 2 | one **free-running functional clock port** that already drives *every* pin in `FI_GATE_PINS`, undivided | the flow silently re-domains that block, permanently |
| 3 | exactly **one** clock domain needs freezing | two are inexpressible; listing both shorts them together |
| 4 | an **active-low** async reset | hardcoded in four places; three simultaneous breakages |
| 5 | a **testmode input that already exists** | Tcl error mid-run, and `dc_shell` does not stop on it |
| 6 | hierarchy that **survives both compiles** (`-no_autoungroup`) | the `FI_Index → flop` map becomes meaningless |
| 7 | every stateful **black-box macro** under a frozen instance | `all_registers` cannot see them, so A3 cannot either |
| 8 | a JTAG TAP with a **5-bit IR**; TRSTn wired outside the wrapper | cutover never happens and every later write vanishes |
| 9 | an **observation channel that survives a freeze** — see below | every trial returns garbage, after everything else passes |

Item 9 is the one that costs real design work. During an injection the frozen set
loses exactly `L` clock edges and the shifted set is scrambled for `L` cycles, so
any peripheral mid-transmission emits garbage. It needs a **FIFO plus a CDC into
an ungated transmit domain**, so the in-flight byte finishes while the core is
frozen. In the example SoC that is `scan_uart_top`; the reusable, bus-free half is
`rtl/soc/perips/uart/cdc_rv_1deep.v`. Anything in the output path that is *not*
CDC'd must be frozen instead — `u_pinmux` is in `FI_GATE_PINS` purely because
shifting it scrambles the pad mux.

Item 1 is the only port the flow will create for you if it is missing (with a
warning); you then have to drive it from the level above.

**3. Run a campaign**

```sh
cd sim
cp config.mk.example config.mk               # netlist + cell models
make                                         # builds and starts the simulator
```

```sh
openocd -f host/fi_openocd.cfg   # in a second shell
telnet localhost 4444            # in a third
> poll off
> fi_campaign { {30000 {2354}} {90000 {2354}} {90000 {2354 2355 2356}} }
```

One trial is `{<cycle> {<FI_Index> ...}}` — when to inject, and which flops to
flip. That is the whole interface: the three trials above are the same flop
early, the same flop later, and a 3-bit upset at the same instant as the second.
All of a trial's bits are flipped in **one** scan pass, so an n-bit upset costs
`L` cycles, not `n*L`.

Cycles are absolute, counted from reset release — the same ruler the testbench
prints in `fi_exec_window.txt`, which is how you find the legal range for your
workload. `grep <flop-name> fi_scanmap.txt` finds the `FI_Index` for any flop.

> **A result belongs to one netlist and one seed.** Uninitialised flops are
> randomised, and this DUT has 992 of them, so `sim/Makefile` pins the seed
> (`SEED ?= 1`) — without that the same campaign returns different verdicts every
> run. Re-baseline after re-synthesising: two netlists built from the same RTL
> differ in which flops reset clears, which is enough to change a marginal
> outcome. `make SEED=2` re-runs the same faults from a different initial state,
> and a trial whose class moves is one that depends on state the workload never
> wrote.

> **The netlist, `rtl/fi/fi_scan_cfg.vh` and `host/tapename.tcl` must agree on
> the chain length.** Synthesis emits the first two for you; `make -C syn
> sync-check` tells you whether all three currently match. A mismatch means the
> chain is never restored and the DUT dies on the first injection.

---

## The five synthesis invariants

Every flop must be either **shifted** (on the chain, restored by rotation) or
**frozen** (clock-gated, untouched). Anything else is silently broken at run time —
the symptom is "the DUT dies the moment FI is armed", with nothing wrong at
synthesis. So the flow proves it instead:

| | check | catches |
|---|---|---|
| A1 | every pin in `FI_GATE_PINS` is really on the gated clock | the declaration and the netlist disagreeing |
| A2 | **no flop is both frozen and on the chain** | the chain becoming unrestorable |
| A3 | every register is shifted, frozen, or explicitly exempt | a block nobody accounted for |
| A4 | `L` still fits the table encoding | injecting at the wrong index |
| A5 | DFT did not rewire the gated clock | `-fix_clock` quietly undoing the freeze |

A3 failing on a new DUT is normal and useful: it prints, grouped by instance,
exactly what you have not classified yet. Foreign clock domains that are idle
during the window (a debug TAP, an RTC) go in `FI_EXEMPT_CLOCKS`.

A2 is computed from the scan-path report and instance path strings only — no
netlist traversal — precisely so it cannot go green for the wrong reason.

**Know what these five do not cover.** A1 asks whether a frozen pin is on the
gated net, which the flow connected itself a moment earlier — so it proves the
connection survived DFT, not that the pin belonged there. Nothing checks reset
polarity, clock domains, or stateful black boxes. The full list, ordered by how
quietly each one fails, is in [syn/README.md](syn/README.md) — read it before
your first campaign, not after.

---

## Documentation

- **[docs/RUNBOOK.md](docs/RUNBOOK.md)** — the ordered steps from a clone to a
  running campaign, and what usually goes wrong. **Start here.**
- **[docs/DESIGN.md](docs/DESIGN.md)** — architecture, the DMI register map, the
  clock-gate contract, the FI table encoding
- **[syn/README.md](syn/README.md)** — the two ways into the synthesis flow, and
  what the five invariants do *not* cover

---


## Licence

Apache-2.0, except where a file's own header says otherwise. Two vendored
files (`rtl/soc/utils/cdc_2phase.sv`, `rtl/soc/utils/sync_fifo.sv`) are under
the Solderpad Hardware License 0.51, which is Apache-2.0 plus a hardware
clause. See [LICENSE](LICENSE) and [NOTICE](NOTICE) for full third-party
attribution.
