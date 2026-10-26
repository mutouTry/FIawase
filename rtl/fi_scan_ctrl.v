// SPDX-License-Identifier: Apache-2.0
// Copyright 2025-2026 the FIawase authors
// ============================================================
// FI Scan Controller                      (docs/DESIGN.md 1.2)
// ------------------------------------------------------------
// Figure name -> code name
//   Scan_Len  cfg_scan_len_i    Scan_En   scan_en_o
//   FI_Index  entry_index_i     Scan_Out  scan_out_i
//   Clk_Gate  clk_gate          Scan_In   scan_in_o
//
// The figure compares the scan counter against FI_Index directly. Here
// run_cnt counts head-first, so the comparison is against the derived
// shift step hit_step = L-1-FI_Index: same instant, two coordinate
// systems. FI_Index is never renamed away from the FI_Entry field.
//
// One replay pattern = ONE pass of L shifts that flips |F| bits.
//
// The restore invariant: the k-th
// step reads V[L-1-k] and the bit injected at step k lands in FF[L-1-k]
// after the remaining L-1-k steps. That relation holds independently for
// every hit, so flipping at k1/k2/k3 within one pass gives exactly three
// flipped FFs and a fully restored chain otherwise.
//
// Edge accounting:
//   S      clk_gate<=1, tm_lead<=1
//   S+1    run<=1, run_cnt<=0, scan_en_o<=1, testmode_o rises  (scan_en trails gate by 1)
//   S+2..  S+L+1  run_cnt 0->L-1, the L masked edges
//   S+L+1  done_o, shutdown; testmode_o falls on the following falling edge
// scan_en_o must keep trailing clk_gate by exactly one cycle and the
// freeze gate's synchroniser (fi_clk_gate) must stay a single flop, or the
// chain cannot be restored.
//
// testmode_o rises with scan_en_o and, after an injection pass, falls half a
// cycle after it, on the falling clock edge (TM_LEAD = TM_TAIL_CYCLES = 0):
// only shift edges see it, so it cannot touch a functional edge -- the last
// one before the pass, which captures the state being injected, or the first
// ones after it. The half cycle is for the test-mode muxes the DFT flow puts
// in front of asynchronous sets and resets: on the last shift edge the chain
// takes its restored values, and a mux that switched on that same edge, with
// its functional input still changing, could pass a glitch to the pin. On the
// falling edge the chain has settled and only testmode changes. After a scrub
// testmode falls with scan_en_o (below).
// A DUT may use testmode for more than its reset muxes (e.g. to block bus
// requests while the chain shifts). TM_LEAD = 1 and/or a TM_TAIL_CYCLES > 0
// widen the window by one cycle before and some cycles after, for a DUT that
// needs that and does not use testmode functionally.
// ============================================================
module fi_scan_ctrl (
  input  wire        clk,
  input  wire        rst_n,

  // === Configuration ===
  input  wire        cfg_start_i,     // Write 0->1 to trigger a run; must return to 0 before the next trigger
  input  wire [31:0] cfg_scan_len_i,  // Scan_Len: chain length L (if 0, ignore start)

  // === FI_Index stream (from the FI Table Controller) ===
  input  wire [31:0] entry_index_i,   // head entry's FI_Index, tail-relative
  input  wire        entry_valid_i,   // head entry is valid
  input  wire        entry_ready_i,   // enough of the pattern is in hand to start
  output wire        entry_pop_o,     // consume the head entry

  // === Scan-chain datapath ===
  input  wire        scan_out_i,      // Scan_Out from DUT
  output wire        scan_in_o,       // Scan_In to DUT (pass-through, or inverted at a target)
  output reg         scan_en_o,       // Scan_En

  // === Freeze control for the unscanned part of the DUT ===
  output reg         clk_gate,        // Clk_Gate

  // === Status ===
  output reg         done_o,          // 1-cycle pulse at the end of the pass

  // === Scrub (FI Resolver reset window) ===
  // While scrub_req_i is high and the block is idle, run one pass that
  // shifts zeros into the chain instead of rotating it, then pulse
  // scrub_done_o. SCRUB_LEN shifts are enough when the cells without a reset
  // lead the chain (synthesis puts them there and reports their count as
  // FI_SCRUB_LEN): they take the zeros, and the DUT reset that follows puts
  // every later cell back. It runs at the end of a trial, before the DUT reset, with
  // Clk_Gate freezing the unscanned part as in any pass. testmode_o drops
  // with Scan_En (no tail): the FI Time Controller asserts the DUT reset on
  // the last shift edge (scrub_last_o), and the reset must not meet
  // testmode. done_o does not pulse for a scrub.
  input  wire        scrub_req_i,
  output reg         scrub_done_o,
  output wire        scrub_run_o,     // a scrub is shifting (the freeze is on)
  output wire        scrub_last_o,    // this cycle's edge is the scrub's last shift
  output reg         err_order_o,     // entries were not in descending FI_Index order (sticky)

  // === Test mode windowing ===
  output wire        testmode_o       // Drives test mode; high with SE (see TM_LEAD, TM_TAIL_CYCLES)
);

  // Raise testmode one cycle before SE (1) or with it (0)
  parameter integer TM_LEAD = 0;
  // Number of cycles to keep testmode asserted after SE deasserts (0..3)
  parameter integer TM_TAIL_CYCLES = 0;
  // Shifts of a scrub: the number of chain cells, counted from Scan_In, that
  // the DUT reset does not put back. Negative: the whole chain (L). A scrub
  // never shifts more than L.
  parameter integer SCRUB_LEN = -1;
  reg [1:0] tm_tail_cnt;             // Tail counter (width matches expected max tail cycles)
  reg       tm_q;                    // the test-mode window, on rising edges

  wire tm_tail = (tm_tail_cnt != 2'd0); // Tail is active whenever counter is non-zero

  // --- Rising-edge detect for cfg_start_i ---
  reg start_d;
  wire start_pulse = cfg_start_i & ~start_d; // Single-cycle pulse on 0->1

  // --- Run state and bit counter ---
  reg        run;                              // Inside a shift run
  reg        scrub_q;                          // The current run is a scrub
  reg [31:0] run_cnt;                          // Bit index within the pass [0..L-1]

  // --- Lead/tail timing for testmode window ---
  reg tm_lead;                                 // The cycle between arming and SE rising
  wire busy = run | tm_lead | tm_tail;         // Any of these mean the block is active

  // --- Per-run latched parameters ---
  reg [31:0] L_q;                              // Latched chain length
  reg [31:0] run_end_q;                        // Last index for this pass

  // --- Combinational helpers evaluated from current cfg ---
  wire [31:0] L               = cfg_scan_len_i;
  wire        cfg_scan_len_is_zero = (L == 32'd0);

  // FI_Index -> shift step:
  //  - FI_Index 0 .. L-1 -> L-1-FI_Index (FI_Index 0 is the first cell after Scan_In)
  //  - FI_Index >= L     -> step L, which run_cnt never reaches -> null injection
  wire [31:0] hit_step_of =
    (entry_index_i >= L) ? (L) : (L - 32'd1 - entry_index_i);

  // Shift ends at L-1
  wire [31:0] run_end_calc = (L - 32'd1);

  // A scrub shifts min(SCRUB_LEN, L) times; none at all if that is 0.
  localparam [31:0] SCRUB_K = (SCRUB_LEN < 0) ? 32'hFFFF_FFFF : SCRUB_LEN;
  wire [31:0] scrub_n         = (L < SCRUB_K) ? L : SCRUB_K;
  wire        scrub_none      = (scrub_n == 32'd0);
  wire [31:0] scrub_end_calc  = scrub_n - 32'd1;

  // ------------------------------------------------------------
  // Two-deep index front end.
  //
  // This is what makes back-to-back targets (spacing 1) work: the
  // armed index and the next index are both already registered here,
  // so on a hit the comparator switches to the next target on the very
  // next cycle without waiting for a fetch.
  // ------------------------------------------------------------
  reg [31:0] hit_step_q,  hit_step_nx;
  reg        hit_vld_q,  hit_vld_nx;

  wire hit   = run & hit_vld_q & (run_cnt == hit_step_q);
  // run_cnt has already passed this target: the host did not emit the
  // pattern in descending FI_Index order. Drop the entry so the rest of the
  // pattern still lands, and raise a sticky flag instead of silently
  // injecting in the wrong place.
  wire stale = run & hit_vld_q & (run_cnt >  hit_step_q);
  // FI_Index >= L maps to step L, which run_cnt never reaches. Retire
  // it right away (null injection, no flip) so it cannot block the rest
  // of the pattern behind it. Not an error: a null entry is legal.
  wire null_e = run & hit_vld_q & (hit_step_q > run_end_q);

  wire advance = hit | stale | null_e;

  // Arm slot 0 at S, slot 1 at S+1.
  wire arm0 = start_pulse & ~cfg_scan_len_is_zero & ~busy & entry_ready_i;
  wire arm1 = tm_lead & ~run & ~scrub_q;
  // A scrub starts only from idle, and not again on the cycle after its own
  // done pulse (the request is still high then).
  wire arm_s = scrub_req_i & ~busy & ~arm0 & ~scrub_done_o;

  assign entry_pop_o = entry_valid_i & (arm0 | arm1 | advance);

  // Data path: pass-through except invert on the armed index while running
  assign scan_in_o = scrub_q ? 1'b0 : (hit ? ~scan_out_i : scan_out_i);

  assign scrub_run_o  = run & scrub_q;
  assign scrub_last_o = run & scrub_q & (run_cnt == run_end_q);

  // === Main sequential control ===
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      start_d     <= 1'b0;

      run         <= 1'b0;
      run_cnt     <= 32'd0;
      scan_en_o   <= 1'b0;
      clk_gate   <= 1'b0;
      done_o      <= 1'b0;
      scrub_q     <= 1'b0;
      scrub_done_o <= 1'b0;

      tm_q  <= 1'b0;
      tm_lead     <= 1'b0;
      tm_tail_cnt <= 2'd0;

      L_q         <= 32'd0;
      run_end_q   <= 32'd0;

      hit_step_q   <= 32'd0;
      hit_step_nx  <= 32'd0;
      hit_vld_q   <= 1'b0;
      hit_vld_nx  <= 1'b0;

      err_order_o <= 1'b0;
    end else begin
      // Edge capture
      start_d <= cfg_start_i;

      // Default strobes
      done_o <= 1'b0;
      scrub_done_o <= 1'b0;

      if (stale)
        err_order_o <= 1'b1;

      // Slide the front end on every consumed target, hit or dropped.
      if (advance) begin
        hit_step_q  <= hit_step_nx;
        hit_vld_q  <= hit_vld_nx;
        hit_step_nx <= hit_step_of;
        hit_vld_nx <= entry_valid_i;
      end

      if (run) begin
        // Running: advance or complete the pass
        if (run_cnt == run_end_q) begin
          // Shutdown sequence: one pattern is exactly one pass.
          run         <= 1'b0;
          scan_en_o   <= 1'b0;
          clk_gate   <= 1'b0;
          if (scrub_q) begin
            scrub_done_o <= 1'b1;
            scrub_q      <= 1'b0;
            tm_q   <= 1'b0;             // no tail: let the reset back in now
          end else begin
            done_o      <= 1'b1;               // Pulse at the end of the pass
            if (TM_TAIL_CYCLES == 0)
              tm_q  <= 1'b0;             // with SE
            else
              tm_tail_cnt <= TM_TAIL_CYCLES[1:0]; // Keep testmode for a short tail window
          end

          hit_vld_q   <= 1'b0;               // drop anything left over (e.g. a null entry)
          hit_vld_nx  <= 1'b0;
        end else begin
          run_cnt <= run_cnt + 32'd1;
        end

      end else if (tm_lead) begin
        // Lead cycle: SE (and TM, unless TM_LEAD already raised it) rises now
        // and the run begins. Also the second arming slot.
        run        <= 1'b1;
        run_cnt    <= 32'd0;
        scan_en_o  <= 1'b1;
        tm_q <= 1'b1;
        tm_lead    <= 1'b0;

        hit_step_nx <= hit_step_of;
        hit_vld_nx <= entry_valid_i & ~scrub_q;

      end else if (tm_tail) begin
        // Tail window: SE is low; drop TM when tail counter expires
        if (tm_tail_cnt == 2'd1) begin
          tm_q <= 1'b0;
        end
        tm_tail_cnt <= tm_tail_cnt - 2'd1;

      end else begin
        // Idle: pass-through behavior with SE/TM low
        scan_en_o <= 1'b0;

        // TM is raised only by a run. A start request that cannot arm (no
        // entry ready, e.g. before the table loop is on) must leave TM low:
        // nothing in idle would lower it again.
        if (arm0) begin
          clk_gate  <= 1'b1;     // Open gate at start

          if (TM_LEAD != 0)
            tm_q <= 1'b1;   // TM leads SE by one cycle
          tm_lead    <= 1'b1;

          // Latch all parameters for this run
          L_q        <= L;
          run_end_q  <= run_end_calc;

          hit_step_q  <= hit_step_of;
          hit_vld_q  <= entry_valid_i;
          hit_vld_nx <= 1'b0;     // filled on the next cycle by the tm_lead branch
        end else if (arm_s) begin
          if (scrub_none) begin
            scrub_done_o <= 1'b1;  // no chain configured, or no cell without a reset: nothing to scrub
          end else begin
            clk_gate   <= 1'b1;
            if (TM_LEAD != 0)
              tm_q <= 1'b1;
            tm_lead    <= 1'b1;
            L_q        <= L;
            run_end_q  <= scrub_end_calc;
            hit_vld_q  <= 1'b0;   // a scrub flips nothing and pops nothing
            hit_vld_nx <= 1'b0;
            scrub_q    <= 1'b1;
          end
        end
      end
    end
  end

  // After an injection pass the window closes on the falling edge after the
  // last shift edge (see the top); a scrub closes it on that edge itself.
  reg tm_half;
  always @(negedge clk or negedge rst_n)
    if (!rst_n) tm_half <= 1'b0;
    else        tm_half <= tm_q & ~scrub_q;
  assign testmode_o = tm_q | tm_half;

endmodule
