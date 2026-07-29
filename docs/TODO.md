# Known issues and open work

Grouped by what they block. Every item names the evidence that produced it.

---

## P0 — blocks FPGA / silicon

### 🟢 Freeze gate, scan exclusion, invariants, export — landed and verified

The DUT's RTL contains no clock gating at all any more; the freeze gate is inserted
into the netlist by the synthesis flow. Files:

| file | role |
|---|---|
| [syn/fi_scan_cfg.tcl](../syn/fi_scan_cfg.tcl) | **the single source of truth**: `FI_GATE_PINS`, `FI_EXEMPT`, `FI_EXEMPT_CLOCKS`, `FI_N_FF`, port names. The only file you edit per DUT |
| [syn/fi_clk_gate.v](../syn/fi_clk_gate.v) | portable gate: one synchroniser flop + negative-level latch + AND. No library cell names |
| [syn/fi_scan_lib.tcl](../syn/fi_scan_lib.tcl) | `fi_insert_clock_gate` / `fi_apply_scan_exclusion` / `fi_check_invariants` / `fi_export_scanmap` / `fi_report` |
| [syn/scanchain.tcl](../syn/scanchain.tcl) | example DC script; the nine `set_dont_touch` lines it used to carry are gone |

What this fixed:

- **Gating and scan exclusion used to be two lists** — the gate was written in RTL,
  the exclusion in tcl — and they had silently drifted apart. Now there is one list,
  and assertion A2 refuses to let them diverge again.
- **Combinational gating replaced by a latch-based gate.** No runt pulse. It
  deliberately does **not** name a library ICG, which would tie the flow to one PDK;
  swap the contents of `fi_clk_gate.v` if you want your library's cell.
- **The pad mux is now frozen** along with the ROM, RAM, debug TAP, SPI, XIP and boot
  ROM.

**Measured result of the first clean run:**

```
chain length L = 4143
register partition: on chain 4143 + frozen 1187 + exempt clock 234
                    + exempt instance 323 + gate itself 2   = 5889
                    orphans 0
all five invariants pass
```

Calibration was re-done afterwards against a live injection: flipping `FI_Index = 2354`
changed `u_gpr_reg/gpr_rw_2/qout` by exactly `0x20` (bit 5) while the control flop
`gpr_rw_3/qout` was unchanged across the scan window — i.e. the chain was restored
bit-perfect and only the target moved.

### Edge-account equivalence — measured, not argued

[tests/run.sh](../tests/run.sh) drives the real `fi_scan_ctrl` and both real gate
modules through real rotate-and-restore passes:

| gate | cycles masked | short pulses |
|---|---|---|
| `clk & ~gate_q` (the combinational form being replaced) | **L** ✅ | 1 (a runt at the window start, width = t_co) |
| ICG with `E = ~gate_q` | **L+1** ❌ | 0 |
| ICG with `E = ~(gate_q & clk_gate)` (used) | **L** ✅ | **0** |

`L ∈ {1,2,3,5,8,17,64,257,4143}` over one or two passes: the two working gates mask
**the same cycles with zero disagreement**, and the chain restores bit-perfect every
time.

> An ICG decides per edge from the enable during the preceding low phase, so using
> the registered `gate_q` alone masks **one cycle too many** — the off-chain blocks
> would come back one cycle behind everything else. The enable has to **engage on the
> registered version and release on the raw one**. That is not obvious, which is why
> there is a regression for it. Re-run it after touching `fi_clk_gate.v` or
> `fi_scan_ctrl.v`.

### The five invariants

Checked by `fi_check_invariants` after `insert_dft`; any failure raises an error.

| | check | what it catches |
|---|---|---|
| A1 | every pin in `FI_GATE_PINS` is really driven by `fi_clk_gated` | the declaration and the netlist disagreeing |
| A2 | no cell is both under a frozen instance and on the chain | **the core one**: an unrestorable chain |
| A3 | every register is on the chain, frozen, or explicitly exempt | a block nobody classified |
| A4 | `L ≤ FI_N_FF − 1` | FI_Entry field overflow |
| A5 | `fi_clk_gated` carries only the gate output and the declared loads | `-fix_clock` quietly undoing the freeze |

