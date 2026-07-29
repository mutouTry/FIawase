# Debugging notes — module dissection and host protocol

Everything here was read off the code or measured on a waveform. Statements marked
**derived** are reasoning you can confirm yourself; everything else is observed.

Read [DESIGN.md](DESIGN.md) first for what the thing does. This document is for when
it does not.

---

# Part A — inside the wrapper

## A.0 Top-level wiring

| wrapper port | testbench connects | DUT port |
|---|---|---|
| `aon_hfclk_i` | `clk_i` (50 MHz) | also the DUT's `clk_50m_i` |
| `aon_lfclk_i` | **`1'b0`** | — |
| `aon_rst_ni` | `rst_ni` (tb power-on reset) | — |
| `jtag_tck/tms/tdi/tdo` | `jtagdpi` (OpenOCD remote_bitbang) | — |
| `jtag_trst_ni` | **`rst_ni`** | — |
| `dut_jtag_*` | `dut_jtag_*` | `jtag_TCK/TMS/TDI/TDO_pin` |
| `scan_in_o` / `scan_en_o` / `testmode_o` | `sc_scanin` / `sc_scanen` / `sc_testmode` | `io_scanin` / `io_scanen` / `io_testmode` |
| `scan_out_i` | `tb_io_scanout` | `io_scanout` |
| `clk_gate_o` | `clk_gate_o` | `scan_gate` |
| `fi_rst` | `fi_rst` | **`rst_ext_ni`** |

Three wiring facts worth memorising:

1. **`jtag_trst_ni = rst_ni`, not `fi_rst`.** The FI reset hits the DUT every trial
   but **does not** reset the wrapper's own TAP, DTM or registers — which is why the
   configuration and the table pointer survive across trials. The whole auto loop
   depends on this.
2. **The DUT's `rst_ext_ni = fi_rst`, and the DUT's debug module resets from
   `rst_ext_ni` too.** So every FI reset clears `haltreq`: OpenOCD's `halt` during
   `init` is undone automatically and you never need `resume`.
3. **`fi_rst = aon_rst_ni & ~resolver_rst_w`.**

## A.1 fi_transporter — who owns the JTAG

### A.1.1 Routing: passive vs active

```verilog
assign dut_jtag_tck_o = fi_mode_active_q ? 1'b0          : jtag_tck_i;
assign dut_jtag_tms_o = fi_mode_active_q ? 1'b1          : jtag_tms_i;
assign dut_jtag_tdi_o = fi_mode_active_q ? 1'b0          : jtag_tdi_i;
assign jtag_tdo_o     = fi_mode_active_q ? fi_jtag_tdo_w : dut_jtag_tdo_i;
```

- **Passive**: host JTAG passes straight through; the host sees the DUT's TDO. The
  wrapper's own TAP is still clocking (it hangs off the same TCK/TMS/TDI), its TDO
  just is not selected.
- **Active**: the DUT's TCK is tied low and TMS high, parking its TAP safely toward
  TEST-LOGIC-RESET. The host now talks only to the wrapper.

> **What this means when debugging**: after cutover **the DUT's JTAG is gone**, so
> OpenOCD's RISC-V target is effectively dead. Every `failed read at 0x11, status=2`
> that follows is a consequence of that, not a fault.

### A.1.2 The TAP front end

- A standard 16-state TAP clocked on `posedge TCK`. `SHIFT_REG_BITS = 7+32+2 = 41`.
- IR is 5 bits; on reset/TLR `ir_reg_q = IDCODE`. **`ir_reg_q` and `jtag_tdo_q`
  update on `negedge TCK`** — standard practice, and it means a new IR takes effect
  on the falling edge of UPDATE_IR.
- `CAPTURE_IR` loads `2'b01`, which matches OpenOCD's default ircapture=0x1 /
  irmask=0x3 check, so `-irlen 5` in the config file is all that is needed.
- `SHIFT_DR` shifts **32 bits** for IDCODE/DTMCS and **41 bits** for DMI.
- `tap_req_q <= (tap_state_q == UPDATE_DR) && (ir_reg_q == DMI)` — **note this is a
  register, so it lags UPDATE_DR by one cycle.**
- `tap_safe_switch_o = (state == RUN_TEST_IDLE) || (state == TEST_LOGIC_RESET)`.

### A.1.3 The DTM state machine

Three states, `S_IDLE / S_SEND / S_WAIT_RESP`, all on `posedge TCK`.

**The passive branch is the easiest thing to trip over:**

```verilog
if (!fi_mode_active_i) begin
    state_q <= S_IDLE; dtm_data_q <= 0; stick_busy_q <= 1'b0;
    if (passive_entry_trigger_w && dtm_req_ready_i) begin
        dtm_data_q  <= tap_data_i;
        req_pulse_q <= 1'b1;
    end
end
```

**In passive mode exactly one packet is forwarded and everything else is dropped
silently.** The trigger is `IR == DMI && tap_req && op == WRITE && addr == 0x60 &&
data[0] == 1`.

> So: **if cutover did not happen, every subsequent write vanishes without an
> error.** That is why you must confirm cutover with the IDCODE
> (`1e200a6f` = not switched, `f17e0006` = switched) rather than assuming.

Active branch:

- `S_IDLE`: a `tap_req_i` whose op is READ or WRITE latches `dtm_data_q` and moves to
  `S_SEND`. **A NOP packet never enters the state machine** — which is exactly why
  `fi_dmi_flush` is safe.
- `S_SEND`: waits for `dtm_req_ready_i`, emits `req_pulse_q`, moves to `S_WAIT_RESP`.
- `S_WAIT_RESP`: raises `resp_ready_q`, latches on `dmi_resp_valid_i`, returns to
  `S_IDLE`.
- **`stick_busy_q`**: another `tap_req` arriving during `S_SEND`/`S_WAIT_RESP` sets
  it, after which `data_o` returns BUSY forever. **Only a DTMCS write of bit 16
  (`dmireset`) clears it**, and the host scripts have no proc for that. If reads
  suddenly all come back status=3, this is why.

