# Paper ↔ code alignment

Two things live here:

1. **[§1](#1-fi_entry-encoding-what-the-paper-must-change)** — the `FI_Entry`
   encoding. The paper (Fig. 6 and §VI-B) still describes an encoding the hardware
   does not implement. This section says what the hardware actually does, why, and
   sentence by sentence what the paper should say instead. It also answers the
   reviewer note *"not clear how can we know how many FFs are fliped in a single
   FI run"*.
2. **[§2](#2-name-map)** — the name map. Every module, signal and register in this
   repository is named after the paper, so the two can be read side by side.

The paper text this refers to is `FIawase.md` / `FIawase__TCAD_-1.pdf` §VI
(*FPGA-Based Replay Architecture*), Fig. 4, Fig. 5, Fig. 6.

---

## 1. `FI_Entry` encoding: what the paper must change

### 1.1 The two encodings

**Paper, Fig. 6** — three fields, all three valid in every word:

```
 31        28 27              16 15                0
+------------+------------------+------------------+
| Cycle_Off  |   Pattern_Len    |     FI_Index     |
|    (4b)    |      (12b)       |       (16b)      |
+------------+------------------+------------------+
```

**Implemented** ([fi_table_ctrl.v](../rtl/fi/fi_table_ctrl.v), [DESIGN.md §5.5](DESIGN.md)) —
a 1-bit end-of-pattern marker replaces the `Pattern_Len` count, and the released
bits go to `Cycle_Offset`:

```
 31  30                W_IDX  W_IDX-1              0
+---+--------------------+----------------------+
|EOP|    Cycle_Offset    |       FI_Index       |
+---+--------------------+----------------------+

W_IDX = ceil(log2(N_FF))
```

`N_FF` is an **encoding bound**, not the current chain length: it is a power of two
chosen once per DUT, so that the field boundaries do not move when the real chain
length `L` drifts across re-synthesis. The contract checked at synthesis time is
`L <= 2^W_IDX - 1`. In the tinyriscv instance `N_FF = 8192`, so:

| field | paper | implemented (`N_FF = 8192`) |
|---|---|---|
| `FI_Index` | 16 b, fixed | `W_IDX` = 13 b, i.e. `ceil(log2(N_FF))` |
| `Cycle_Offset` | 4 b, max 15 | `31 - W_IDX` = 18 b, max 262 143 |
| pattern grouping | `Pattern_Len`, 12 b, max 4095 targets | `EOP`, 1 b, no bound on `\|F\|` |
| validity | all fields, every word | `EOP` and `FI_Index` always; `Cycle_Offset` **only in the `EOP` word** |

### 1.2 Why

**(a) `Pattern_Len` is redundant in every word but one.** It is a property of the
pattern, not of the entry, so an `|F|`-word pattern stores the same count `|F|`
times. `EOP` carries the same information in 1 bit, positionally.

**(b) `Cycle_Offset` at 4 bits is the field that actually limits a batch.** It is
the stride between the injection cycles of consecutive patterns. At 4 bits the
largest step is 15 cycles, so one loaded batch can only sweep a
`15 x B_eff`-cycle window and cannot express a jump between two distant injection
cycles at all — the host would have to reload just to move the cycle. At 18 bits
the stride reaches 262 143, which is more than the whole workload for the designs
evaluated here. The 11 bits released by `Pattern_Len -> EOP` are exactly what pays
for this.

**(c) Deriving `FI_Index` from `N_FF` rather than fixing it at 16 b** makes the
encoding scale with the DUT instead of capping it. A design with more than 65 535
scan-addressable FFs is not representable in the paper's layout; here it is a
parameter change. The trade is explicit: wider `FI_Index` means narrower
`Cycle_Offset`, and the two always sum to 31.

**(d) No sentinel is possible any more, and that is deliberate.** Under
`{EOP, Cycle_Offset, FI_Index}` the word `0x0000_0000` is a *legal* entry
(non-final, offset 0, `FI_Index` 0 = null injection). The end of a batch is
therefore **counted**: the host writes the word count to `CFG_TBL_LEN` and the
controller compares its pointer against it. This is a change from the earlier
`{N[31:24], FI_Index[23:0]}` encoding, where a zero high byte was the terminator.
The hardware exposes `FI_VERSION` (DMI `0x6F`, value `0x0002_0000`) so a host can
tell which encoding a given bitstream speaks.

### 1.3 The reviewer's question

> *"(not clear how can we know how many FFs are fliped in a single FI run)"*

**`|F|` is not stored and is not known in advance. It is determined at consumption
time**: the FI Table Controller keeps fetching entries of the current pattern until
it fetches one with `EOP = 1`, and `|F|` is the number of entries consumed up to
and including that one.

Nothing in the replay path needs `|F|` up front. What the FI Scan Controller needs
before it may start a scan pass is not a count but a **readiness condition**, and
readiness is satisfied when *any* of the following holds
([fi_table_ctrl.v](../rtl/fi/fi_table_ctrl.v), `entry_ready_o`):

- the whole pattern is already buffered (`EOP` has been fetched), **or**
- the lookahead buffer is full, **or**
- the table has no more words to give.

The middle case is what makes an unbounded `|F|` safe: the buffer refills at one
word per clock while the pass consumes it, and the minimum spacing between two
targets within one pass is one shift step, so a full buffer can always keep up with
the shift. A pattern longer than the buffer streams through without ever stalling
the pass. `Pattern_Len` would not improve this; it would only let the controller
*predict* a stall it cannot have.

### 1.4 Sentence-level edits for §VI-B

| paper text (current) | replace with |
|---|---|
| "…records the scan-chain target position (*FI_Index*), the number of target indices in the same replay pattern (*Pattern_Len*), and a non-negative cycle increment (*Cycle_Offset*)" | "…records the scan-chain target position (*FI_Index*), a single end-of-pattern bit (*EOP*) that marks the last entry of a replay pattern, and a non-negative cycle increment (*Cycle_Offset*) that is read only from that last entry" |
| Fig. 6 | redraw as `{EOP(1b), Cycle_Offset(31-W b), FI_Index(W b)}` with `W = ceil(log2(N_FF))`; annotate the example as `N_FF = 8192 -> W = 13`, `Cycle_Offset = 18 b` |
| "The controller counts how many *FI_Index* values have been consumed for the current replay pattern and compares the count with *Pattern_Len*. Therefore, *Pattern_Len* determines how many FFs are flipped in one replay pattern." (the `\zhang{}` block) | "The controller consumes *FI_Index* values until it reaches an entry with *EOP* set; the number of FFs flipped in one replay pattern is therefore the number of entries up to and including that one, and is not bounded by the encoding. The rolling buffer refills at one word per cycle, which matches the worst-case target spacing of one shift step, so a pattern longer than the buffer streams through without stalling the scan loop." |
| "The controller determines whether additional target indices remain in the current replay pattern using the per-entry grouping information encoded in the *FI_Entry*." | delete — it is now the previous sentence |
| the `\hashimoto{}` margin note | delete once the above lands |
| "When the scan counter matches the current *FI_Index* supplied by the FI Table Controller, *Scan_Out* is inverted…" | add a parenthetical: "…(the implementation counts shift steps from the head of the chain, so the comparison is against *Scan_Len* − 1 − *FI_Index*; the two are the same instant expressed in opposite coordinates)" |
| "…let `\bar{w}` denote the average number of FI Table words required by one replay pattern under the current *FI_Entry* encoding" | can now be stated exactly: under this encoding `\bar{w} = E[\|F\|]` — one word per flipped FF, with no per-pattern header word |

Two things worth **adding** to §VI-B, both consequences of the change:

- **Batch termination.** One sentence: because every 32-bit word is a legal entry,
  the end of a batch is given by a word count loaded with the configuration rather
  than by a reserved sentinel value.
- **Null injections.** One clause: `FI_Index = 0` maps to a shift step the counter
  never reaches, so it is a no-flip entry — useful as a control trial that exercises
  the full freeze/shift/restore/reset sequence without perturbing the DUT.

### 1.5 What does *not* change

The rest of §VI-B is accurate as written and should be left alone:

- one replay pattern = one scan-shift loop of `Scan_Len` shifts;
- entries of a pattern are stored in **descending** scan-index order so they can be
  consumed sequentially during that loop (the hardware also *checks* this and raises
  a sticky `err_order` status bit rather than injecting in the wrong place);
- `FI_Cycle <- FI_Cycle + Cycle_Offset` after every trial of the current pattern;
- the FI Resolver resets the DUT and the FI counters while the FI configuration is
  preserved;
- `Clk_Gate` both pauses the DUT and stops scan-shift side effects reaching
  unscanned modules.

---

## 2. Name map

Every name below is the paper's. The code follows it.

### 2.1 Blocks (Fig. 4, Fig. 5)

| paper block | module | file |
|---|---|---|
| the wrapper | `fi_wrapper_top` | [rtl/fi/fi_wrapper_top.v](../rtl/fi/fi_wrapper_top.v) |
| FI Transporter | `fi_transporter` | [rtl/fi/fi_transporter.v](../rtl/fi/fi_transporter.v) |
| FI Executor | `fi_executor` (+ `fi_executor_core`) | [rtl/fi/fi_executor.v](../rtl/fi/fi_executor.v), [fi_executor_core.v](../rtl/fi/fi_executor_core.v) |
| FI Time Controller | `fi_time_ctrl` | [rtl/fi/fi_time_ctrl.v](../rtl/fi/fi_time_ctrl.v) |
| FI Scan Controller | `fi_scan_ctrl` | [rtl/fi/fi_scan_ctrl.v](../rtl/fi/fi_scan_ctrl.v) |
| FI Table Controller | `fi_table_ctrl` | [rtl/fi/fi_table_ctrl.v](../rtl/fi/fi_table_ctrl.v) |
| FI Table | `fi_table` | [rtl/fi/fi_table.v](../rtl/fi/fi_table.v) |
| FI Resolver | **no separate module** — the reset window inside `fi_time_ctrl` | [rtl/fi/fi_time_ctrl.v](../rtl/fi/fi_time_ctrl.v) |
| Impact Classify | **not in RTL** — host side (UART, tb counters) | — |
| FI Configuration (the blue block) | the `CFG_*` registers in the Transporter | [rtl/fi/fi_transporter.v](../rtl/fi/fi_transporter.v) |

The FI Resolver is drawn as its own block in Fig. 5 but is one reset FSM in RTL:
splitting it out would add a module boundary and no logic. `fi_time_ctrl` generates
`resolver_rst` and never consumes it, which is what makes "reset everything except
the configuration" true by construction — the configuration lives in a different
module.

### 2.2 Signals (Fig. 5)

| paper | code |
|---|---|
| `Scan_Len` | `cfg_scan_len_i`, register `CFG_SCAN_LEN` (DMI `0x63`) |
| `FI_Cycle` | `fi_cycle_q` / `fi_cycle_o`; base in `CFG_FI_CYCLE` (`0x65`), running value readable at `FI_CYCLE` (`0x69`) |
| `TO_Thr` | `cfg_to_thr_i`, register `CFG_TO_THR` (`0x66`) |
| `Cycle_Offset` | `cycle_offset_o` / `cycle_offset_i`, latched in `cycle_offset_q` |
| `FI_Index` | `entry_index_o` / `entry_index_i`; static-mode override in `CFG_FI_INDEX` (`0x64`) |
| `FI_Entry` | the 32-bit table word; encoder `fi_entry` in [host/tapename.tcl](../host/tapename.tcl) |
| `Clk_Gate` | `clk_gate` inside the Scan Controller, `clk_gate_o` at the wrapper boundary. The **DUT-side port name is not a FIawase name** — see [§3](#3-the-one-name-that-is-deliberately-not-the-papers) |
| `Scan_En` / `Scan_In` / `Scan_Out` | `scan_en_o` / `scan_in_o` / `scan_out_i` |
| "scan start" | `scan_start_o` |
| "timeout" | `stop_by_to` inside `fi_time_ctrl` |
| "Reset all states except FI Configuration" | `resolver_rst` (internal), `fi_rst` (to the DUT, active low) |
| "Address+" / "read" | `tbl_rd_addr_o` / `tbl_rdata_i`, driven by `word_ptr` |
| "ready" / "new FI_Index" | `entry_ready_o` / `entry_valid_o` + `entry_pop_i` |

`hit_step` in `fi_scan_ctrl` has no paper name: it is the derived shift step
`Scan_Len - 1 - FI_Index`, i.e. the same target in head-first coordinates. See
§1.4.

### 2.3 Terms the code deliberately does *not* use

`pos`, `inj_idx`, `scan_gate`, `scan_rst`, `RAM`/`SRAM` (for the FI Table),
`CFG_LEN`, `CFG_WRCNT`, `CFG_CLK_FI`, `CFG_CLK_TO`. All were renamed to the paper's
vocabulary. If you find one, it is stale.

---

## 3. The one name that is deliberately not the paper's

**The DUT's top-level freeze input stays `scan_gate`.** Everything on the FIawase
side of that wire is named `Clk_Gate` after the paper — `clk_gate` inside
`fi_scan_ctrl`, `clk_gate_o` on `fi_wrapper_top`, `clk_gate_i` on the inserted
`fi_clk_gate` — and the DUT port keeps the name it already has:

```
fi_scan_ctrl.clk_gate -> fi_wrapper_top.clk_gate_o -> tinyriscv_soc_top.scan_gate
        Clk_Gate, the paper's name                       the DUT's own name
```

This is not an oversight, and it is not a special case for one DUT. FIawase
attaches to a **user-provided** design, so the name of the port it drives is a
property of that design, not of the framework. That is why the synthesis flow
never hard-codes it: the whole DUT-side contract is the single line

```tcl
set FI_GATE_PORT  scan_gate      ;# syn/fi_scan_cfg.tcl
```

Point it at whatever your DUT calls its freeze input. If the DUT has no such port,
`fi_insert_clock_gate` creates one and warns.

The practical reason to leave the example SoC alone: renaming the port would
invalidate every netlist synthesised so far, forcing a `make dc` re-run and a
re-calibration of the `FI_Index -> flop` map, in exchange for one identifier. The
paper does not name DUT ports, so nothing in it disagrees with this.