**A2** is computed only from the scan-path report and instance path strings — no
netlist traversal, no clock query — specifically so it cannot go green for the
wrong reason. See pitfall #22 in [DEBUG_NOTES.md](DEBUG_NOTES.md) for what happened
when it was not.

**A1 is not**, despite what this file and README used to claim: it resolves each
`FI_GATE_PINS` entry with `get_pins` and follows the net. That is unavoidable —
the question it asks is a netlist question — but it means A1 can pass *by
construction*, because the flow itself connected those pins to the gated net a
moment earlier. A1 proves the connection survived DFT; it cannot tell you the pin
should have been on that net in the first place.

**A3 will normally fail the first time on a new DUT**, and that is the point: it
prints, grouped by instance, everything you have not classified yet. Each hit goes
into `FI_GATE_PINS`, `FI_EXEMPT`, or `FI_EXEMPT_CLOCKS`, with a reason written next
to it.

### The general rule this all serves

> For any output that must stay continuous across the scan window, **every stage from
> the register that produces it to the chip pin must be off the chain and frozen.**
> A combinational datapath is not enough — if that stage's **control** (a mux select,
> an enable, an output enable) comes from a flop on the chain, the path is broken.

---

## P1 — blocks portability

### The DUT-independent half is not as DUT-independent as it claims

*From a systematic audit of the porting surface. Each item was checked against the
code; the ones that were fixed are not listed.*

Hardcoded in files that carry no knob for them, and absent from
`syn/fi_scan_cfg.tcl`:

| what | where | consequence for a DUT that differs |
|---|---|---|
| active-low reset | `syn/fi_clk_gate.v`, `syn/fi_scan_lib.tcl`, `syn/scanchain.tcl`, `rtl/fi/fi_wrapper_top.v` | three simultaneous breakages, none checked |
| 5-bit JTAG IR | `rtl/fi/fi_transporter.v` | cutover never fires; every later write vanishes silently |
| no TRSTn pass-through | `rtl/fi/fi_wrapper_top.v` | must be wired outside the wrapper; undocumented |
| one freezable clock domain | `fi_insert_clock_gate` builds one gate on one net | a second domain is inexpressible |

Missing assertions, where the data is already in hand:

- **A6, one master clock on the chain.** `report_scan_path` prints
  MasterClock/SlaveClock and `fi__scan_order` already parses that file — and
  discards the line. A foreign-domain flop on the chain is caught by nothing.
- **A3 is blind to black boxes.** `all_registers` does not return them. The
  reference run has two SRAM macros that are safe only by accident of hierarchy.
- **`FI_EXEMPT_CLOCKS` typos warn instead of failing**, and the domain then falls
  through to being counted as *frozen* — silent in the wrong direction.

Guards that pass when they should not:

- `make sync-check` exits 0 when the synthesis-side file is absent, which is
  exactly the state a fresh clone is in; and it compares `FI_SCAN_LEN` (which no
  RTL reads) while skipping `FI_W_IDX` vs `FI_N_FF`, where a mismatch injects into
  the wrong flop with no error at all. Both files are already open in that recipe.
- `FI_VERSION` (DMI `0x6F`) is a fixed constant and cannot confirm the field
  split, though the debug notes suggest reading it for that.
- CI does not run `sync-check`.

Layout: `rtl/soc/jtag_dpi/` is generic OpenTitan simulation infrastructure filed
inside the *vendored example DUT*, and `sim/Makefile` reaches it by literal path.
Deleting `rtl/soc/` — the natural reading of "vendored example" — removes the
`remote_bitbang` server OpenOCD connects to, and the failure looks like a missing
DPI toolchain. The same applies to `cdc_rv_1deep.v`, which is written for this
project and meant to be lifted.



### Linking the FI_Entry encoding to the scan source of truth