**One fatal detail in the response path:**

```verilog
assign dmi_resp_ready_o = fi_mode_active_i ? resp_ready_q : 1'b0;
```

Passive mode **never drains responses**, so the response to the `FI_MODE = 1` write
itself stays stuck in the CDC — see A.1.6.

### A.1.4 The 2-phase CDC

Source side latches on `src_valid && !src_busy`, flips `src_toggle_q`, sets
`src_busy_q`. Destination side synchronises the toggle through three flops and
detects the change. One crossing takes roughly 3–4 destination clocks; a full round
trip including the busy release takes roughly 6–8 source clocks. **Only one
transaction can be in flight at a time** — `src_busy_q` is a single-depth handshake.

### A.1.5 The AON-side register file

```verilog
assign dmi_req_ready_o = ~dmi_resp_valid_o;
```

**A new request is not accepted until the previous response has been taken.**
Strictly serial.

Addresses outside the FI window return `{addr, 32'hBADA_0001, FAIL}` with
`FI_DMI_RESP_FAIL = 2'b10 = 2`.

> **OpenOCD polling the DUT's `0x11` (dmstatus) lands outside the window, so it gets
> `status=2`. That is by design, not a bug.**

### A.1.6 Cutover timing and the one-transaction response lag

**Cutover commit** requires three things at once: a TCK edge, the TAP in RUN/IDLE or
TLR, and the DTM in `S_IDLE`.

> **`sleep` does not produce TCK.** If a `sleep` ever appeared to help, it was
> OpenOCD's polling supplying the edges, not the sleep.

**A DMI write needs three TCK rising edges after UPDATE_DR to leave the TCK domain:**

| edge | event |
|---|---|
| n | `tap_state_q` = UPDATE_DR |
| n+1 | `tap_req_q <= 1`; the TAP also reaches RUN/IDLE |
| n+2 | DTM `S_IDLE → S_SEND` |
| n+3 | DTM `S_SEND → S_WAIT_RESP`, `req_pulse_q <= 1` |
| n+4 | the CDC source samples `src_valid_i` ← **only now does the request leave TCK** |

n+1 is the last edge of the drscan itself, so RUN/IDLE still owes three edges and
`fi_dmi_write` only supplies a few. `req_pulse_q` is a held register so nothing is
lost — **every write simply lands on the next transaction, and the last write of a
sequence hangs forever.** That is the only reason `fi_dmi_flush` exists.

**The response lags by one transaction** (derived; confirm on a waveform). The
`FI_MODE = 1` response is never drained in passive mode and sits in the CDC. The
first transaction after cutover enters `S_WAIT_RESP` and immediately consumes that
stale response, and the phase persists from then on.

> **⚠️ `fi_dmi_read` returns the response to the *previous* transaction, not the
> register you just asked for. Read the same address twice and keep the second
> result.** Waveform check: is `u_cdc_resp.dst_valid_o` high for long stretches
> while idle?

---

## A.2 fi_executor

`fi_executor` = `fi_executor_core` (three controllers) + `fi_table` (the table),
all on `aon_hfclk_i`.

### A.2.1 fi_time_ctrl — Time Controller

```
enables   fi_hit_en = (fi_cycle_q != 0)     <- the RUNNING register, not cfg_fi_cycle_i
          to_hit_en = (cfg_to_thr_i != 0)
inject    fi_hit_en && !fi_fired_q && (clock_counter == fi_cycle_q)
timeout   to_hit_en && (clock_counter >= cfg_to_thr_i)      <- greater-or-equal
overflow  fi_cycle_ovf = to_hit_en && (fi_cycle_q >= cfg_to_thr_i)
```

**Where the per-entry cycle offset lands:**

```
reset            -> 0
cfg_fi_cycle_wr_i  -> cfg_fi_cycle_i          write strobe on 0x65; rewriting the same
                                          value still reloads
end of phase 2   -> fi_cycle_q + cycle_offset_i    atomic with clock_counter <= 0
```

> **Why it cannot be accumulated at `done`**: `clock_counter` is still climbing in
> this trial, so raising the target would let `==` fire **a second time in the same
> trial**. `fi_fired_q` is the second line of defence.
>
> This register naturally sits outside the FI Resolver's reset: the Time Controller
> *produces* `resolver_rst` and never consumes it.

The reset window after stopping:

- entering: `stopped=1, rtc_phase=1, testmode_rst_r=1, resolver_rst_r=0`
- phase 1: one `rst_advance` → `resolver_rst_r=1`, phase=2
- phase 2: one more → `resolver_rst_r=0, testmode_rst_r=0, stopped=0, phase=0,
  clock_counter=0`

```verilog
wire rst_advance = (RTC_ALIGN_EN != 0) ? rtc_rise_pulse : (rst_cnt >= RST_CYC-1);
```

With `RTC_ALIGN_EN=0, RST_CYC=32` the reset window is 32 cycles of preparation plus
32 cycles of `resolver_rst` high, and `aon_lfclk_i` is not involved at all. Setting
`RTC_ALIGN_EN=1` switches to aligning on `aon_rtcToggle_a`, for a DUT that really has
an independent slow clock. **With `aon_lfclk_i` tied to `1'b0`, `RTC_ALIGN_EN` must
stay 0** or the FSM sticks in phase 1 forever.

**`clock_counter` is cleared only at the end of phase 2**, so every trial counts
cycles from "reset released" — the same origin the testbench's FI window report uses.

> Two numeric constraints:
> - `fi_cycle_q` is compared with `==`, so it must land inside `[0, cfg_to_thr)`. A
>   cycle sweep that walks out of that range raises `fi_cycle_ovf`, lights
>   `FI_STATUS` bit 4 and stops the batch rather than silently doing nothing.
> - `cfg_to_thr` is compared with `>=`, so the instant it is written `clock_counter`
>   is already past it and the **first stop triggers immediately**. That is the
>   mechanism behind "writing CFG_TO_THR is what starts the loop".

### A.2.2 fi_scan_ctrl — Scan Controller

