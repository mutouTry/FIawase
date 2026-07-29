// SPDX-License-Identifier: Apache-2.0
// Copyright 2025-2026 the FIawase authors
// ============================================================
// FI Scan Controller                      (paper Fig. 5, FI Executor)
// ------------------------------------------------------------
// Paper name -> code name
//   Scan_Len  cfg_scan_len_i    Scan_En   scan_en_o
//   FI_Index  entry_index_i     Scan_Out  scan_out_i
//   Clk_Gate  clk_gate          Scan_In   scan_in_o
//
// The paper compares the scan counter against FI_Index directly. Here
// run_cnt counts head-first, so the comparison is against the derived
// shift step hit_step = L-1-FI_Index: same instant, two coordinate
// systems. FI_Index is never renamed away from the FI_Entry field.
//
// One replay pattern = ONE pass of L shifts that flips |F| bits.
// (It used to be |F| passes of L shifts each, with SE/gate held
// across all of them; that cost N x L cycles of frozen DUT.)
//
// The shift datapath and the restore invariant are unchanged: the k-th
// step reads V[L-1-k] and the bit injected at step k lands in FF[L-1-k]
// after the remaining L-1-k steps. That relation holds independently for
// every hit, so flipping at k1/k2/k3 within one pass gives exactly three
// flipped FFs and a fully restored chain otherwise.
//
// Edge accounting (docs/DEBUG_NOTES.md A.2.2) is untouched:
//   S      clk_gate<=1, testmode_o<=1, tm_lead<=1
//   S+1    run<=1, run_cnt<=0, scan_en_o<=1        (scan_en trails gate by 1)
//   S+2..  S+L+1  run_cnt 0->L-1, the L masked edges
//   S+L+1  done_o, shutdown
// scan_en_o must keep trailing clk_gate by exactly one cycle and
// scan_en_sync must stay a single flop, or the chain cannot be restored.
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
  output reg         err_order_o,     // entries were not in descending FI_Index order (sticky)

  // === Test mode windowing ===
  output reg         testmode_o       // Drives test mode; leads SE by 1 cycle and lags it by TM_TAIL_CYCLES
);

  // Number of cycles to keep testmode asserted after SE deasserts
  parameter integer TM_TAIL_CYCLES = 3;
  reg [1:0] tm_tail_cnt;             // Tail counter (width matches expected max tail cycles)

  wire tm_tail = (tm_tail_cnt != 2'd0); // Tail is active whenever counter is non-zero

  // --- Rising-edge detect for cfg_start_i ---
  reg start_d;
  wire start_pulse = cfg_start_i & ~start_d; // Single-cycle pulse on 0->1

  // --- Run state and bit counter ---
  reg        run;                              // Inside a shift run
  reg [31:0] run_cnt;                          // Bit index within the pass [0..L-1]

  // --- Lead/tail timing for testmode window ---
  reg tm_lead;                                 // Assert TM 1 cycle before SE rises
  wire busy = run | tm_lead | tm_tail;         // Any of these mean the block is active

  // --- Per-run latched parameters ---
  reg [31:0] L_q;                              // Latched chain length
  reg [31:0] run_end_q;                        // Last index for this pass

  // --- Combinational helpers evaluated from current cfg ---
  wire [31:0] L               = cfg_scan_len_i;
  wire        cfg_scan_len_is_zero = (L == 32'd0);

  // FI_Index -> shift step. Tail semantics, unchanged:
  //  - FI_Index 0 or > L -> step L, which run_cnt never reaches -> null injection
  //  - else              -> L-1-FI_Index
  wire [31:0] hit_step_of =
    ((entry_index_i == 32'd0) || (entry_index_i > L)) ? (L) : (L - 32'd1 - entry_index_i);

  // Shift ends at L-1
  wire [31:0] run_end_calc = (L - 32'd1);

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
  // FI_Index==0 or >L maps to step L, which run_cnt never reaches. Retire
  // it right away (null injection, no flip) so it cannot block the rest
  // of the pattern behind it. Not an error: this is how T12 works.
  wire null_e = run & hit_vld_q & (hit_step_q > run_end_q);

  wire advance = hit | stale | null_e;

  // Arm slot 0 at S, slot 1 at S+1.
  wire arm0 = start_pulse & ~cfg_scan_len_is_zero & ~busy & entry_ready_i;
  wire arm1 = tm_lead & ~run;

  assign entry_pop_o = entry_valid_i & (arm0 | arm1 | advance);

  // Data path: pass-through except invert on the armed index while running
  assign scan_in_o = hit ? ~scan_out_i : scan_out_i;

  // === Main sequential control ===
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      start_d     <= 1'b0;

      run         <= 1'b0;
      run_cnt     <= 32'd0;
      scan_en_o   <= 1'b0;
      clk_gate   <= 1'b0;
      done_o      <= 1'b0;

      testmode_o  <= 1'b0;
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
          done_o      <= 1'b1;               // Pulse at the end of the pass

          // Shutdown sequence. There is no multi-round continuation any
          // more: one pattern is exactly one pass.
          run         <= 1'b0;
          scan_en_o   <= 1'b0;
          clk_gate   <= 1'b0;
          tm_tail_cnt <= TM_TAIL_CYCLES[1:0]; // Keep testmode for a short tail window

          hit_vld_q   <= 1'b0;               // drop anything left over (e.g. FI_Index==0)
          hit_vld_nx  <= 1'b0;
        end else begin
          run_cnt <= run_cnt + 32'd1;
        end

      end else if (tm_lead) begin
        // Lead cycle: TM already 1, SE rises now and run begins.
        // Also the second arming slot.
        run        <= 1'b1;
        run_cnt    <= 32'd0;
        scan_en_o  <= 1'b1;
        tm_lead    <= 1'b0;      // TM remains asserted

        hit_step_nx <= hit_step_of;
        hit_vld_nx <= entry_valid_i;

      end else if (tm_tail) begin
        // Tail window: SE is low; drop TM when tail counter expires
        if (tm_tail_cnt == 2'd1) begin
          testmode_o <= 1'b0;
        end
        tm_tail_cnt <= tm_tail_cnt - 2'd1;

      end else begin
        // Idle: pass-through behavior with SE/TM low
        scan_en_o <= 1'b0;

        // Arm TM one cycle before the run starts
        if (cfg_start_i) begin
          testmode_o <= 1'b1;
        end
        if (arm0) begin
          clk_gate  <= 1'b1;     // Open gate at start

          testmode_o <= 1'b1;     // TM leads SE by one cycle
          tm_lead    <= 1'b1;

          // Latch all parameters for this run
          L_q        <= L;
          run_end_q  <= run_end_calc;

          hit_step_q  <= hit_step_of;
          hit_vld_q  <= entry_valid_i;
          hit_vld_nx <= 1'b0;     // filled on the next cycle by the tm_lead branch
        end
      end
    end
  end

endmodule
