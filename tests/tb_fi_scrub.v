// SPDX-License-Identifier: Apache-2.0
// Copyright 2025-2026 the FIawase authors
// ============================================================
// Scrub length regression: fi_scan_ctrl with SCRUB_LEN
// ------------------------------------------------------------
//   tests/run.sh
//
// A scrub shifts zeros into the first K = min(SCRUB_LEN, L) cells of the
// chain (all of L for a negative SCRUB_LEN) and none at all for K = 0. On a
// chain model holding random bits it checks that:
//
//   1. the scrub takes exactly K shift edges, with scrub_run_o high on
//      each of them and scrub_last_o on the last one only,
//   2. cells 0 .. K-1 hold 0 and cell i >= K holds what cell i-K held,
//   3. scrub_done_o pulses once, also when K = 0 (no shift at all),
//   4. an injection pass after the scrub still shifts all L cells and
//      flips exactly FF[FI_INDEX].
// ============================================================
`timescale 1ns/1ps

module tb_fi_scrub;

  parameter integer L         = 8;
  parameter integer SCRUB_LEN = 3;
  parameter integer FI_INDEX  = 2;

  localparam integer K = (SCRUB_LEN < 0 || SCRUB_LEN > L) ? L : SCRUB_LEN;

  reg clk = 1'b0;
  always #5 clk = ~clk;
  reg rst_n = 1'b0;

  reg         cfg_start = 1'b0;
  reg         scrub_req = 1'b0;
  reg  [31:0] entry_index = 32'd0;
  reg         entry_valid = 1'b0, entry_ready = 1'b0;
  wire        entry_pop, scan_in, scan_en, clk_gate, done, err_order, testmode;
  wire        scrub_done, scrub_run, scrub_last;

  reg  [L-1:0] chain;               // chain[0] = FI_Index 0, next to Scan_In
  wire        scan_out = chain[L-1];

  fi_scan_ctrl #(.SCRUB_LEN(SCRUB_LEN)) u_ctrl (
    .clk           (clk),         .rst_n          (rst_n),
    .cfg_start_i   (cfg_start),   .cfg_scan_len_i (L),
    .entry_index_i (entry_index), .entry_valid_i  (entry_valid),
    .entry_ready_i (entry_ready), .entry_pop_o    (entry_pop),
    .scan_out_i    (scan_out),    .scan_in_o      (scan_in),
    .scan_en_o     (scan_en),     .clk_gate       (clk_gate),
    .done_o        (done),
    .scrub_req_i   (scrub_req),   .scrub_done_o   (scrub_done),
    .scrub_run_o   (scrub_run),   .scrub_last_o   (scrub_last),
    .err_order_o   (err_order),   .testmode_o     (testmode)
  );

  always @(posedge clk) if (entry_pop) entry_valid <= 1'b0;   // one entry

  // the chain shifts on every edge Scan_En is high, as the DUT's scan flops
  integer shifts = 0, runs = 0, lasts = 0, dones = 0, bad_run = 0;
  always @(posedge clk) begin
    if (scan_en) begin
      chain  <= {chain[L-2:0], scan_in};
      shifts <= shifts + 1;
      if (scrub_req && !scrub_run) bad_run = bad_run + 1;
    end
    if (scrub_run) begin
      runs <= runs + 1;
      if (!scan_en) bad_run = bad_run + 1;
    end
    if (scrub_last) lasts <= lasts + 1;
    if (scrub_done) dones <= dones + 1;
  end

  reg [L-1:0] before, after, want;
  integer i, errs = 0;
  initial begin
    chain = {L{1'b0}};
    for (i = 0; i < L; i = i + 1) chain[i] = $random;
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);
    before = chain;

    // ---- the scrub ----
    @(negedge clk) scrub_req = 1'b1;
    wait (scrub_done === 1'b1);
    @(negedge clk) scrub_req = 1'b0;
    repeat (3) @(posedge clk);
    after = chain;
    for (i = 0; i < L; i = i + 1) want[i] = (i < K) ? 1'b0 : before[i-K];
    if (shifts != K)    begin errs = errs + 1; $display("FAIL shifts %0d, expected %0d", shifts, K); end
    if (runs != K)      begin errs = errs + 1; $display("FAIL scrub_run_o high %0d edges, expected %0d", runs, K); end
    if (lasts != (K ? 1 : 0)) begin errs = errs + 1; $display("FAIL scrub_last_o %0d times", lasts); end
    if (dones != 1)     begin errs = errs + 1; $display("FAIL scrub_done_o %0d pulses", dones); end
    if (bad_run != 0)   begin errs = errs + 1; $display("FAIL scrub_run_o and Scan_En disagree on %0d edges", bad_run); end
    if (after !== want) begin errs = errs + 1; $display("FAIL chain %b, expected %b (before %b)", after, want, before); end

    // ---- an injection pass after it ----
    shifts = 0;
    before = chain;
    entry_index = FI_INDEX; entry_ready = 1'b1;
    @(negedge clk) entry_valid = 1'b1;
    @(negedge clk) cfg_start   = 1'b1;
    @(negedge clk) cfg_start   = 1'b0;
    wait (done === 1'b1);
    repeat (3) @(posedge clk);
    want = before;
    want[FI_INDEX] = ~want[FI_INDEX];
    if (shifts != L)       begin errs = errs + 1; $display("FAIL pass shifts %0d, expected %0d", shifts, L); end
    if (chain !== want)    begin errs = errs + 1; $display("FAIL pass chain %b, expected %b", chain, want); end

    $display("L=%0d SCRUB_LEN=%0d K=%0d FI_INDEX=%0d errors=%0d | %s", L, SCRUB_LEN, K, FI_INDEX, errs,
             errs ? "FAIL" : "PASS");
    $finish;
  end

  initial begin #(20 * (4 * L + 100)); $display("L=%0d SCRUB_LEN=%0d TIMEOUT | FAIL", L, SCRUB_LEN); $finish; end
endmodule