**The exact edge account.** Let S be the rising edge on which `start_pulse` hits:

| time | fi_scan_ctrl | the freeze gate |
|---|---|---|
| S | `clk_gate<=1`, `testmode_o<=1`, `tm_lead<=1`, latch `L_q`/`run_end_q`, **arm index stage 0** + pop | — |
| S+1 | `run<=1, run_cnt<=0, scan_en_o<=1`, **arm stage 1** + pop | `gate_q<=1` (one sync stage) |
| S+2 … S+L+1 | `run_cnt` walks 0→L-1 with `scan_en_o=1` | gated clock low — **these L edges are masked** |
| S+L+1 | `run_cnt==run_end_q` → `done_o<=1`; `run<=0, scan_en_o<=0, clk_gate<=0` | — |
| S+L+2 | — | gate reopens |

**⇒ chain flops take exactly L extra shift edges (S+2…S+L+1) and the frozen flops are
masked for exactly those same L edges.**

This alignment depends on **one thing only**: `scan_en_o` trails `clk_gate` by
exactly one cycle (via `tm_lead`), and the gate's synchroniser is exactly one flop.

> **⚠️ Never add a second synchroniser stage.** The gate would close one cycle late
> and open one cycle late, so the frozen flops would take one edge too many at one
> end and one too few at the other — and the chain could never be restored.

**Injection point and the two-stage index front end:**

```verilog
wire [31:0] hit_step_of = ((entry_index_i == 0) || (entry_index_i > L)) ? L : (L - 1 - entry_index_i);

wire hit     = run & hit_vld_q & (run_cnt == hit_step_q);   // hit, flip it
wire stale   = run & hit_vld_q & (run_cnt >  hit_step_q);   // out of order: drop + err_order
wire null_e  = run & hit_vld_q & (hit_step_q > run_end_q);  // FI_Index==0: retire immediately
wire advance = hit | stale | null_e;

assign scan_in_o   = hit ? ~scan_out_i : scan_out_i;
assign entry_pop_o = entry_valid_i & (arm0 | arm1 | advance);
// on advance: hit_step_q <= hit_step_nx;  hit_step_nx <= hit_step_of;
```

`run_cnt` only reaches L-1, so `hit_step = L` means **no flip** — that is the null
injection case (`FI_Index == 0` or `FI_Index > L`).

> **The two-stage front end is why a spacing of 1 works**: on a hit, `hit_step_q`
> takes the already-staged `hit_step_nx` without waiting for a fetch. So `FI_Index = k+1,
> k` — an adjacent-cell double flip, the case an MBU model most wants — completes in
> one pass. A null entry retires through `null_e`; without that it would sit at the
> head forever and block every target behind it.

**Which flop actually gets flipped (derived).** Call FF[0] the first cell after
`io_scanin` and FF[L-1] the one driving `io_scanout`. At step k the value at
`scan_out` is `V[L-1-k]`, and the bit injected at step k lands in FF[L-1-k] after the
remaining L-1-k steps. With k = `hit_step` = L-1-FI_Index, **the flop flipped is FF[FI_Index],
where `FI_Index` is the 0-based index in `report_scan_path` order (scanin → scanout).**

> **✅ Confirmed by measurement.** Target `FI_Index = 2354` =
> `u_tinyriscv_core/u_gpr_reg/gpr_rw_2__not_x0_rf_dff/qout_r_reg_5_`, i.e. bit 5 of
> GPR **x2 (sp)**, on the L = 4143 netlist.
>
> | signal | before the scan window | after | conclusion |
> |---|---|---|---|
> | `gpr_rw_2 .qout[31:0]` | `2000_07E0` | `2000_07C0` | differs by `0x20` = bit 5 ⇒ **hit** |
> | `gpr_rw_3 .qout[31:0]` | `2000_0868` | `2000_0868` | unchanged ⇒ **chain restored bit-perfect** |
>
> **The core is on the chain, so it executes no instructions while shifting** — which
> means any difference across the window can only come from the injection. That is
> the cleanest possible criterion, and it is the method to copy when calibrating a
> new DUT: pick one register with a stable value as the target and another as the
> control, and one waveform gives you both conclusions.
>
> Reproduce with `fi_campaign { {30000 {2354}} {50000 {2354}} {70000 {2354}} }`.
>
> ⚠️ **A `FI_Index` is only valid for the netlist it was measured on.** Re-synthesis moves
> every one of them.

**Getting `FI_Index` for a flop** — synthesis exports `results/fi_scanmap.txt`
(`FI_Index <TAB> cell`), so target selection is one grep:

```sh
grep gpr_rw_2__not_x0_rf_dff/qout_r_reg_5_ results/fi_scanmap.txt
```

> 🔴 **Do not use the SCANDEF instead.** It writes the chain as `FLOATING`, an
> unordered set that place-and-route may reorder, and DC's output order differs from
> the order it actually stitched. On one real netlist, SCANDEF entry 2711 was
> `gpr_rw_8` bit 1 while the flop measured at `FI_Index = 2711` was `gpr_rw_2` bit 5
> (SCANDEF position 2523) — a map that looks perfectly normal and is entirely wrong.
> See pitfall #20.

**Test mode window**: TM rises one cycle before SE and falls `TM_TAIL_CYCLES = 3`
cycles after it.

### A.2.3 fi_table_ctrl — Table Controller

- One pointer, `word_ptr` (a word count); the byte address is derived
  combinationally. No FSM, and no `[7:2]` wrap-around problem.
- **Lookahead**: a `LOOKAHEAD = 4` shift register (`la_index` / `la_vld`) whose head is
  a plain register, so the consumer-side comparator timing is identical to the old
  "compare against one register" arrangement.
