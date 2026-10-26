// SPDX-License-Identifier: Apache-2.0
// Copyright 2025-2026 the FIawase authors
// ============================================================
// Regression for the FI memory restore, rtl/fi_sram_restore.vh
// ------------------------------------------------------------
// A 16-word model includes the restore. DUT writes (byte enables, a word
// written twice, a write that changes nothing; FILL: every word), then a
// restore: fi_done_o must rise and every word must be back at its power-on
// content. A second round: UNDO fills its log, so the write after that is
// dropped and fi_abort_o is high until the restore; FILL restores again.
// A DUT write during a restore does not land and sets fi_bad_o, which stays
// set.
// ============================================================
`timescale 1ns/1ps

module fi_mem_model #(parameter integer KIND = 0) (
  input         clk, fi_clk_i,
  input  [3:0]  a,
  input  [31:0] d,
  input  [3:0]  wenb,
  input         fi_restore_i,
  output        fi_done_o, fi_abort_o, fi_bad_o
);
  localparam integer FI_AW = 4, FI_DW = 32, FI_KIND = KIND, FI_LOG_DEPTH = 4, FI_BANKS = 2;
  localparam [31:0]  FI_FILL_WORD = 32'h0;
  reg [FI_DW-1:0] ram [0:(1<<FI_AW)-1];
  `include "fi_sram_restore.vh"
endmodule

module tb_fi_sram_restore;

  parameter integer KIND = 0;

  reg clk = 1'b0;
  always #5 clk = ~clk;

  reg  [3:0]  a = 4'd0;
  reg  [31:0] d = 32'd0;
  reg  [3:0]  wenb = 4'd0;
  reg         restore = 1'b0;
  wire        done, abort, bad;
  fi_mem_model #(.KIND (KIND)) u_mem (
    .clk (clk), .fi_clk_i (clk), .a (a), .d (d), .wenb (wenb),
    .fi_restore_i (restore), .fi_done_o (done), .fi_abort_o (abort), .fi_bad_o (bad)
  );

  reg [31:0] init [0:15];
  integer    i, fails = 0, cycles;
  initial for (i = 0; i < 16; i = i + 1) begin
    init[i] = KIND ? 32'h0 : {4{i[3:0], ~i[3:0]}};
    u_mem.ram[i] = init[i];
  end

  task wr(input [3:0] wa, input [31:0] wd, input [3:0] we);
    begin
      @(negedge clk) begin a = wa; d = wd; wenb = we; end
      @(negedge clk) wenb = 4'd0;
    end
  endtask

  task restore_all;
    begin
      cycles = 0;
      @(negedge clk) restore = 1'b1;
      while (!done && cycles < 100) begin @(negedge clk); cycles = cycles + 1; end
      if (done !== 1'b1) begin fails = fails + 1; $display("FAIL  fi_done_o did not rise"); end
      @(negedge clk) restore = 1'b0;
      #1 if (done !== 1'b0) begin fails = fails + 1; $display("FAIL  fi_done_o stays high"); end
    end
  endtask

  task expect_word(input [3:0] wa, input [31:0] want, input [8*24-1:0] what);
    if (u_mem.ram[wa] !== want) begin
      fails = fails + 1;
      $display("FAIL  %0s: word %0d = %h, expected %h", what, wa, u_mem.ram[wa], want);
    end
  endtask

  task expect_power_on(input [8*24-1:0] what);
    begin
      for (i = 0; i < 16; i = i + 1) expect_word(i, init[i], what);
    end
  endtask

  initial begin
    repeat (2) @(posedge clk);
    // DUT writes land as the macro would put them
    wr(3, 32'hDEAD_BEEF, 4'b1111);
    wr(3, 32'h0000_00AA, 4'b0001);
    wr(5, init[5],       4'b1111);
    wr(9, 32'h1234_5678, 4'b0110);
    expect_word(3, 32'hDEAD_BEAA, "write");
    expect_word(5, init[5], "write");
    expect_word(9, (init[9] & 32'hFF00_00FF) | 32'h0034_5600, "write");
    if (KIND == 0 && u_mem.fi_log_n !== 3) begin
      fails = fails + 1; $display("FAIL  undo log holds %0d entries, expected 3", u_mem.fi_log_n);
    end
    if (KIND == 1) for (i = 0; i < 16; i = i + 1) wr(i, 32'hA5A5_0000 | i, 4'b1111);
    restore_all;
    expect_power_on("restore");
    if (KIND == 1 && cycles < 16 / 2) begin
      fails = fails + 1; $display("FAIL  fill done after %0d cycles", cycles);
    end
    $display("restore after %0d cycle(s)", cycles);

    // a second round: UNDO fills its log, so the fifth changing write is dropped and ends the trial
    for (i = 0; i < 5; i = i + 1) wr(i, 32'hFFFF_0000 | i, 4'b1111);
    if (KIND == 0) begin
      expect_word(4, init[4], "dropped");
      if (abort !== 1'b1) begin fails = fails + 1; $display("FAIL  fi_abort_o low on a full log"); end
    end
    restore_all;
    expect_power_on("second restore");
    if (abort !== 1'b0) begin fails = fails + 1; $display("FAIL  fi_abort_o high after the restore"); end

    // a DUT write during a restore
    @(negedge clk) restore = 1'b1;
    @(negedge clk) begin a = 4'd7; d = 32'h5555_5555; wenb = 4'b1111; end
    @(negedge clk) wenb = 4'd0;
    expect_word(7, init[7], "write during restore");
    repeat (16) @(negedge clk);
    restore = 1'b0;
    @(negedge clk);
    if (bad !== 1'b1) begin fails = fails + 1; $display("FAIL  fi_bad_o not set and held after a write during a restore"); end

    $display("kind=%0s | %s", KIND ? "FILL" : "UNDO", (fails == 0) ? "PASS" : "FAIL");
    $finish;
  end

endmodule
