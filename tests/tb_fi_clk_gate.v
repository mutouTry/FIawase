// SPDX-License-Identifier: Apache-2.0
// Copyright 2025-2026 the FIawase authors
// ============================================================
// Equivalence regression: fi_clk_gate vs scan_en_sync
// ------------------------------------------------------------
//   tests/run.sh
//
// The restore rests on one number: the frozen blocks lose exactly the L
// functional clock edges the chain spends shifting. With the real
// fi_scan_ctrl, a real rotate-and-restore pass, and scan_en_sync.v (a
// synchroniser and an AND) as the reference, it checks that:
//
//   1. both gates mask exactly L cycles,
//   2. they mask the SAME cycles (zero disagreement),
//   3. the chain is restored bit-perfect with exactly one flip,
//   4. fi_clk_gate emits no short pulse (the runt scan_en_sync has at
//      the window boundary),
//   5. fi_clk_freeze behind a DUT-style clock gate (random enable, TE =
//      testmode) passes exactly the edges that gate passes, minus the L
//      window edges, with no short pulse,
//   6. the wrapper's clock enable (run_o) is 1 at exactly the edges
//      fi_clk_gate passes.
//
// Run it again after touching fi_clk_gate.v, fi_scan_ctrl.v, or the
// clk_gate/scan_en timing contract.
// ============================================================
`timescale 1ns/1ps

module tb_fi_clk_gate;

  parameter integer L      = 8;    // chain length
  parameter integer FI_INDEX    = 3;    // target position (>= L = null injection)
  parameter integer PASSES = 2;    // back-to-back injection passes

  // ---------------- clock / reset ----------------
  reg clk = 1'b0;
  always #5 clk = ~clk;
  reg rst_n = 1'b0;

  // ---------------- the real controller ----------------
  reg         cfg_start = 1'b0;
  reg  [31:0] entry_index;
  reg         entry_valid, entry_ready;
  wire        entry_pop, scan_in, scan_en, clk_gate;
  wire        done, err_order, testmode, scan_out;

  fi_scan_ctrl u_ctrl (
    .clk           (clk),         .rst_n         (rst_n),
    .cfg_start_i   (cfg_start),   .cfg_scan_len_i     (L),
    .entry_index_i   (entry_index),   .entry_valid_i (entry_valid),
    .entry_ready_i (entry_ready), .entry_pop_o   (entry_pop),
    .scan_out_i    (scan_out),    .scan_in_o     (scan_in),
    .scan_en_o     (scan_en),     .clk_gate     (clk_gate),
    .done_o        (done),        .err_order_o   (err_order),
    .testmode_o    (testmode)
  );

  always @(posedge clk or negedge rst_n)
    if (!rst_n)         entry_valid <= 1'b0;
    else if (entry_pop) entry_valid <= 1'b0;

  // ---------------- mock scan chain (never gated) ----------------
  reg [L-1:0] chain, golden, init;
  integer i, p;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) chain <= init;
    else if (scan_en) begin
      for (i = L-1; i > 0; i = i - 1) chain[i] <= chain[i-1];
      chain[0] <= scan_in;
    end
  end
  assign scan_out = chain[L-1];

  // ---------------- the two gates, same stimulus ----------------
  wire clk_old, clk_new, freeze;
  scan_en_sync u_old (.clk    (clk),  .rst_n  (rst_n),
                      .clk_gate (clk_gate), .clk_gate_clk (clk_old));
  fi_clk_gate  u_new (.clk_i  (clk),  .rst_ni (rst_n),
                      .clk_gate_i (clk_gate), .clk_o (clk_new),
                      .freeze_o (freeze));

  // ---------------- a block behind the DUT's own clock gate ----------------
  // An RTL-style gate (latch + AND, TE = testmode) with a pseudo-random
  // enable, so some window boundaries fall on cycles where the gate is
  // closed. fi_clk_freeze in series must pass exactly the edges the gate
  // passes outside the window and none inside it.
  reg [7:0] lfsr = 8'h5a;
  always @(posedge clk) lfsr <= {lfsr[6:0], lfsr[7] ^ lfsr[5] ^ lfsr[4] ^ lfsr[3]};
  reg rtl_l;
  always @(*) if (~clk) rtl_l = lfsr[0] | testmode;
  wire clk_rtl = clk & rtl_l;
  wire clk_fz;
  fi_clk_freeze u_fz (.clk_i (clk_rtl), .freeze_i (freeze), .clk_o (clk_fz));

  // ---------------- the wrapper's clock enable (fi_wrapper_top run_o) -------
  // Same synchroniser and freeze term, used as an enable on the free-running
  // clock: run sampled at an edge must be 1 exactly when fi_clk_gate passes it.
  reg run_gq;
  always @(posedge clk or negedge rst_n) if (!rst_n) run_gq <= 1'b0; else run_gq <= clk_gate;
  wire run = ~(run_gq & clk_gate);
  reg  run_s;
  always @(posedge clk) run_s = run;      // the value this edge sees

  integer nrt = 0, nfz = 0;
  always @(posedge clk_rtl) nrt = nrt + 1;
  always @(posedge clk_fz)  nfz = nfz + 1;
  real t_f;
  integer runt_f = 0;
  always @(posedge clk_fz) t_f = $realtime;
  always @(negedge clk_fz) if (rst_n && $realtime - t_f < 4.9) runt_f = runt_f + 1;

  integer nr = 0, no = 0, nn = 0;
  always @(posedge clk)     nr = nr + 1;
  always @(posedge clk_old) no = no + 1;
  always @(posedge clk_new) nn = nn + 1;

  // ---------------- pulse width watch ----------------
  real t_o, t_n, w;
  integer runt_o = 0, runt_n = 0;
  always @(posedge clk_old) t_o = $realtime;
  always @(negedge clk_old) begin
    w = $realtime - t_o;
    if (rst_n && w < 4.9) runt_o = runt_o + 1;
  end
  always @(posedge clk_new) t_n = $realtime;
  always @(negedge clk_new) begin
    w = $realtime - t_n;
    if (rst_n && w < 4.9) runt_n = runt_n + 1;
  end

  // ---------------- per-cycle mask map ----------------
  integer po = 0, pn = 0, pr = 0, mo = 0, mn = 0, disagree = 0;
  integer prt = 0, pfz = 0, fz_bad = 0, fz_mask = 0, run_bad = 0;
  always @(negedge clk) begin
    if (rst_n && nr != pr) begin
      if ((no == po) !== (nn == pn)) disagree = disagree + 1;
      if (no == po) mo = mo + 1;
      if (nn == pn) mn = mn + 1;
      // behind the DUT's gate: an edge iff that gate passed it and the
      // freeze (the same cycles fi_clk_gate masks) did not
      if ((nfz != pfz) !== ((nrt != prt) && (nn != pn))) fz_bad = fz_bad + 1;
      if ((nrt != prt) && (nn == pn)) fz_mask = fz_mask + 1;
      if (run_s !== (nn != pn)) run_bad = run_bad + 1;
    end
    pr = nr; po = no; pn = nn; prt = nrt; pfz = nfz;
  end

  // ---------------- stimulus + verdict ----------------
  integer j, fails = 0;
  reg [L-1:0] expect_v;
  initial begin
    for (i = 0; i < L; i = i + 1) init[i] = ((i*7 + 3) & 3) != 0;
    entry_index = FI_INDEX; entry_valid = 1'b0; entry_ready = 1'b1;

    #23 rst_n = 1'b1;
    @(posedge clk); @(posedge clk);
    golden = chain;

    for (j = 0; j < PASSES; j = j + 1) begin
      @(negedge clk) entry_valid = 1'b1;
      @(negedge clk) cfg_start   = 1'b1;
      @(negedge clk) cfg_start   = 1'b0;
      wait (done);
      repeat (5) @(posedge clk);
    end
    repeat (5) @(posedge clk);

    // every FI_Index below L is a cell (0 = first after Scan_In);
    // FI_Index >= L is the null injection (no flip at all)
    expect_v = golden;
    if (FI_INDEX < L)
      for (j = 0; j < PASSES; j = j + 1) expect_v = expect_v ^ (1 << FI_INDEX);

    if (mo       != L*PASSES) begin fails=fails+1;
      $display("FAIL  scan_en_sync masked %0d, expected %0d", mo, L*PASSES); end
    if (mn       != L*PASSES) begin fails=fails+1;
      $display("FAIL  fi_clk_gate  masked %0d, expected %0d", mn, L*PASSES); end
    if (disagree != 0)        begin fails=fails+1;
      $display("FAIL  the two gates disagree on %0d cycle(s)", disagree); end
    if (chain    !== expect_v) begin fails=fails+1;
      $display("FAIL  chain %b, expected %b", chain, expect_v); end
    if (runt_n   != 0)        begin fails=fails+1;
      $display("FAIL  fi_clk_gate emitted %0d short pulse(s)", runt_n); end
    // testmode holds the DUT's gate open in the window, so all L window
    // edges reach fi_clk_freeze and all of them must be masked
    if (fz_bad   != 0)        begin fails=fails+1;
      $display("FAIL  fi_clk_freeze wrong on %0d cycle(s)", fz_bad); end
    if (fz_mask  != L*PASSES) begin fails=fails+1;
      $display("FAIL  fi_clk_freeze masked %0d, expected %0d", fz_mask, L*PASSES); end
    if (runt_f   != 0)        begin fails=fails+1;
      $display("FAIL  fi_clk_freeze emitted %0d short pulse(s)", runt_f); end
    if (run_bad  != 0)        begin fails=fails+1;
      $display("FAIL  the run enable disagrees with fi_clk_gate on %0d cycle(s)", run_bad); end

    // both strings same width -- Verilog zero-pads the shorter one
    $display("L=%0d fi_index=%0d passes=%0d | masked old=%0d new=%0d gated=%0d | disagree=%0d | short pulses old=%0d new=%0d gated=%0d | %s",
             L, FI_INDEX, PASSES, mo, mn, fz_mask, disagree, runt_o, runt_n, runt_f,
             (fails == 0) ? "PASS" : "FAIL");
    if (fails) $stop;     // non-zero exit for the runner
    $finish;
  end

endmodule