- **Fill window = [falling edge of `resolver_rst`, EOP fetched or
  `word_ptr == Table_Len`]**, greedily one word per cycle:

  ```
  do_push = fill_armed & ~eop_fetched & ~ptr_at_end & (room | popping this cycle)
  on push : la <= rdata[W_IDX-1:0]; word_ptr++
            if rdata[31] (EOP) -> cycle_offset_q <= rdata[30:W_IDX]; eop_fetched <= 1
  ```

  The exec port is a **purely combinational read**, so advancing the pointer is the
  entire memory access and data is valid the next cycle — one entry per cycle. Trials
  are tens of thousands of cycles apart, so the pattern is staged long before the
  trigger and arming is a plain register load. With `|F| > 4` it refills while
  consuming.
- `entry_ready_o = la_vld[0] && (eop_fetched || lookahead full || ptr_at_end)` — the
  "full" term is what lets a pattern longer than the lookahead start at all.
- **The end of the table is counted**: `ptr_at_end = (word_ptr >= Table_Len)`.
  `table_exhausted_o` is set only on the `done` of the last pattern.
- **The `resolver_rst` soft reset preserves four things**: `word_ptr`, `cycle_offset_q`,
  `table_exhausted_o`, `err_malformed_o`. Everything else is cleared, because the
  moment `resolver_rst` falls the fill starts again.

> **The one piece of timing that needs care — handing over `cycle_offset_q`.**
> `fi_time_ctrl` reads `cycle_offset_o` on the cycle `resolver_rst` falls, and gets the
> **previous pattern's** value (the register's pre-edge value); `fill_armed` is only
> set on that same cycle, so the earliest anything can overwrite it is the next
> cycle. A single register is therefore enough — no pending/live handshake needed.

**Three things that will bite you:**

1. **`CFG_TBL_LEN` (0x68) must be written**, or nothing is injected at all. The old
   "high byte zero means end of table" sentinel is gone: `0x0000_0000` is now a legal
   entry. The reset value of 0 is a deliberate fail-safe.
2. **Within a pattern, `FI_Index` must descend** (`hit_step` ascending). Out-of-order
   entries are dropped and light `FI_STATUS` bit 2. Generating them with `fi_pattern`
   makes it impossible to get wrong.
3. **The last entry must have `EOP = 1`.** A table ending mid-pattern sets
   `err_malformed` (`FI_STATUS` bit 3) and prints `[FI-ERR]`; the hardware closes the
   pattern with an implicit EOP rather than hanging.

**After the table ends the loop idles, it does not stop**: `table_exhausted` clears
`cfg_en_able_r`, the target source falls back to the static `cfg_fi_index_i` (which the
script sets to 0), so `arm_ok = 0` and no scan pass ever starts. Reset trials keep
running, they just stop injecting.

### A.2.4 fi_table

- 256 × 32 flops, not an SRAM macro — so the table needs no memory library.
- Host port is synchronous; the exec port is `assign exec_rdata_o =
  mem[exec_word_addr]`, a **pure combinational read**, so `tbl_rdata_i` is valid the
  same cycle `tbl_rd_addr_o` changes.
- **Reset clears the whole array**, and its reset is `aon_rst_ni`, not `fi_rst` — so
  the table survives across trials.

### A.2.5 fi_executor_core — the glue

```verilog
assign start_usr           = cfg_start_i | scan_start;   // :172
assign scan_ctrl_cfg_start = s2;                         // :184, s1/s2 delay it 2 cycles
```

The Scan Controller is started **two cycles after** `start_usr` on purpose, so that
whatever will feed `entry_index_i` is already staged when it samples.

The Table Controller has no start port at all — its only sequencing input is
`resolver_rst`, on whose falling edge it arms its fill (`fill_armed`), so by the time
`scan_ctrl_cfg_start` arrives the lookahead has had the entire inter-trial gap to
pre-fill. In static mode the same two cycles cover `static_first`, which `start_usr`
sets at :161 and which the pass consumes exactly once.

```verilog
if (!cfg_auto_i)                              cfg_en_able_r <= 1'b0;
else if (table_exhausted_o || fi_cycle_ovf_o) cfg_en_able_r <= 1'b0;  // ranks above the next line
else if (resolver_rst_rise)                       cfg_en_able_r <= 1'b1;

assign entry_index_sel   = cfg_en_able_r ? tbl_index   : cfg_fi_index_i;
assign entry_valid_sel = cfg_en_able_r ? tbl_valid : static_first;   // static mode emits exactly one
assign arm_ok          = cfg_en_able_r ? tbl_ready : (cfg_fi_index_i != 0);
```

`cfg_en_able_r` means "this pass uses the table's entry stream rather than the static
`CFG_FI_INDEX`". It is re-armed by every `resolver_rst` rising edge, but **the two
batch-finished conditions are ranked above it** — with the opposite ordering it would
pulse high for one cycle after every reset even once the table was done.
`static_first` is set by `start_usr` and cleared by the pop, so static mode flips
exactly one bit per pass.

```verilog
assign testmode_o = testmode_sc & !testmode_rst;
```

`io_testmode` is asserted **only during the scan window** (one cycle before SE, three
after), not for the whole auto-mode run. In the netlist `io_testmode` reaches the
core's `scan_en`, which forces `mem_req_o` low — so keeping it narrow means
functional memory access is only suppressed while shifting.

---

## A.3 The DUT interface contract — the clock-gate invariant

> **Every flop is either on the chain** (takes L extra edges, restored by rotation)
> **or frozen** (takes none).
> **Both** ⇒ the chain shifts out of step ⇒ restoration is impossible ⇒ the symptom
> is "the DUT dies the moment FI is armed".
> **Neither** ⇒ it runs free during the window with no way to restore it ⇒ state is
> silently corrupted.

### Who guarantees it

The DUT's RTL contains no clock gating. What is frozen is declared once, in
[syn/fi_scan_cfg.tcl](../syn/fi_scan_cfg.tcl), and
[syn/fi_scan_lib.tcl](../syn/fi_scan_lib.tcl) inserts the gate, re-routes the clocks,
excludes the blocks from the chain, and then **proves the result with five
assertions**. The porting contract is one line: the DUT exposes one freeze input.
FIawase calls that signal `Clk_Gate`; the DUT-side *port name* is whatever you put
in `FI_GATE_PORT` (here `scan_gate`, matching the existing netlist).

