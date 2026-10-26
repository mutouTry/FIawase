// SPDX-License-Identifier: Apache-2.0
// Copyright 2025-2026 the FIawase authors
// ============================================================
// fi_sram_fpga -- a DUT memory with the FI memory restore, in block-RAM form
// ------------------------------------------------------------
// The FPGA counterpart of a memory macro model that includes fi_sram_restore.vh:
// the same behaviour at the macro's pins and the same restore, written so that
// FPGA synthesis maps the content to block RAM.
//
// It runs on the free-running clock. The macro's own clock, frozen or gated in the
// DUT, arrives as a clock enable: ce = 1 on an edge that clock has (the clock-gate
// conversion of the netlist gives it).
//
// At the macro's pins (as the simulation models):
//   ren = 1 on an edge loads the read address register from a;
//   q is the content at that register, including writes made after the read;
//   wenb (byte enables, active high) writes d at a.
//
// The content sits in BANKS block-RAM groups by the high address bits. Port A of
// each takes the writes, DUT and restore, and reads the old word (read first);
// port B reads q's word. Whenever a write lands on q's word, a bypass register
// holds that word, since a block RAM shows a write on its other port only on the
// next read.
//
// KIND = 0, UNDO: a write that changes a word is logged as (address, old word) and
//   the restore writes the old words back, newest first. The old word comes out of
//   port A one cycle after the write, so a write is logged one cycle late, and a
//   write is let through only while the log, counting the write still being
//   checked, has room. Once it is full no write gets through; if the blocked write
//   would have changed its word, abort_o rises (one cycle after the macro model
//   raises it) and the wrapper ends the trial. A write that leaves its word as it
//   was is not logged, as in the model.
// KIND = 1, FILL: the restore writes FILL_WORD into one row of every bank per
//   cycle, 2^AW / BANKS cycles.
// RESTORE_CLEARS_ADDR = 1: the read address register goes to 0 on every restore
//   cycle, for a model that resets its own state with the content.
// INIT_FILE: the power-on content ($readmemh, one word per line, one bank only);
//   "none" means FILL_WORD everywhere.
// ============================================================
module fi_sram_fpga #(
  parameter integer AW                  = 14,
  parameter integer DW                  = 32,
  parameter integer KIND                = 0,
  parameter integer LOG_DEPTH           = 64,
  parameter integer BANKS               = 1,
  parameter [DW-1:0] FILL_WORD          = {DW{1'b0}},
  parameter integer RESTORE_CLEARS_ADDR = 0,
  parameter         INIT_FILE           = "none"
)(
  input  wire              clk,
  input  wire              ce,
  input  wire [AW-1:0]     a,
  input  wire [DW-1:0]     d,
  input  wire [DW/8-1:0]   wenb,
  input  wire              ren,
  output wire [DW-1:0]     q,
  input  wire              restore_i,
  output wire              done_o,
  output wire              abort_o,
  output wire              bad_o
);
  localparam integer NB    = DW / 8;
  localparam integer BW    = (BANKS > 1) ? $clog2(BANKS) : 0;
  localparam integer RW    = AW - BW;
  localparam integer BROWS = 1 << RW;
  localparam integer LW    = $clog2(LOG_DEPTH + 1);
  localparam integer LIW   = (LOG_DEPTH > 1) ? $clog2(LOG_DEPTH) : 1;

  function [DW-1:0] bytemask(input [NB-1:0] be);
    integer i;
    begin
      for (i = 0; i < NB; i = i + 1) bytemask[8 * i +: 8] = {8{be[i]}};
    end
  endfunction

  function [BW > 0 ? BW - 1 : 0 : 0] bank_of(input [AW-1:0] x);
    bank_of = (BW > 0) ? x[AW-1 -: (BW > 0 ? BW : 1)] : 1'b0;
  endfunction

  // ---- the DUT side, and the UNDO check of the previous write
  reg  [AW-1:0]  addr_r;
  reg            pend;                 // a DUT write went through on the previous edge
  reg            pend_blk;             // a DUT write was blocked on the previous edge
  reg  [AW-1:0]  pend_a;
  reg  [DW-1:0]  pend_d;
  reg  [NB-1:0]  pend_be;
  reg  [LW-1:0]  log_n;
  reg            full, bad;

  wire [DW-1:0]  old_word;             // port A's read-first output: pend_a's word before the write
  wire           pend_chg  = (KIND == 0) && pend &&
                             (((old_word ^ pend_d) & bytemask(pend_be)) != {DW{1'b0}});
  wire           blk_chg   = (KIND == 0) && pend_blk &&
                             (((old_word ^ pend_d) & bytemask(pend_be)) != {DW{1'b0}});
  wire           log_room  = (KIND != 0) || ({1'b0, log_n} + pend_chg < LOG_DEPTH);
  wire           dut_wr    = ce && !restore_i && (wenb != {NB{1'b0}});
  wire           dut_wr_ok = dut_wr && log_room;

  // ---- the restore
  reg  [AW-1:0]  log_a [0:LOG_DEPTH-1];
  reg  [DW-1:0]  log_d [0:LOG_DEPTH-1];
  reg  [RW:0]    fill_k;
  reg            fill_done;
  wire [LIW-1:0] top_i     = log_n - 1'b1;
  // UNDO: first put back the write still being checked, then pop the log
  wire           undo_back = (KIND == 0) && restore_i && pend_chg;
  wire           undo_pop  = (KIND == 0) && restore_i && !pend_chg && (log_n != 0);
  wire           fill_wr   = (KIND != 0) && restore_i && !fill_done;
  wire [AW-1:0]  undo_a    = undo_back ? pend_a : log_a[top_i];
  wire [DW-1:0]  undo_d    = undo_back ? old_word : log_d[top_i];

  // ---- the read address register, and the bypass
  wire           rd        = ce && ren;
  wire           clr       = (RESTORE_CLEARS_ADDR != 0) && restore_i;
  wire [AW-1:0]  next_addr = rd ? a : (clr ? {AW{1'b0}} : addr_r);
  wire           rd_b      = rd || clr;            // port B reads next_addr this edge
  reg            byp_v;
  reg  [DW-1:0]  byp_w;
  reg  [BW > 0 ? BW - 1 : 0 : 0] qbank;
  wire [DW-1:0]  q_bram;
  assign q = byp_v ? byp_w : q_bram;

  // the word next_addr holds after this edge, if this edge writes it
  wire           hit_dut   = dut_wr_ok && (a == next_addr);
  wire           hit_undo  = (undo_back || undo_pop) && (undo_a == next_addr);
  wire           hit_fill  = fill_wr && (next_addr[RW-1:0] == fill_k[RW-1:0]);
  // a DUT write lands on q's own word only when no read moved the register (a read and
  // a write never share an edge at these pins), so q is the word it modifies
  wire [DW-1:0]  hit_word  = hit_dut  ? ((q & ~bytemask(wenb)) | (d & bytemask(wenb))) :
                             hit_undo ? undo_d : FILL_WORD;

  always @(posedge clk) begin
    if (rd || clr) addr_r <= next_addr;
    if (rd_b) qbank <= bank_of(next_addr);
    if (hit_dut || hit_undo || hit_fill) begin
      byp_v <= 1'b1;
      byp_w <= hit_word;
    end else if (rd_b) begin
      byp_v <= 1'b0;
    end
  end

  // ---- UNDO bookkeeping
  always @(posedge clk) begin
    pend     <= (KIND == 0) && dut_wr_ok;
    pend_blk <= (KIND == 0) && dut_wr && !log_room;
    if (dut_wr) begin
      pend_a  <= a;
      pend_d  <= d;
      pend_be <= wenb;
    end
    if (KIND == 0) begin
      if (!restore_i && pend_chg) begin
        log_a[log_n[LIW-1:0]] <= pend_a;
        log_d[log_n[LIW-1:0]] <= old_word;
      end
      if (!restore_i && pend_chg)
        log_n <= log_n + 1'b1;
      else if (undo_pop)
        log_n <= log_n - 1'b1;
      if (blk_chg)
        full <= 1'b1;
      else if (restore_i && !pend_chg && log_n == 0)
        full <= 1'b0;
    end
    if (ce && restore_i && (wenb != {NB{1'b0}}))
      bad <= 1'b1;
  end

  // ---- FILL bookkeeping
  always @(posedge clk) begin
    if (!restore_i) begin
      fill_k    <= {(RW + 1){1'b0}};
      fill_done <= 1'b0;
    end else if (fill_wr) begin
      if (fill_k == BROWS - 1)
        fill_done <= 1'b1;
      else
        fill_k <= fill_k + 1'b1;
    end
  end

  assign done_o  = restore_i && ((KIND == 0) ? (log_n == 0 && !pend_chg) : fill_done);
  assign abort_o = full;
  assign bad_o   = bad;

  // ---- the banks
  wire [DW-1:0] douta [0:BANKS-1];
  wire [DW-1:0] doutb [0:BANKS-1];
  genvar gb;
  generate
    for (gb = 0; gb < BANKS; gb = gb + 1) begin : g_bank
      (* ram_style = "block" *) reg [DW-1:0] mem [0:BROWS-1];
      reg [DW-1:0] ra, rb;
      integer i;
      initial begin
        if (INIT_FILE != "none")
          $readmemh(INIT_FILE, mem);
        else
          for (i = 0; i < BROWS; i = i + 1) mem[i] = FILL_WORD;
        ra = {DW{1'b0}};
        rb = {DW{1'b0}};
      end
      wire          sel_dut = (BW == 0) || (bank_of(a) == gb);
      wire          sel_udo = (BW == 0) || (bank_of(undo_a) == gb);
      wire [RW-1:0] pa_addr = fill_wr ? fill_k[RW-1:0] :
                              (undo_back || undo_pop) ? undo_a[RW-1:0] : a[RW-1:0];
      wire          pa_en   = fill_wr || ((undo_back || undo_pop) && sel_udo) ||
                              (ce && !restore_i && sel_dut);
      wire [NB-1:0] pa_we   = (fill_wr || ((undo_back || undo_pop) && sel_udo)) ? {NB{1'b1}} :
                              (dut_wr_ok && sel_dut) ? wenb : {NB{1'b0}};
      wire [DW-1:0] pa_din  = fill_wr ? FILL_WORD : (undo_back || undo_pop) ? undo_d : d;
      integer k;
      always @(posedge clk)
        if (pa_en) begin
          ra <= mem[pa_addr];
          for (k = 0; k < NB; k = k + 1)
            if (pa_we[k]) mem[pa_addr][8 * k +: 8] <= pa_din[8 * k +: 8];
        end
      always @(posedge clk)
        if (rd_b) rb <= mem[next_addr[RW-1:0]];
      assign douta[gb] = ra;
      assign doutb[gb] = rb;
    end
  endgenerate

  assign old_word = douta[0];          // UNDO memories have one bank
  assign q_bram   = doutb[qbank];

  initial begin
    addr_r = {AW{1'b0}}; qbank = 0; byp_v = 1'b0; byp_w = {DW{1'b0}};
    pend = 1'b0; pend_blk = 1'b0; pend_a = {AW{1'b0}}; pend_d = {DW{1'b0}}; pend_be = {NB{1'b0}};
    log_n = {LW{1'b0}}; full = 1'b0; bad = 1'b0; fill_k = {(RW + 1){1'b0}}; fill_done = 1'b0;
  end
endmodule