`W_IDX = $clog2(N_FF)` fixes the FI_Entry field boundaries. Like `CFG_SCAN_LEN` and the
`FI_Index` numbering, it is ultimately a product of `report_scan_path`, but it lives in
two places that must agree: [rtl/fi/fi_scan_cfg.vh](../rtl/fi/fi_scan_cfg.vh) on the
RTL side and `FI_W_IDX` in [host/tapename.tcl](../host/tapename.tcl) on the host
side. **If they disagree nothing errors — you simply inject into the wrong flop.**

Two decisions make that hard to get wrong:

- `N_FF` means "encoding bound", not "current chain length", and is a power of two.
  `L` can drift (4721 / 4727 / 4143 have all been seen) without moving a single field
  boundary; only crossing 8191 forces a change. Contract: **L ≤ 2^W_IDX − 1**,
  asserted as A4.
- Synthesis emits both values: `fi_scan_cfg.vh` for the RTL and `fi_scan_cfg.tcl` for
  the host, from one measurement.

| | status |
|---|---|
| source of truth generates the DC commands, the RTL header, and the host config | 🟢 done |
| A4 asserts the encoding bound | 🟢 done |
| `fi_scanmap.txt` (`FI_Index → flop`) exported | 🟢 done |
| `fi_entry_by_name {eop off cell bit}` on the host, so targets are named not numbered | 🟡 not written |
| the wrapper measures `L` itself at runtime | ⬜ not started |

**Still manual, and it should not be**: the generated `fi_scan_cfg.vh` and
`fi_scan_cfg.tcl` have to be copied over `rtl/fi/fi_scan_cfg.vh` and into
`host/tapename.tcl` by hand, together with the netlist. All three move together; get
one wrong and the chain is never restored.

`make -C syn sync-check` now *detects* the mismatch — it prints the chain length
found in all three places and exits non-zero if they disagree. It does not fix it.
Copying is still on you, and nothing runs the check automatically.

### Runtime self-measurement of the chain length

In test mode, hold `scan_en = 1` with `scan_in` tied low for long enough to clear the
chain, then send a single 1 and count the cycles until it appears at `scan_out`. That
count is `L`.

- This is the single most useful thing for an arbitrary DUT: **the host needs to know
  nothing about the synthesis run**.
- Cost: the measurement destroys DUT state, so it has to run once after reset and
  before the campaign proper.
- It reuses the existing shift path plus a small FSM.
- It is the runtime dual of A4: compare the measured `L` against `2^W_IDX − 1` in
  hardware and raise an `FI_STATUS` error bit if it does not fit. That matters most on
  an FPGA, where there is no synthesis log to read.

### Export the FI_Index → flop map — landed, with one trap worth repeating

> **Parse the `Cell_#` column of `report_scan_path`. Do not parse the SCANDEF.**
> SCANDEF writes chains as `FLOATING`, an *unordered* set that place-and-route may
> reorder, and DC emits it in a different order from the chain it built. On one real
> netlist, entry 2711 of the SCANDEF was `gpr_rw_8` bit 1 while the flop actually
> flipped at `FI_Index = 2711` was `gpr_rw_2` bit 5 (SCANDEF position 2523). The resulting
> map looks perfectly normal and is entirely wrong. See pitfall #20.

---

## P2 — host and protocol robustness

### `stick_busy_q` has no way to be cleared

It can only be cleared by writing bit 16 (`dmireset`) of DTMCS, and
[host/tapename.tcl](../host/tapename.tcl) has no proc for that. Once set, every read
returns status = 3 with no way back. Add:

```tcl
proc fi_dmi_reset {} {
    global TAPNAME
    irscan $TAPNAME 0x10
    drscan $TAPNAME 32 0x00010000 -endstate RUN/IDLE
    runtest 8
}
```

### The `runtest` threshold is unexplained

`runtest 2` ✓ / `8` ✓ / `80` ✗ / `100` ✗ — the larger values hang both telnet and
OpenOCD.

**Mitigated**: `fi_dmi_read` used to use `runtest 80`, which made it a trap that
killed the session on the very first status read-back. It looked like "reads do not
work during FI", when in fact the read path (in the AON domain, independent of the
DUT) was fine the whole time. Idling less is harmless, because the response lags by
one transaction regardless — which is why the documented usage is to read the same
address twice and keep the second result.