### Prove the edge account before changing the gate — `tests/run.sh`

Replacing the gate is risky: one cycle of difference in the freeze window makes the
off-chain blocks recover early or late relative to the chain, and that is nearly
impossible to spot on a waveform. So there is a regression that needs only
`iverilog`: the real `fi_scan_ctrl`, both real gate modules, real
rotate-and-restore passes, comparing the masked-cycle sets one cycle at a time.

| gate | cycles masked | short pulses |
|---|---|---|
| `clk & ~gate_q` (the combinational form) | **L** ✅ | 1 (a runt at the window start, width = t_co) |
| ICG, `E = ~gate_q` | **L+1** ❌ | 0 |
| ICG, `E = ~(gate_q & clk_gate)` (used) | **L** ✅ | **0** |

`L ∈ {1,2,3,5,8,17,64,257,4143}` over one or two passes: **same cycles masked, zero
disagreement**. The enable **must** be `~(gate_q & clk_gate)`; `gate_q` alone masks
one cycle too many — see pitfall #21.

### Three mechanisms can keep an instance off the chain

| mechanism | works? | verdict |
|---|---|---|
| `set_scan_element false` | ✅ | purpose-built, does not block optimisation. **This flow uses it**, then asserts the result |
| a clock that is not a `ScanClock` | ✅ | a side effect of gating. Implicit, and `-fix_clock enable` may try to "repair" it (assertion A5 watches for that) |
| `set_dont_touch` | ✅ | works indirectly, by blocking the DFF→SDFF swap. A blunt instrument: costs QoR and expresses no intent. Not used here |

Do not guess which one is doing the work. The flow uses the explicit one and checks
the outcome. The corollary matters regardless: **never declare a gated clock as a
`ScanClock`.**

### Why the UART output was garbled — three independent causes

`uart0`'s own two-clock structure is sound: the registers and TX FIFO run on the
gated clock, the serialiser on the ungated one, so a byte in flight finishes.
**The problem was everything after `uart0`.**

```
uart0.tx_o ─→ uart_tx[0] ─→ u_pinmux.uart_tx_val_i[0] ─┐
                                                        ├─ always_comb select → io_data_out[0]
u_gpio ────→ gpio_data_out_module ─→ .gpio_val_i[0] ───┘
                          ▲
              the selector = u_pinmux's config registers
```

1. **The pad mux was on the chain.** `pinmux_core`'s datapath is combinational, but
   its *selector* comes from configuration registers that were being shifted. During
   a window the selector changed arbitrarily and both inputs were changing too, so
   `io_data_out[0]` was essentially random for L cycles — 94.5 µs at L=4727, about 11
   bit times at 115200 baud. **Fixed**: `u_pinmux/clk_i` is now in `FI_GATE_PINS`.
2. **The monitor's reset source.** `uart_rx_print` was reset by the tb's power-on
   reset, so it never reset when the DUT did and was routinely left mid-frame.
3. **The pad mux's reset default.** `io0_mux` has `RESVAL = 2'h0` = GPIO0, not
   UART0_TX. After every DUT reset the pin drops from UART idle-high to the GPIO
   reset value of 0 — a textbook false start bit — until software rewrites
   `PINMUX_CTRL`. `uart_rx_print` triggers on a falling edge and **does not check the
   stop bit**, so this produces exactly one bogus byte per reset and blocks the
   receiver for ten bit times.

Cause 3 is fixed by neither of the others: it is not caused by shifting, and the
pulse is objectively present on the pin. The testbench instantiates all three taps
at once (stdout, `uart_txo.log`, `uart_pad_fi.log`) so one run separates them.

#### What the first gate-level run actually measured

Payload `7fabab04\n`, 9 bytes, no campaign armed:

| tap | reset | log | result |
|---|---|---|---|
| B | `rst_ni` | `uart_txo.log` | `7fabab04\n` — clean |
| C | `fi_rst` | `uart_pad_fi.log` | `\xB0\xB0` + `7fabab04\n` |
| A | `rst_ni` | stdout | same as C |

Two corrections to the model above.

**1. Tap C is only a different experiment once a campaign is armed.**
`fi_wrapper_top.v`: `assign fi_rst = aon_rst_ni & ~resolver_rst_w;` is
combinational, and `resolver_rst_w` only pulses inside a campaign. On a bare run
`fi_rst` *is* `rst_ni`, so C and A reset at the same instant and differ only in the
tap point — which is why they produced byte-identical logs. Keep C: during a
campaign it is the only monitor whose bit timing is cleared between trials. Just do
not read a bare run as evidence about it.

**2. The bogus bytes are not maskable by any monitor reset.** They land while
`fi_rst` is HIGH, between reset release and the first TXDATA write at cycle 321032,
and a monitor's reset can only mask edges inside its own reset window. The window
they live in is the one where `io0_mux` is still at `RESVAL = 00` and the firmware
is already driving GPIO0: `application_intmix.c` does `GPIO_IO_MODE` /
`GPIO_DATA_OUT` (cycle 733 — the observer's "exec start") *before* `sim_ctrl_init`
switches the pad to UART. Every 1→0 in there fabricates a byte, because the receiver
does not check the stop bit (pitfall 16). Note the observer hides this from
`fi_exec_window.txt` on purpose: `n_byte` is cleared at the first TXDATA write.

`tb/chaos_soc_tb.sv` carries a `[PAD-EDGE]` tracer for the one thing static reading
cannot settle — *when* those edges are and what the pad was following. `tx_o=1` at
the edge means the pad is not on `uart0`, so the cause is the pinmux/firmware;
`tx_o=0` would mean `uart0` really pulled low and tap B should have logged the same
byte, which would be new information.

**So score a campaign on `uart_txo.log`.** `uart_tx[0]` is the DUT's UART output;
everything downstream of it is a combinational mux sharing a pad with the GPIO the
firmware uses as its done flag — one more failure mode and no extra information. A
and C stay as the pad-path sanity check.

**The root fix, not applied**, is `RESVAL = 2'h1` on `io0_mux`, so the pad is
UART-idle-high from reset and never carries GPIO0. That is a decision about what pin
0 defaults to on your chip, and it costs a re-synthesis. Moving the firmware's done
flag off GPIO0 is the same fix from the software side.

