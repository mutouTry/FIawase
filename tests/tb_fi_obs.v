// SPDX-License-Identifier: Apache-2.0
// Copyright 2025-2026 the FIawase authors
// ============================================================
// Regression for the wrapper's DUT-time logic: fi_uart_obs and fi_slow_clk
// ------------------------------------------------------------
// A DUT-side UART transmitter and a reference divider run on fi_clk_gate's
// frozen clock while the real fi_scan_ctrl opens scan windows at irregular
// times, some of them in the middle of a frame. The wrapper side runs on
// the free-running clock with the run enable of fi_wrapper_top. It checks:
//   1. fi_uart_obs receives every byte, in order, with no framing error;
//   2. fi_slow_clk equals a divider of the frozen clock at every edge.
// ============================================================
`timescale 1ns/1ps

module tb_fi_obs;

  parameter integer L   = 37;    // chain length (the window is L edges)
  parameter integer CPB = 5;     // UART bit period in functional cycles
  parameter integer DIV = 16;    // slow clock period
  localparam integer NB = 24;    // bytes sent

  reg clk = 1'b0;
  always #5 clk = ~clk;
  reg rst_n = 1'b0;

  // ---------------- the real controller, null injections -----------------
  reg         cfg_start = 1'b0;
  reg         entry_valid;
  wire        entry_pop, scan_in, scan_en, clk_gate, done, err_order, testmode;
  fi_scan_ctrl u_ctrl (
    .clk (clk), .rst_n (rst_n), .cfg_start_i (cfg_start), .cfg_scan_len_i (L),
    .entry_index_i (L), .entry_valid_i (entry_valid), .entry_ready_i (1'b1),
    .entry_pop_o (entry_pop), .scan_out_i (1'b0), .scan_in_o (scan_in),
    .scan_en_o (scan_en), .clk_gate (clk_gate), .done_o (done),
    .err_order_o (err_order), .testmode_o (testmode)
  );
  always @(posedge clk or negedge rst_n)
    if (!rst_n)         entry_valid <= 1'b0;
    else if (entry_pop) entry_valid <= 1'b0;

  // ---------------- the DUT's frozen clock --------------------------------
  wire clk_dut, freeze;
  fi_clk_gate u_gate (.clk_i (clk), .rst_ni (rst_n), .clk_gate_i (clk_gate),
                      .clk_o (clk_dut), .freeze_o (freeze));

  // ---------------- DUT side: a UART transmitter on the frozen clock ------
  reg  [7:0] msg [0:NB-1];
  integer    k;
  initial for (k = 0; k < NB; k = k + 1) msg[k] = (k * 37 + 11) & 8'hff;
  reg        tx = 1'b1;
  reg        busy = 1'b0;
  reg  [9:0] frame;
  integer    tbit, tcnt, ti = 0, gap = 3;
  always @(posedge clk_dut or negedge rst_n) begin
    if (!rst_n) begin
      tx <= 1'b1; busy <= 1'b0; ti <= 0; gap <= 3; tcnt <= 0; tbit <= 0;
    end else if (!busy) begin
      if (gap > 0) gap <= gap - 1;
      else if (ti < NB) begin
        frame <= {1'b1, msg[ti], 1'b0};
        tx <= 1'b0; busy <= 1'b1; tbit <= 0; tcnt <= 0;
      end
    end else if (tcnt == CPB - 1) begin
      tcnt <= 0;
      if (tbit == 9) begin busy <= 1'b0; ti <= ti + 1; gap <= ti % 4; tx <= 1'b1; end
      else begin tbit <= tbit + 1; tx <= frame[tbit + 1]; end
    end else tcnt <= tcnt + 1;
  end

  // reference slow clock: a divider of the frozen clock
  reg     slow_ref = 1'b0;
  integer sc = 0;
  always @(posedge clk_dut or negedge rst_n)
    if (!rst_n) begin slow_ref <= 1'b0; sc <= 0; end
    else if (sc == DIV/2 - 1) begin sc <= 0; slow_ref <= ~slow_ref; end
    else sc <= sc + 1;

  // ---------------- wrapper side: free-running clock + run enable ---------
  reg run_gq;
  always @(posedge clk or negedge rst_n) if (!rst_n) run_gq <= 1'b0; else run_gq <= clk_gate;
  wire run = ~(run_gq & clk_gate);

  wire [7:0] rx_data;
  wire       rx_valid, rx_ferr;
  fi_uart_obs #(.CLKS_PER_BIT (CPB)) u_obs (
    .clk_i (clk), .run_i (run), .rst_ni (rst_n), .rx_i (tx),
    .data_o (rx_data), .valid_o (rx_valid), .ferr_o (rx_ferr)
  );
  wire slow;
  fi_slow_clk #(.DIV (DIV)) u_slow (.clk_i (clk), .run_i (run), .rst_ni (rst_n), .slow_o (slow));

  integer nrx = 0, bad_byte = 0, nferr = 0, slow_bad = 0, npass = 0;
  always @(posedge clk) begin
    if (rx_valid) begin
      if (nrx >= NB || rx_data !== msg[nrx]) bad_byte = bad_byte + 1;
      nrx = nrx + 1;
    end
    if (rx_ferr) nferr = nferr + 1;
  end
  always @(negedge clk) if (rst_n && slow !== slow_ref) slow_bad = slow_bad + 1;
  always @(posedge done) npass = npass + 1;

  // ---------------- stimulus: windows at irregular times ------------------
  integer w, fails = 0;
  initial begin
    #23 rst_n = 1'b1;
    for (w = 0; w < 12; w = w + 1) begin
      repeat (17 + (w * 29) % 61) @(posedge clk);
      @(negedge clk) entry_valid = 1'b1;
      @(negedge clk) cfg_start   = 1'b1;
      @(negedge clk) cfg_start   = 1'b0;
      wait (done);
    end
    wait (ti == NB && !busy);
    repeat (4 * CPB) @(posedge clk);

    if (nrx != NB)     begin fails = fails + 1; $display("FAIL  received %0d byte(s), sent %0d", nrx, NB); end
    if (bad_byte != 0) begin fails = fails + 1; $display("FAIL  %0d byte(s) differ", bad_byte); end
    if (nferr != 0)    begin fails = fails + 1; $display("FAIL  %0d framing error(s)", nferr); end
    if (slow_bad != 0) begin fails = fails + 1; $display("FAIL  slow clock differs on %0d cycle(s)", slow_bad); end
    $display("L=%0d cpb=%0d div=%0d | windows=%0d bytes=%0d/%0d ferr=%0d slow_bad=%0d | %s",
             L, CPB, DIV, npass, nrx, NB, nferr, slow_bad, (fails == 0) ? "PASS" : "FAIL");
    if (fails) $stop;
    $finish;
  end

endmodule
