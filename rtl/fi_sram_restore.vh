// SPDX-License-Identifier: Apache-2.0
// Copyright 2025-2026 the FIawase authors
// ============================================================
// FI memory restore, for the model of a DUT memory macro
// ------------------------------------------------------------
// A DUT memory is neither reset nor on the scan chain, so whatever a trial
// wrote into it is still there in the next trial. Included in the model of a
// memory macro (a black box in the DUT netlist), this file restores the
// memory to its power-on content between two trials, while fi_time_ctrl
// keeps the DUT off it: frozen, which holds the memory's clock, or in reset
// (fi_mem_req_o / fi_mem_done_i on fi_wrapper_top).
//
// The model declares, before the include, with these names:
//   clk                                the macro's clock
//   fi_clk_i                           the wrapper's free-running clock
//                                      (fi_wrapper_top aon_hfclk_i)
//   a [FI_AW-1:0], d [FI_DW-1:0]       word address and write data
//   wenb [FI_DW/8-1:0]                 this cycle's byte write enables, active high
//   reg [FI_DW-1:0] ram [0:(1<<FI_AW)-1]   the content (the TB loads it there)
//   fi_restore_i, fi_done_o, fi_abort_o, fi_bad_o   its restore ports
//   localparam FI_AW, FI_DW, FI_KIND, FI_LOG_DEPTH, FI_BANKS, FI_FILL_WORD
// and leaves every write into ram to this file. State of its own besides the
// content (e.g. a registered read address) it returns to its power-on value
// while fi_restore_i is high, on fi_clk_i. The DUT side is unchanged: a
// write lands exactly where and when the macro model would put it (with the
// one exception below, in a trial that is being ended).
//
// FI_KIND = 0, UNDO: for a memory that normal runs never write (program
//   memory). A DUT write that changes a word pushes (word address, old word)
//   onto an undo log of FI_LOG_DEPTH entries; a write that leaves the word as
//   it was needs no undo and is not logged. The restore pops the log newest
//   first, one entry per cycle, so a word changed twice ends with its oldest
//   value. No copy of the content is kept.
//   When the log is full, a further changing write is dropped (the word keeps
//   its value, so the log stays complete) and fi_abort_o asks fi_time_ctrl to
//   end the trial at once; the host counts that trial as DUE. A normal run
//   never gets there: it does not write this memory at all.
// FI_KIND = 1, FILL: for a memory that normal runs write all the time (data
//   memory) whose power-on content is one word everywhere (FI_FILL_WORD, 0 for
//   an SRAM that starts cleared). The restore writes it into every word,
//   FI_BANKS words per cycle (one per BRAM in an FPGA mapping): 2^FI_AW /
//   FI_BANKS cycles. Nothing is recorded.
// fi_done_o is high while fi_restore_i is and the memory is back at power-on
// content; it falls with fi_restore_i. fi_bad_o (sticky) reports a DUT write
// that arrived during a restore: the DUT was not held off the memory, so the
// restore cannot be trusted and fi_time_ctrl stops the campaign.
//
// DUT accesses run on clk, the restore on fi_clk_i. A DUT may gate its
// memory's clock while the memory is idle, e.g. while it is held in reset,
// and the freeze holds it on purpose: on clk the restore could wait forever.
// The DUT cannot reach the memory during the restore, so the two never act
// on the same cycle. (On an FPGA the DUT's clock gates become clock enables
// on the free-running clock, and the restore uses that clock with its own
// enable.)
// ============================================================
localparam integer FI_DEPTH      = 1 << FI_AW;
localparam integer FI_BANK_DEPTH = FI_DEPTH / FI_BANKS;
localparam integer FI_LW         = $clog2(FI_LOG_DEPTH + 1);

integer          fi_i, fi_j;
reg [FI_AW-1:0]  fi_log_a [0:FI_LOG_DEPTH-1];
reg [FI_DW-1:0]  fi_log_d [0:FI_LOG_DEPTH-1];
reg [FI_LW-1:0]  fi_log_n;
reg [FI_DW-1:0]  fi_new;
reg              fi_full;
reg              fi_bad;
reg [FI_AW:0]    fi_fill_k;
reg              fi_fill_done;

initial begin
  fi_log_n = 0; fi_full = 1'b0; fi_bad = 1'b0; fi_fill_k = 0; fi_fill_done = 1'b0;
end

always @(posedge clk) begin
  if (!fi_restore_i) begin
    // DUT access, as the macro model does it
    fi_new = ram[a];
    for (fi_i = 0; fi_i < FI_DW / 8; fi_i = fi_i + 1)
      if (wenb[fi_i]) fi_new[8 * fi_i +: 8] = d[8 * fi_i +: 8];   // the word after this write
    if (FI_KIND == 0 && fi_new != ram[a]) begin
      if (fi_log_n < FI_LOG_DEPTH) begin
        ram[a]             <= fi_new;
        fi_log_a[fi_log_n] <= a;
        fi_log_d[fi_log_n] <= ram[a];      // the word before this write
        fi_log_n           <= fi_log_n + 1'b1;
      end else begin
        fi_full <= 1'b1;                   // dropped: the trial is being ended
      end
    end else begin
      for (fi_i = 0; fi_i < FI_DW / 8; fi_i = fi_i + 1)
        if (wenb[fi_i]) ram[a][8 * fi_i +: 8] <= d[8 * fi_i +: 8];
    end
  end else if (wenb != 0) begin
    fi_bad <= 1'b1;                        // a DUT write while the memory is restored
  end
end

// the restore, on the free-running clock
always @(posedge fi_clk_i) begin
  if (!fi_restore_i) begin
    fi_fill_k    <= 0;
    fi_fill_done <= 1'b0;
  end else if (FI_KIND == 0) begin
    if (fi_log_n != 0) begin
      ram[fi_log_a[fi_log_n - 1'b1]] <= fi_log_d[fi_log_n - 1'b1];
      fi_log_n <= fi_log_n - 1'b1;
    end else begin
      fi_full <= 1'b0;
    end
  end else if (!fi_fill_done) begin
    for (fi_j = 0; fi_j < FI_BANKS; fi_j = fi_j + 1)
      ram[fi_j * FI_BANK_DEPTH + fi_fill_k] <= FI_FILL_WORD;
    if (fi_fill_k == FI_BANK_DEPTH - 1)
      fi_fill_done <= 1'b1;
    else
      fi_fill_k <= fi_fill_k + 1'b1;
  end
end

assign fi_done_o  = fi_restore_i & ((FI_KIND == 0) ? (fi_log_n == 0) : fi_fill_done);
assign fi_abort_o = fi_full;
assign fi_bad_o   = fi_bad;

// synopsys translate_off
always @(posedge clk)
  if (fi_restore_i === 1'b1 && wenb != 0)
    $display("[FI-SRAM] %m: DUT write during a restore at t=%0t", $time);
// synopsys translate_on
