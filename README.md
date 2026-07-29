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

While the chain rotates, every flop on it holds someone else's data. So anything that must not be
disturbed is taken off the chain and clock-gated for exactly those `L` cycles instead.

> **Every flop is either shifted or frozen.** That one rule is what you configure when you port,
> and what the synthesis flow checks for you.

A campaign is a table, not a single shot. The host writes a list of entries and the wrapper walks
it on its own: inject, run, reset, next entry. Each entry carries a cycle offset. Several entries
can share one rotation to model a multi-bit upset.

---

## Running the example SoC

This needs commercial tools and your own PDK. **No foundry data is shipped**: no `.lib`/`.db`/
`.lef`, no memory macros, no netlist, no SDF.

| you supply | for |
|---|---|
| Synopsys Design Compiler | scan insertion |
| a standard-cell library, `.db` | synthesis |
| the same library's Verilog simulation model | gate-level simulation |
| VCS | gate-level simulation. The JTAG DPI bridge does not build under iverilog. |
| OpenOCD | driving the campaign |

The workload ships prebuilt, so no RISC-V toolchain is needed unless you change it.

**1. Fill in two config files.** Both are gitignored and contain paths only. Each has a commented
`.example` next to it.

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
make -C syn sync-check
```

`make dc` splices in the freeze gate, re-routes the frozen clock pins, runs `insert_dft`, checks
its own work, and writes the netlist plus the `FI_Index → flop` map to `syn/results/`. It also
writes a config file for the RTL and one for the host; copy those over, then `sync-check`
confirms all three agree on the chain length.

> A chain length that does not match the netlist means the chain is never restored and the DUT
> dies on the first injection, with no error message. [docs/RUNBOOK.md](docs/RUNBOOK.md) §2.4
> lists which file goes where.

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
`fi_exec_window.txt`. Pick targets with `grep <flop-name> syn/results/fi_scanmap.txt`.

> **A result belongs to one netlist and one seed.** Flops with no reset start at a random value,
> so `sim/Makefile` pins the seed (`SEED ?= 1`). Re-baseline after re-synthesising.

`make -C sim echo-config` prints the configuration as resolved. Check it first when a build fails.

---

## Porting to your own DUT

### Deciding what is shifted and what is frozen

That decision is the port. It lives in `syn/fi_scan_cfg.tcl`, the only file you edit:

```tcl
set FI_CLK_PORT   clk_50m_i        ;# free-running functional clock
set FI_RST_PORT   rst_ext_ni       ;# async reset, active low
set FI_GATE_PORT  scan_gate        ;# freeze request from the wrapper

set FI_GATE_PINS     { u_rom/clk_i u_ram/clk_i u_jtag/clk_i ... }   ;# frozen
set FI_EXEMPT        { u_rst uart0 }                                ;# neither
set FI_EXEMPT_CLOCKS { jtag_TCK }                                   ;# neither, by clock domain
```

Clock **pins**, not instances: a block with two clocks may need only one of them frozen. Anything
not listed is shifted.

`FI_EXEMPT` means "neither shifted nor frozen, and I take responsibility". It is legitimate for a
block that must keep running through the window, and for a clock domain that is idle during it.

The flow proves the rule holds. **On a new DUT it will fail on the first run**, listing every
register you have not classified yet, grouped by instance. Work the list, re-run, repeat. The
checks and their blind spots are in [syn/README.md](syn/README.md).

If you already have a Design Compiler flow you do not need `make dc`. Source `syn/scanchain.tcl`
into your own session after the first `compile_ultra`.

### What your DUT has to provide

| | requirement | if it is missing |
|---|---|---|
| 1 | a top-level freeze input, named in `FI_GATE_PORT` | the flow creates the port and warns; you then drive it from the level above |
| 2 | one free-running functional clock that already drives every pin in `FI_GATE_PINS` | the flow moves that block to another clock domain, permanently, and nothing catches it |
| 3 | an observation channel that survives the freeze | every trial returns garbage, after everything else has passed |

Item 3 is the one that costs design work. During an injection the frozen blocks lose exactly `L`
clock edges and the shifted flops hold someone else's data, so a peripheral mid-transmission emits
garbage. It needs a FIFO and a CDC into an ungated transmit domain, so the in-flight byte finishes
while the core is frozen. The example SoC uses `scan_uart_top`; the reusable, bus-free half is
`rtl/soc/perips/uart/cdc_rv_1deep.v`.

[docs/RUNBOOK.md](docs/RUNBOOK.md) §2.1 lists the remaining preconditions — reset polarity, the
testmode port, hierarchy, JTAG IR width — which are checks to run against your design rather than
things to build.

---

## Repository layout

| path | what |
|---|---|
| `rtl/fi/` | the wrapper: FI Transporter, FI Executor, the three controllers, the FI Table |
| `syn/` | the synthesis flow: freeze gate, scan exclusion, the checks, the `FI_Index → flop` map |
| `host/` | OpenOCD Tcl: DMI primitives, FI-entry encoder, ready-made campaigns |
| `tb/` | testbench for the example SoC, with UART observation taps |
| `tests/` | equivalence regression for the freeze gate, needs only `iverilog` |
| `sim/` | Makefile for the gate-level campaign |
| `firmware/` | the workload the campaign runs, prebuilt, with source |
| `rtl/soc/` | the example DUT, vendored from tinyriscv. Keeps its original Chinese comments; the wrapper and its flow are in English. |
| `docs/` | runbook and architecture description |

## Documentation

- **[docs/RUNBOOK.md](docs/RUNBOOK.md)** — clone to running campaign, step by step. **Start here.**
- **[docs/DESIGN.md](docs/DESIGN.md)** — architecture, DMI register map, FI table encoding
- **[syn/README.md](syn/README.md)** — the synthesis flow, and what the checks miss

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

Memory macros go the same way: write them as plain Verilog arrays and synthesis infers block RAM.

If you replace the freeze gate itself, run `tests/run.sh` afterwards. It checks that a substitute
still masks exactly `L` clock edges. One edge too many restores the chain perfectly and leaves
every frozen block one cycle out of phase, which nothing else will tell you.

## Licence

Apache-2.0, except where a file's own header says otherwise. Two vendored files
(`rtl/soc/utils/cdc_2phase.sv`, `rtl/soc/utils/sync_fifo.sv`) are under the Solderpad Hardware
License 0.51, which is Apache-2.0 plus a hardware clause. See [LICENSE](LICENSE) and
[NOTICE](NOTICE) for full third-party attribution.
