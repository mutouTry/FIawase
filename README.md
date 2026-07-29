# FIawase

A sustained hardware fault-injection wrapper for RISC-V SoCs. It attaches to an existing DUT,
reuses the DUT's own scan chain, and flips bits in real flops while the processor runs. A host
drives it over JTAG. One simulation runs thousands of trials.

The wrapper adds no fault-injection logic to your design. The synthesis flow splices the clock
gating it needs into the netlist. The example DUT is
[tinyriscv](https://gitee.com/liangkangnan/tinyriscv); the wrapper itself is DUT-independent.

> **Status: usable, not polished.** Verified in gate-level simulation on one SoC and one PDK.
> Expect to iterate the first time you port it.

---

## How it works

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

One injection is one rotation of the chain. Shift `L` times and invert the bit as it passes the
scan-out pin. After `L` steps every flop is back where it was, except the targeted one.

Blocks that must not be disturbed (memories, the debug TAP, the pad mux) are clock-gated for the
same `L` cycles instead of being shifted. The edge count must be exact. An error of one cycle
makes the chain unrestorable.

A campaign is a table, not a single shot. The host writes a list of entries and the wrapper walks
it on its own: inject, run, reset, next entry. Each entry carries a cycle offset. Several entries
can share one rotation to model a multi-bit upset.

---

## Try it — 30 seconds, `iverilog` only

```sh
cd tests && ./run.sh
```

Over nine chain lengths this checks that the freeze window masks exactly `L` clock edges and that
the chain comes back bit-perfect. It is the one thing here that needs no PDK and no licence.

---

## Running the example SoC

This part needs commercial tools and your own PDK. **No foundry data is shipped**: no
`.lib`/`.db`/`.lef`, no memory macros, no netlist, no SDF.

| you supply | for |
|---|---|
| Synopsys Design Compiler | scan insertion |
| a standard-cell library, `.db` | synthesis |
| the same library's Verilog simulation model | gate-level simulation |
| VCS | gate-level simulation. The JTAG DPI bridge does not build under iverilog. |
| OpenOCD | driving the campaign |

The workload ships prebuilt, so no RISC-V toolchain is needed unless you change it.

**1. Fill in two config files.** Both are gitignored and contain paths only. Each has a
commented `.example` next to it.

```sh
cp syn/tool_config.tcl.example syn/tool_config.tcl   # .db libraries, RTL dirs, SDC
cp sim/config.mk.example       sim/config.mk         # netlist, cell + memory sim models
```

- If your DUT instantiates memory macros, supply their `.db` for synthesis and their `.v` model
  for simulation.
- The RTL defines must be the same on both sides. Synthesising with one set and simulating with
  another gives a netlist the testbench cannot drive.
- Both files take a full command, so tools behind a container or a site wrapper work:

  ```make
  VCS := singularity exec /path/to/vcs.sif vcs         # in sim/config.mk
  ```
  ```sh
  make -C syn dc DC_SHELL='singularity exec /path/to/syn.sif dc_shell'
  ```

**2. Synthesise.**

```sh
make -C syn dc
```

This splices in the freeze gate, re-routes the frozen clock pins, runs `insert_dft`, asserts the
five invariants, and writes the netlist, the `FI_Index → flop` map (`fi_scanmap.txt`), and a
config file for the RTL and one for the host into `syn/results/`. Copy those two over, then:

```sh
make -C syn sync-check     # confirms the three places agree on the chain length
```

> The netlist, `rtl/fi/fi_scan_cfg.vh` and `host/tapename.tcl` must agree on the chain length.
> A mismatch means the chain is never restored and the DUT dies on the first injection.
> [docs/RUNBOOK.md](docs/RUNBOOK.md) §2.4 lists exactly which file goes where.

**3. Run a campaign.**

```sh
make -C sim                      # builds and starts the simulator
```
```sh
openocd -f host/fi_openocd.cfg   # second shell
telnet localhost 4444            # third shell
> poll off
> fi_campaign { {30000 {2354}} {90000 {2354}} {90000 {2354 2355 2356}} }
```

One trial is `{<cycle> {<FI_Index> ...}}`: when to inject, and which flops to flip. The three
above are the same flop early, the same flop later, and a 3-bit upset at the same instant as the
second. All of a trial's bits are flipped in one scan pass, so an n-bit upset costs `L` cycles,
not `n*L`. Those index numbers are for the example netlist; yours will differ.

Cycles are absolute, counted from reset release. The testbench prints the same ruler in
`fi_exec_window.txt`. Use it to find the legal range for your workload.

> **A result belongs to one netlist and one seed.** Flops with no reset start at a random value,
> so `sim/Makefile` pins the seed (`SEED ?= 1`). Re-baseline after re-synthesising. `make SEED=2`
> re-runs the same faults from a different initial state.

`make -C sim echo-config` prints the configuration as resolved. Check it first when a build fails.

---

## Porting to your own DUT

### What your DUT has to provide

You add the freeze input. The rest are properties your design must already have. The flow cannot
check most of them. A wrong one shows up later as a broken campaign, not as a synthesis error.

| | requirement | if it is wrong |
|---|---|---|
| 1 | a top-level freeze input, named in `FI_GATE_PORT`, launched by a clock 1:1 synchronous with the functional clock | the `L`-edge count breaks, and nothing checks it |
| 2 | one free-running functional clock port that already drives every pin in `FI_GATE_PINS`, undivided | the flow silently moves that block to another clock domain, permanently |
| 3 | exactly one clock domain that needs freezing | two cannot be expressed; listing both shorts them together |
| 4 | an active-low async reset | it is hardcoded in four places; three breakages at once |
| 5 | a testmode input that already exists | Tcl error mid-run, and `dc_shell` does not stop on it |
| 6 | hierarchy that survives both compiles (`-no_autoungroup`) | the `FI_Index → flop` map becomes meaningless |
| 7 | every stateful black-box macro under a frozen instance | `all_registers` cannot see them, so A3 cannot either |
| 8 | a JTAG TAP with a 5-bit IR, TRSTn wired outside the wrapper | cutover never happens and every later write is lost |
| 9 | an observation channel that survives a freeze | every trial returns garbage, after everything else passes |

Item 1 is the only port the flow creates for you if it is missing. It prints a warning, and you
drive that port from the level above.

Item 9 costs real design work. During an injection the frozen set loses exactly `L` clock edges
and the shifted set is scrambled for `L` cycles, so any peripheral mid-transmission emits garbage.
The channel needs a FIFO plus a CDC into an ungated transmit domain, so the in-flight byte
finishes while the core is frozen. The example SoC uses `scan_uart_top`; the reusable, bus-free
half is `rtl/soc/perips/uart/cdc_rv_1deep.v`. Anything in the output path that is not CDC'd must
be frozen instead. `u_pinmux` is in `FI_GATE_PINS` because shifting it scrambles the pad mux.

### The one file you edit

`syn/fi_scan_cfg.tcl`. Everything else in `syn/` is DUT-independent.

```tcl
set FI_CLK_PORT   clk_50m_i        ;# free-running functional clock
set FI_RST_PORT   rst_ext_ni       ;# async reset, active low
set FI_GATE_PORT  scan_gate        ;# freeze request from the wrapper

set FI_GATE_PINS { u_rom/clk_i u_ram/clk_i u_jtag/clk_i uart0/clk_i ... }
set FI_EXEMPT        { u_rst uart0 }
set FI_EXEMPT_CLOCKS { jtag_TCK }
```

If you already have a Design Compiler flow, you do not need `make dc`. Source
`syn/scanchain.tcl` into your own session after the first `compile_ultra`.

### The five synthesis invariants

Every flop must be either shifted (on the chain) or frozen (clock-gated). Anything else breaks
silently at run time: the DUT dies the moment FI is armed, with nothing wrong at synthesis.

| | check | catches |
|---|---|---|
| A1 | every pin in `FI_GATE_PINS` is really on the gated clock | the declaration and the netlist disagreeing |
| A2 | no flop is both frozen and on the chain | the chain becoming unrestorable |
| A3 | every register is shifted, frozen, or explicitly exempt | a block nobody accounted for |
| A4 | `L` still fits the table encoding | injecting at the wrong index |
| A5 | DFT did not rewire the gated clock | `-fix_clock` quietly undoing the freeze |

A3 failing on a new DUT is normal. It lists, grouped by instance, what you have not classified
yet. Idle foreign clock domains (a debug TAP, an RTC) go in `FI_EXEMPT_CLOCKS`.

These five do not cover everything. Nothing checks reset polarity, clock domains, or stateful
black boxes. See [syn/README.md](syn/README.md).

---

## Taking it to an FPGA

Import two things into Vivado as RTL:

1. the scan-inserted netlist from `syn/results/`
2. your standard cell library, rewritten as plain synthesisable Verilog

The netlist is only cell instances, so Vivado maps it to LUTs and flops like any other RTL. The
scan chain comes with it and `fi_scanmap.txt` stays valid.

The rewrite is one small module per cell. Vendor simulation models use `specify` blocks, UDPs and
timing checks that synthesis rejects; write the function instead:

```verilog
module AOI22D1 (A1, A2, B1, B2, ZN);
    output ZN;  input A1, A2, B1, B2;
    assign ZN = ~((A1 & A2) | (B1 & B2));
endmodule

module SDFQD1 (SI, D, SE, CP, Q);       // a scan flop is a 2:1 mux and a flop
    output reg Q;  input SI, D, SE, CP;
    always @(posedge CP) Q <= SE ? SI : D;
endmodule
```

Two more substitutions:

- each memory macro instance needs a block-RAM wrapper with the same ports
- use `BUFGCE` for the freeze gate. Latch-plus-AND is not an FPGA clock primitive. The frozen
  blocks must still lose exactly `L` edges; check any substitute with `tests/run.sh`.

---

## Repository layout

| path | what |
|---|---|
| `rtl/fi/` | the wrapper: FI Transporter, FI Executor, the three controllers, the FI Table |
| `syn/` | the synthesis flow: freeze gate, scan exclusion, the invariants, the `FI_Index → flop` map |
| `host/` | OpenOCD Tcl: DMI primitives, FI-entry encoder, ready-made campaigns |
| `tb/` | testbench for the example SoC, with UART observation taps |
| `tests/` | self-checking regression for the freeze gate, needs only `iverilog` |
| `sim/` | Makefile for the gate-level campaign |
| `firmware/` | the workload the campaign runs, prebuilt, with source |
| `rtl/soc/` | the example DUT, vendored from tinyriscv. Keeps its original Chinese comments; the wrapper and its flow are in English. |
| `docs/` | runbook and architecture description |

## Documentation

- **[docs/RUNBOOK.md](docs/RUNBOOK.md)** — clone to running campaign, step by step. **Start here.**
- **[docs/DESIGN.md](docs/DESIGN.md)** — architecture, DMI register map, FI table encoding
- **[syn/README.md](syn/README.md)** — the synthesis flow, and what the invariants miss

## Licence

Apache-2.0, except where a file's own header says otherwise. Two vendored files
(`rtl/soc/utils/cdc_2phase.sv`, `rtl/soc/utils/sync_fifo.sv`) are under the Solderpad Hardware
License 0.51, which is Apache-2.0 plus a hardware clause. See [LICENSE](LICENSE) and
[NOTICE](NOTICE) for full third-party attribution.