**The mechanism is still not understood.** 8 is an empirical value, not an explained
one. Suspicion falls on `stick_busy_q` or on how remote_bitbang supplies TCK.

### Requests during `S_WAIT_RESP` are dropped silently

`fi_jtag_dtm_v6` receiving `tap_req_i` in `S_SEND` / `S_WAIT_RESP` only sets
`stick_busy_q`; it does not accept the request. **This makes `poll off` a hard
protocol requirement, not just noise reduction** — with polling on, writes are
probabilistically swallowed and you cannot see it happen. Either give the DTM
backpressure, or state `poll off` as part of the protocol.

### The passive-mode trigger has no handshake

```verilog
if (passive_entry_trigger_w && dtm_req_ready_i) ...   // tap_req_q lasts 1 cycle, no retry
```

If `dtm_req_ready_i` happens to be low, the FI_MODE trigger is lost forever.

---

## P3 — simulation and observation

### A campaign is comparable only within one netlist × one seed

*Measured, not conjectured. Three runs of the same 9-trial campaign.*

The build randomises every uninitialised flop (`+vcs+initreg+random`), and this DUT
has 992 of them — the GPRs have no reset and the SRAM starts empty. `sim/Makefile`
therefore **pins the seed** (`SEED ?= 1`); it used to pass
`+ntb_random_seed_automatic`, so the same campaign returned different verdicts on
every run and no result could be reproduced or bisected.

With the seed pinned, two runs of one netlist are byte-identical across all nine
trials. Two *different* netlists are not, and the reason is worth understanding
before reading anything into such a comparison:

| | reference netlist | netlist from `make -C syn dc` |
|---|---|---|
| flops | 5886 | 5886 |
| …with an async set/clear | 4876 | 4894 |
| …keeping their random value through reset | **1010** | **992** |
| inverted module boundaries (`*_BAR`) | 21 | 19 |

Randomisation applies to the *physical* flop output. Eighteen flops differ in
whether reset clears them at all, and about twenty module boundaries differ in
polarity, so **one seed produces two different logical initial states**. The
fault-free run alone then differs: first UART write at cycle 326138 versus 326137.

Two of nine fault outcomes differed accordingly. That is not evidence of a bad
chain — `L`, the `FI_Index → flop` map, the scan window (`scan=4143` every trial)
and the fault-free payload `7fabab04` were all identical. It is evidence that the
two netlists were never running the same experiment.

**Consequence for anyone porting this:** re-baseline after every synthesis run.
Comparing campaign results across netlists needs formal equivalence checking, or a
workload that does not read anything it has not written — and this one does read
such state, which is why its *fault-free* cycle count moves at all.

### UART output garbling — three independent causes, now separated

The FI campaign's UART output was garbled, and it took three separate mechanisms to
explain it. The testbench now carries **three receiver taps** so one run tells them
apart:

| tap | point | reset from | log |
|---|---|---|---|
| A | the pad, `io_pins[0]` | `rst_ni` | stdout (the historical setup) |
| B | `uart0.tx_o`, before the pad mux | `rst_ni` | `uart_txo.log` |
| C | the pad | `fi_rst` | `uart_pad_fi.log` |

1. **The pad mux was on the chain** — shifting scrambled the pin selector for the
   whole scan window. *Fixed*: `u_pinmux/clk_i` is now in `FI_GATE_PINS`.
2. **The monitor's reset source.** `uart_rx_print` was reset by the tb's power-on
   reset, so it kept counting across every DUT reset and was routinely stuck
   mid-frame. *Fixed in tap C.*