> **General rule, and part of the porting contract**: for any output that must stay
> continuous across the scan window, **every stage from the producing register to the
> chip pin must be off the chain and frozen.** A combinational datapath is not
> enough — if that stage's *control* comes from a flop on the chain, the path is
> broken.

---

# Part B — the OpenOCD ↔ wrapper protocol

## B.1 Bring-up

```tcl
adapter_khz 1000
interface remote_bitbang
remote_bitbang_port 44853
jtag newtap riscv tap -irlen 5 -expected-id 0x1e200a6f
target create riscv.tap riscv -chain-position riscv.tap
init
halt
```

1. The simulator starts `jtagdpi`, listening on 44853
   (`jtag0: Accepted client connection`).
2. `openocd -f host/fi_openocd.cfg`.
3. During `init` the TAP is reset and IDCODE read. Still **passive**, so TDO comes
   from the DUT and the expected `1e200a6f` matches.
4. OpenOCD reads the DUT's DTMCS for its `abits` and sizes its own DMI DR from it.
5. `halt` stops the CPU.

> **The key point**: OpenOCD believes throughout that it is talking to the DUT's DTM.
> After cutover it has no idea, so its automatic DMI accesses still use the DUT's
> `abits`, land outside the FI window, and return status=2. The host Tcl uses **raw
> `drscan` with the address width hard-coded to 7**, bypassing OpenOCD's DMI layer
> entirely, which is why it is unaffected.

## B.2 The IR / DR contract

The FI TAP deliberately mirrors the RISC-V DTM's IR assignments, so OpenOCD needs no
reconfiguration across cutover:

| IR (5 bits) | name | DR length |
|---|---|---|
| `0x01` | IDCODE | 32 (`F17E_0006`) |
| `0x10` | DTMCS | 32 |
| `0x11` | DMI | **41** |
| `0x1F` | BYPASS | 1 |

DMI DR bit order:

```
tap_data[1:0]   = op      (0=NOP, 1=READ, 2=WRITE)
tap_data[33:2]  = data[31:0]
tap_data[40:34] = addr[6:0]
```

`drscan` takes fields in shift-in order (first in is least significant), so
`drscan riscv.tap 2 $op 32 $data 7 $addr` matches the hardware decode exactly.

## B.3 The host procs

| proc | does | note |
|---|---|---|
| `fi_ir_dmi` | `irscan riscv.tap 0x11` | switches IR to DMI and incidentally supplies ~14 TCK edges |
| `fi_dmi_write addr data` | 41-bit WRITE scan + `runtest` | **one edge short** (A.1.6) — the request lands on the next transaction |
| `fi_dmi_read addr` | READ scan → idle → NOP scan to capture | NOP never enters the DTM; **subject to the response lag, so read twice** |
| `fi_idcode` | `irscan 0x01` + 32-bit drscan | **the only reliable cutover check**: `1e200a6f` = not switched, `f17e0006` = switched |
| `fi_dmi_flush` | 41-bit **NOP** scan | pushes the last pending write across the CDC; zero side effects |
| `fi_entry eop off idx` | one 32-bit FI_Entry | field boundaries come from `FI_W_IDX`, not from `L` |
| `fi_pattern off {idx...}` | one replay pattern = one scan pass | **sorts descending for you**; unsorted sets `err_order` and drops targets |
| `fi_campaign {{cyc {idx...}} ...}` | the general campaign: any cycle, any bits | absolute cycles in, `Cycle_Offset` increments out; validates every limit before writing |
| `fi_mbu cyc {idx...}` | one multi-bit upset at one cycle | the single-shot form of `fi_campaign` |

## B.4 Write order and why it is not free

```
0x60 = 1          FI_MODE       cutover (the only packet forwarded in passive mode)
0x70 = 1          TBL_CTRL      autoinc
0x71 = 0          TBL_ADDR      pointer to zero
0x72 x N          TBL_WDATA     the table, generated by fi_pattern
0x62 = 1          CFG0          AUTO=1, END=0
0x63 = L          CFG_SCAN_LEN       must equal the netlist's real chain length
0x64 = 0          CFG_FI_INDEX     static index; must be 0 when the table is in use
0x68 = N          CFG_TBL_LEN   entry count -- forget it and nothing is injected
0x65 = base       CFG_FI_CYCLE    also reloads the fi_cycle_q accumulator
0x66 = timeout    CFG_TO_THR    <- writing this is what starts the loop
fi_dmi_flush                    push that last write across the CDC
```

- **`CFG_TO_THR` must be written last.** It is the source of `to_hit_en` and is
  compared with `>=`, so at the moment it lands `clock_counter` is already far past
  it → immediate first stop → reset window → `resolver_rst` rises (`cfg_en_able_r=1`) →
  `resolver_rst` falls (the table prefill starts) → counter cleared → first injection at
  `CFG_FI_CYCLE`.
- Everything else must therefore be in **before** it, or the first trial runs on
  unconfigured values.
- Writing `CFG_FI_CYCLE` **also re-arms the `fi_cycle_q` accumulator** (a write strobe,
  not a shadow-value comparison), so rewriting the same value restarts a sweep.
- `FI_CMD (0x67)` is unnecessary in auto mode.

