// SPDX-License-Identifier: Apache-2.0
// Copyright 2025-2026 the FIawase authors
// ============================================================
// Equivalence regression: fi_clk_gate vs scan_en_sync
// ------------------------------------------------------------
//   cd syn/tests && ./run.sh
//
// The FI wrapper's whole restore guarantee rests on one number: the
// frozen blocks must lose EXACTLY the L functional clock edges that the
// chain spends shifting. syn/fi_clk_gate.v replaces the
// scan_en_sync that is baked into the existing netlist, so before
// trusting it we check, against the REAL fi_scan_ctrl and a real
// rotate-and-restore pass, that:
//
//   1. both gates mask exactly L cycles,
//   2. they mask the SAME cycles (zero disagreement),
//   3. the chain is restored bit-perfect with exactly one flip,
//   4. fi_clk_gate emits no short pulse (the runt scan_en_sync has at
//      the window boundary).
//
// Run it again after touching fi_clk_gate.v, fi_scan_ctrl.v, or the
// clk_gate/scan_en timing contract.
// ============================================================
`timescale 1ns/1ps

module tb_fi_clk_gate;

  parameter integer L      = 8;    // chain length
  parameter integer FI_INDEX    = 3;    // target position (0 = null injection)
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
  wire clk_old, clk_new;
  scan_en_sync u_old (.clk    (clk),  .rst_n  (rst_n),
                      .clk_gate (clk_gate), .clk_gate_clk (clk_old));
  fi_clk_gate  u_new (.clk_i  (clk),  .rst_ni (rst_n),
                      .clk_gate_i (clk_gate), .clk_o (clk_new));

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
  always @(negedge clk) begin
    if (rst_n && nr != pr) begin
      if ((no == po) !== (nn == pn)) disagree = disagree + 1;
      if (no == po) mo = mo + 1;
      if (nn == pn) mn = mn + 1;
    end
    pr = nr; po = no; pn = nn;
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

    // fi_index 0 is the documented null injection (no flip at all)
    expect_v = golden;
    if (FI_INDEX != 0)
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

    // both strings same width -- Verilog zero-pads the shorter one
    $display("L=%0d fi_index=%0d passes=%0d | masked old=%0d new=%0d | disagree=%0d | short pulses old=%0d new=%0d | %s",
             L, FI_INDEX, PASSES, mo, mn, disagree, runt_o, runt_n,
             (fails == 0) ? "PASS" : "FAIL");
    if (fails) $stop;     // non-zero exit for the runner
    $finish;
  end

endmodule