3. **The pad mux's reset default.** `io0_mux` has `RESVAL = 2'h0` = GPIO0, not
   UART0_TX. After every DUT reset the pin falls from UART idle-high to the GPIO
   reset value of 0 until software reconfigures `PINMUX_CTRL`. `uart_rx_print`
   triggers on a falling edge and **does not check the stop bit**, so that produces
   exactly one bogus byte per reset and blocks the receiver for ten bit times,
   swallowing or misaligning whatever real byte starts inside that window.

Cause 3 is **not** fixed by either of the others: it is not caused by shifting, and
the pulse is objectively present on the pin — a real UART receiver on real hardware
would see it too. Measured against the real `uart_rx_print`:

```
A (pad , power-on reset)  ->  2 bytes: 0x00 (the false start bit) + the real byte
B (tx_o, power-on reset)  ->  1 byte : the real byte
C (pad , fi_rst        )  ->  1 byte : the real byte
```

B works because `tx_o` never leaves the pad mux. C works because
`uart_rx_print`'s `uart_rxd_d0/d1` reset to 0, so a monitor held in reset never sees
the 1→0 edge at all.

**The root fix, not applied here**, is to change `io0_mux`'s `RESVAL` to `2'h1` so
the pin is UART idle-high from reset. That is a policy decision about what pin 0
defaults to on your chip, so it is left to you.

### A null-injection control run

Fill the table with `FI_Index = 0` everywhere and you get a scan loop with **identical
timing and zero bit flips** (`hit_step` is `L` for `FI_Index == 0`, and `run_cnt` only
reaches `L-1`, so the path is pure pass-through). If the output is still disturbed,
the disturbance is structural and has nothing to do with the injected fault. Write
it as a campaign whose trials all flip `FI_Index = 0`, e.g.
`fi_campaign { {30000 {0}} {60000 {0}} }`.

Worth pairing with a real flip on a functionally irrelevant target, which proves the
machinery ran while the program was unaffected.

### The observation window truncates the last trial

The testbench's drain time after the last trial is shorter than the remaining program
run, so the final pattern's UART output is cut off by `$finish`.

---

## P4 — history

The FI_Entry encoding changed from `{N[31:24], FI_Index[23:0]}` to
`{EOP, Cycle_Offset, FI_Index}`. Two capabilities came out of that, and three conclusions
are worth keeping.

**Per-entry cycle offset.** `FI_Cycle` went from a read-only configuration constant to
a running register `fi_cycle_q` inside `fi_time_ctrl`. The base comes from DMI
`0x65` as a **write strobe** (not a shadow-value comparison), so rewriting the same
value still restarts a sweep. Each pattern's `Cycle_Offset` is added at the **end of
phase 2 of the reset window, atomically with `clock_counter <= 0`** — it must not be
added at `done`, which would let the `==` comparison fire a second time inside the
same trial. A one-shot latch `fi_fired_q` caps it at one injection per trial.

**Several bits flipped in one pass.** A pattern is now one pass of `L` cycles that
flips `|F|` bits, instead of `|F|` passes. A 3-bit MBU's freeze dropped from 283.6 µs
to 94.5 µs. `fi_scan_ctrl` lost its multi-round machinery entirely; the index
became a two-stage front end with a pop handshake, which is what makes a **minimum
target spacing of 1** possible.

The three conclusions:

**(a) The datapath already supported it.** Step `k` reads `V[L-1-k]`, and the
injected bit lands in `FF[L-1-k]` after the remaining `L-1-k` steps — a relation that
holds **independently for every hit**. The shift path and the restore invariant did
not change by one character; only the index comparison did.

**(b) The apparent "3-cycle fetch pipeline" was not memory latency.** The table's exec
port is a **purely combinational read**; the old pipeline registers were just
plumbing. Once that was clear, the supposed constraint that adjacent targets could
not be one cycle apart disappeared — and adjacent-cell double flips are exactly what
an MBU model most wants to cover.

**(c) The old `N` field held three jobs at once** (round count, entry count, and
end-of-table marker), so removing it forced `CFG_TBL_LEN` to exist: under the new
encoding `0x0000_0000` is a **legal entry** (EOP=0, offset=0, FI_Index=0) and a sentinel
end-of-table is no longer possible.

**Compatibility**: there is no dual-format support, only a version register. `0x6F`
reads `0x0002_0000` for the current encoding and `0x0001_0000` for the old one. An
old host script that never writes `0x68` leaves `CFG_TBL_LEN` at its reset value of
0 and therefore **injects nothing at all** — a deliberately chosen fail-safe.