**About `poll`:** keep it **off**. After cutover, OpenOCD's RISC-V polling floods the
log with `failed read at 0x11, status=2` and buries real errors. It "also works" with
polling on only because the polling happens to supply the missing TCK edge from
A.1.6 — coincidence, not a mechanism to rely on. Worse, a request arriving while the
DTM is busy is dropped silently (see pitfall #2), so polling can swallow your writes.

## B.5 One trial end to end

```
CFG_TO_THR written
  └→ clock_counter >= timeout  ⇒ stopped=1, testmode_rst=1, rtc_phase=1
       └→ 32 cycles later  resolver_rst=1 ⇒ fi_rst=0 ⇒ DUT reset (clears haltreq too)
            └→ cfg_en_able_r=1 on the rising edge
            └→ table controller soft reset, keeping word_ptr / cycle_offset_q
       └→ 32 more   resolver_rst=0, testmode_rst=0, stopped=0, clock_counter=0
            ·  atomically: fi_cycle_q += the last pattern's Cycle_Offset, fi_fired_q=0
            └→ table controller prefills the lookahead, stops at EOP, latches cycle_offset_q
            └→ DUT runs the program from cycle 0
                 ├ clock_counter == fi_cycle_q ⇒ scan_start, fi_fired_q=1
                 │    └→ +2 cycles  start_pulse (arm index stage 0)
                 │         └→ clk_gate=1 → next cycle scan_en=1 → shift L cycles
                 │              · the gated clock loses exactly those L edges
                 │              · one flip at each of the pattern's run_cnt == L-1-FI_Index
                 │         └→ scan_en=0, clk_gate=0, testmode trails 3, done pulse
                 └ clock_counter >= timeout ⇒ next trial
                   (after the done of the pass where word_ptr == TBL_LEN:
                    table_exhausted, injection stops, reset trials continue)
```

---

# Part C — quick reference

## C.1 Waveform probe points

**Host side / cutover**

```
u_fi_wrapper_top.u_fi_transporter.fi_mode_active_q     did cutover happen
                                      .u_tap.tap_state_q / .ir_reg_q / .tap_req_q
                                      .u_dtm.state_q        0=IDLE 1=SEND 2=WAIT_RESP
                                      .u_dtm.stick_busy_q   once 1, every read is BUSY
                                      .u_dtm.req_pulse_q    stuck high = wedged
                                      .u_cdc_req.src_busy_q
                                      .u_cdc_resp.dst_valid_o   long high ⇒ response lag
```

**Did the configuration actually land**

```
...u_regs.cfg_auto_o / cfg_scan_len_o / cfg_fi_cycle_o / cfg_to_thr_o
         .cfg_tbl_len_o        must be non-zero or nothing is injected
         .cfg_fi_cycle_wr_o      one-cycle pulse when 0x65 is written
         .tbl_addr_ptr_q       should equal the entry count after loading
u_fi_wrapper_top.u_fi_executor.u_fi_table.mem[0] ...
```

**Executor**

```
...u_fi_executor_core.cfg_en_able_r / static_first
   .u_fi_time_ctrl.clock_counter / stopped / rtc_phase / rst_cnt
              .fi_cycle_q      steps by the offset each trial
              .fi_fired_q      at most one injection per trial
              .resolver_rst_r / testmode_rst_r
   .u_fi_scan_ctrl.run / run_cnt / L_q / run_end_q
             .hit_step_q / hit_step_nx / hit_vld_q / hit_vld_nx
             .entry_pop_o      should fire |F| times per pass
             .scan_en_o / clk_gate / tm_lead / tm_tail_cnt / err_order_o
   .u_fi_table_ctrl.word_ptr       advances |F| entries per trial
               .la_index / la_vld / la_cnt / eop_fetched / fill_armed / cycle_offset_q
               .table_exhausted_o / err_malformed_o
```

**The single most useful check**: `scan_en_o` is high for exactly **L** cycles per
injection, not `|F| × L`, and the gated clock is missing exactly **L** edges over the
same span.

## C.2 Manual telnet sequence

```tcl
poll off
fi_idcode                 ;# expect 1e200a6f (before cutover)
fi_dmi_write 0x60 1
fi_dmi_flush
fi_idcode                 ;# expect f17e0006 -- if not, stop here

... load the table, write the config ...
fi_dmi_flush

# read-back (response lags one transaction: read twice, keep the second)
fi_dmi_read 0x6F ; fi_dmi_read 0x6F     ;# FI_VERSION, expect 00020000
fi_dmi_read 0x63 ; fi_dmi_read 0x63     ;# CFG_SCAN_LEN
fi_dmi_read 0x68 ; fi_dmi_read 0x68     ;# CFG_TBL_LEN (0 = forgotten, nothing injects)
fi_dmi_read 0x65 ; fi_dmi_read 0x65     ;# CFG_FI_CYCLE base
fi_dmi_read 0x69 ; fi_dmi_read 0x69     ;# FI_CYCLE, steps per trial during a sweep
fi_dmi_read 0x61 ; fi_dmi_read 0x61     ;# FI_STATUS: 0 en / 1 done / 2 order / 3 EOP / 4 overflow
```

`fi_campaign` in
[host/inject_and_run_dmi.tcl](../host/inject_and_run_dmi.tcl) is the only entry
point. The shapes you reach for during bring-up, at the telnet prompt:

```tcl
fi_campaign { {30000 {0}} {60000 {0}} }              ;# control: zero flips, real timing
fi_campaign { {30000 {2354}} {50000 {2354}} }        ;# one target, marching through time
fi_campaign { {30000 {616 617}} }                    ;# adjacent pair; SE stays high L, not 2L
fi_mbu 90000 {2354 2355 2356}                        ;# one MBU, single-shot form
fi_status_dump                                       ;# read everything that matters
```

The first one is the control run worth doing before trusting any result: `FI_Index
= 0` maps to a shift step `run_cnt` never reaches, so the scan loop runs with
identical timing and flips nothing. If the output is still disturbed, the
disturbance is structural and has nothing to do with the injected fault.

One trial is `{<absolute FI_Cycle> {<FI_Index> ...}}`, and one trial is one
scan pass, so an n-bit upset costs L shifts and not n·L:

```tcl
fi_campaign {
    {  30000 {2354} }               ;# SBU, early in the program
    {  90000 {2354} }               ;# the same flop, later
    {  90000 {2354 2355 2356} }     ;# MBU-3 at that same cycle
    { 150000 {17 600 4100} }        ;# MBU-3, scattered across the chain
}
fi_mbu 90000 {2354 2355 2356}       ;# the single-shot form
```

Cycles are absolute and on the same scale as `fi_exec_window.txt`, i.e. counted
from reset release; the proc sorts the trials, turns the gaps into the hardware's
`Cycle_Offset` increments, picks `CFG_FI_CYCLE`, sorts each pattern's indices
descending, and sizes `CFG_TO_THR`. Every limit — `Cycle_Offset` width, `FI_Index`
width, chain length, table depth — is checked **before** the first DMI write, so a
campaign that does not fit is refused rather than half-loaded.

## C.3 Known pitfalls

| # | pitfall | symptom | see |
|---|---|---|---|
| 1 | `fi_dmi_write` is one TCK edge short | the last write of a sequence hangs forever; with `poll off` the loop never starts. `fi_dmi_flush` exists for this | A.1.6 |
| 2 | passive mode forwards only `FI_MODE` | if cutover fails, every later write is dropped silently | A.1.3 |
| 3 | `sleep` produces no TCK | cutover only commits because polling supplied edges | A.1.6 |
| 4 | the response lags one transaction | `fi_dmi_read` returns the previous value; read twice | A.1.6 |
| 5 | `stick_busy_q` cannot be cleared | every read returns status=3 with no way back | A.1.3 |
| 6 | `CFG_SCAN_LEN` must equal the netlist's chain length | the chain does not complete a rotation ⇒ cannot be restored | A.2.2 |
| 7 | any stage between a peripheral and its pad that is on the chain | that pin is random for L cycles; here it was the pad mux, garbling the UART | A.3 |
| 8 | the gate must have exactly one synchroniser flop | a second stage skews the freeze window ⇒ the chain cannot be restored | A.2.2 |
| 9 | `RTC_ALIGN_EN` must be 0 when `aon_lfclk_i` does not toggle | the reset FSM sticks in phase 1 and the auto loop never advances | A.2.1 |
| 10 | `fi_cycle_q` is compared with `==` | the target must land in `[0, cfg_to_thr)`; overflowing lights STATUS bit 4 and stops the batch | A.2.1 |
| 11 | **`CFG_TBL_LEN` (0x68) must be written, before `CFG_TO_THR`** | reset value 0 ⇒ **nothing is injected** (fail-safe, not mis-injection) | A.2.3 |
| 12 | **`FI_Index` must descend within a pattern** | out-of-order entries are dropped, `FI_STATUS` bit 2 lights. Use `fi_pattern` | A.2.2 |
| 13 | **the last entry must have EOP = 1** | a table ending mid-pattern sets `FI_STATUS` bit 3 and prints `[FI-ERR]` | A.2.3 |
| 14 | **the host's `FI_W_IDX` must equal the RTL's `$clog2(N_FF)`** | no error is raised — you simply inject into the wrong flop. Read `0x6F` to confirm the format | A.2.5 |
| 15 | the testbench's drain time is shorter than the last trial | the final pattern's UART output is truncated by `$finish` | tb |
| 16 | `uart_rx_print` does not check the stop bit and triggers on a falling edge | one bogus byte per pin glitch, and the receiver is blocked for ten bit times | A.3 |
| 17 | **pad mux `RESVAL = 0` (GPIO) means the pin drops from UART idle-high at every reset** | a false start bit every trial — a garbling source that fixing the chain or the monitor does not touch | A.3 |
| 18 | **all three of gating, `set_scan_element false` and `set_dont_touch` keep instances off the chain** | do not guess which is acting. Use the explicit one and assert the outcome. **Never declare a gated clock as a ScanClock** | A.3 |
| 19 | `-fix_clock enable` may undo the gate by wiring scan-enable into it | the clock is forced through while shifting ⇒ frozen blocks move. A5 watches the gated net; if hit, `set_dft_configuration -fix_clock disable` | syn |
| 20 | 🔴 **the `FI_Index → flop` map must come from `report_scan_path`, not the SCANDEF** | SCANDEF writes the chain as `FLOATING`, an unordered set, in a different order from the one actually stitched — a map that looks normal and is entirely wrong | A.2.2 |
| 21 | 🔴 **replacing combinational gating with an ICG: the enable cannot be just the registered `gate_q`** | an ICG decides per edge from the preceding low phase, so `gate_q` alone masks **one cycle too many** and the off-chain blocks recover late. Use `E = ~(gate_q & clk_gate)` | A.3 |
| 22 | 🔴 **`all_fanout -from <clock net> -endpoints_only` does not give you "the flops on that clock"** | it walks *timing* paths: through the gated flops, out of Q, through logic, landing on downstream **D** pins. On one run it returned 3099 completely unrelated cells and A2 "failed" on pure fiction. Safety-critical checks use only the scan-path report and instance path strings | syn |
| 23 | ⚠️ **dc_shell's `source` does not stop on a Tcl error** | everything after a failed assertion still runs and still writes a netlist. What blocks misuse is `fi_export_scanmap` refusing to write the config files. Grep the log for `FI-FAIL` | syn |
| 24 | **an independent clock domain that is neither shifted nor frozen is a legitimate third category** | e.g. ~200 flops in the JTAG TCK domain, idle during the window. Declare it with `FI_EXEMPT_CLOCKS`, **not** by exempting the whole enclosing instance | syn |
| 25 | 🔴 **`fi_rst` equals `rst_ni` unless a campaign is armed** | `fi_rst = aon_rst_ni & ~resolver_rst_w`, combinational. Any monitor or checker keyed on `fi_rst` behaves identically to one keyed on `rst_ni` on a bare run, so a bare run is **no evidence at all** about it. That is how tap C looked broken when it had simply never been exercised | A.3 |
| 26 | **a monitor's reset only masks glitches inside its own reset window** | the UART pad's fabricated bytes arrive *after* reset release, while the firmware drives a GPIO that shares the pad. No choice of monitor reset can remove them; the fix is the pinmux `RESVAL`, the firmware, or tapping `uart_tx[0]` instead | A.3 |
