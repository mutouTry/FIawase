// SPDX-License-Identifier: Apache-2.0
// Copyright 2025-2026 the FIawase authors
// ============================================================
// FI Table Controller                     (paper Fig. 5, FI Executor)
// ------------------------------------------------------------
// This is the "rolling buffer of upcoming targets" of the paper: it
// streams FI_Entry words out of the FI Table and presents them to the
// FI Scan Controller one FI_Index at a time.
//
// FI_Entry format (docs/DESIGN.md 5.5, paper Fig. 6). NOTE that this
// differs from the encoding drawn in the paper -- the paper still shows
// a Pattern_Len COUNT field; the hardware uses a 1-bit EOP marker
// instead. docs/PAPER_ALIGNMENT.md is the reconciliation.
//
//   bit  31 30                W_IDX W_IDX-1      0
//       +---+--------------------+--------------+
//       |EOP|    Cycle_Offset    |   FI_Index   |
//       +---+--------------------+--------------+
//
//   EOP          always valid. 1 = last entry of the current replay
//                pattern. Every pattern has at least one entry, so
//                every pattern has exactly one EOP.
//   Cycle_Offset ONLY read when EOP = 1. Non-negative increment applied
//                to FI_Cycle after this pattern's trial completes.
//                Never read from a non-EOP entry.
//   FI_Index     tail-relative scan position. The Scan Controller turns
//                it into a shift step as L-1-FI_Index, so FI_Index==0
//                (and >L) is a null injection.
//
// One pattern = ONE scan pass of L shifts that flips |F| bits, so the
// whole pattern must be delivered inside a single run. That is what the
// lookahead below is for: it is pre-filled during the idle time between
// trials and refills at one word per cycle while the pass consumes it,
// so the minimum spacing between two targets in one pass is 1.
//
// End of table is COUNTED (word_ptr vs cfg_tbl_len_i), not sentinel
// based: 0x0000_0000 is now a perfectly legal entry (EOP=0, off=0,
// FI_Index=0), so the old "high byte == 0" hdr_invalid rule is gone.
//
// Surviving the FI Resolver soft reset (resolver_rst), i.e. carried across
// trials: word_ptr, cycle_offset_q, table_exhausted_o, err_malformed_o.
// Everything else is cleared, because filling restarts as soon as
// resolver_rst falls.
// ============================================================
module fi_table_ctrl #(
    parameter AW = 32,
    parameter DW = 32,
    parameter [AW-1:0] TBL_BASE_ADDR = 32'h7000_0000,
    parameter          TBL_HAVE_ID   = 0,
    // Table depth in words. Must match fi_table's TBL_WORDS.
    parameter integer  TBL_WORDS      = 256,
    // Encoding bound, see fi_scan_cfg.vh. Only its ceil(log2) is used.
    parameter integer  N_FF           = 8192,
    // Lookahead depth. >= 2 is required for back-to-back (spacing 1)
    // targets; 4 gives margin for a stalled fetch.
    parameter integer  LOOKAHEAD      = 4
)(
    input                 clk,
    input                 rst_n,

    input                 resolver_rst,   // FI Resolver soft reset; keeps the pointer

    input      [31:0]     cfg_tbl_len_i,  // Number of entries loaded in this batch
    input                 done_i,         // 1-cycle pulse at the end of a scan pass

    // Read-only bypass into the FI Table
    output     [AW-1:0]   tbl_rd_addr_o,
    input      [DW-1:0]   tbl_rdata_i,

    // FI_Index stream toward the FI Scan Controller
    output     [31:0]     entry_index_o,  // head entry's FI_Index, zero-extended
    output                entry_valid_o,  // head entry is valid
    output                entry_ready_o,  // enough of this pattern is in hand to start
    input                 entry_pop_i,    // consumer took the head entry

    // Toward fi_time_ctrl: increment for FI_Cycle after this trial
    output     [31:0]     cycle_offset_o,

    // Status
    output reg            table_exhausted_o, // whole batch consumed (sticky)
    output reg            err_malformed_o    // ran off the end without an EOP (sticky)
);

  localparam integer W_IDX = $clog2(N_FF);
  localparam integer W_OFF = 31 - W_IDX;
  localparam integer PW    = $clog2(TBL_WORDS);

  // START address = BASE + 4 * (HAVE_ID ? 1 : 0)
  localparam [AW-1:0] START_ADDR = TBL_BASE_ADDR + (TBL_HAVE_ID ? 32'd4 : 32'd0);

  // ------------------------------------------------------------
  // Elaboration-time contract checks. Instantiating a module that
  // does not exist fails elaboration in both simulation and
  // synthesis, which is the point.
  // ------------------------------------------------------------
  generate
    if (W_IDX > 30) begin : g_w_idx_too_large
      fi_illegal_parameter_W_IDX_must_be_le_30 u_err ();
    end
    if ((2 ** W_IDX) < N_FF) begin : g_w_idx_too_small
      fi_illegal_parameter_two_pow_W_IDX_lt_N_FF u_err ();
    end
    if (LOOKAHEAD < 2) begin : g_lookahead_too_small
      fi_illegal_parameter_LOOKAHEAD_must_be_ge_2 u_err ();
    end
  endgenerate

  // ------------------------------------------------------------
  // Table pointer. One word counter is the single source of truth;
  // the byte address is derived from it. It is one bit wider than
  // the word index so that word_ptr == TBL_WORDS (a full table) is
  // representable.
  // ------------------------------------------------------------
  reg  [PW:0] word_ptr;

  wire [PW:0] tbl_len_clip = (cfg_tbl_len_i > TBL_WORDS) ? TBL_WORDS[PW:0]
                                                         : cfg_tbl_len_i[PW:0];
  wire        ptr_at_end   = (word_ptr >= tbl_len_clip);

  assign tbl_rd_addr_o = START_ADDR + {{(AW-PW-2){1'b0}}, word_ptr[PW-1:0], 2'b00};

  // ------------------------------------------------------------
  // Entry field slices. Constant slices by construction: EOP is
  // anchored at bit 31 and FI_Index at the LSB side, only Cycle_Offset
  // in the middle absorbs the width. No barrel shifter anywhere.
  // ------------------------------------------------------------
  wire             ent_eop = tbl_rdata_i[31];
  wire [W_OFF-1:0] ent_cycle_offset = tbl_rdata_i[30:W_IDX];
  wire [W_IDX-1:0] ent_index = tbl_rdata_i[W_IDX-1:0];

  // ------------------------------------------------------------
  // Lookahead: plain shift register, so the head is an ordinary
  // register and the consumer's comparator sees the same timing it
  // saw when the index came from a single cfg_fi_index register.
  // ------------------------------------------------------------
  reg [W_IDX-1:0] la_index [0:LOOKAHEAD-1];
  reg             la_vld [0:LOOKAHEAD-1];
  reg [PW:0]      la_cnt;

  reg             fill_armed;    // filling allowed for the current pattern
  reg             eop_fetched;   // this pattern's EOP entry is already in hand
  reg [W_OFF-1:0] cycle_offset_q;     // latched from the EOP entry, survives resolver_rst
  reg             resolver_rst_q;

  wire do_pop  = entry_pop_i & la_vld[0];

  // A push may happen in the same cycle as a pop: net occupancy is
  // unchanged, which is what sustains one entry per cycle while a
  // pass is consuming back-to-back targets.
  wire la_has_room = (la_cnt < LOOKAHEAD[PW:0]) | do_pop;
  wire do_push     = fill_armed & ~eop_fetched & ~ptr_at_end &
                     ~table_exhausted_o & la_has_room;

  // Ran out of table before seeing an EOP: illegal input. Close the
  // pattern implicitly with offset 0 so nothing hangs, and flag it.
  wire malformed_now = fill_armed & ~eop_fetched & ptr_at_end &
                       ~table_exhausted_o;

  // Insertion slot: the shift has already moved everything down by
  // one when a pop happens in the same cycle.
  wire [PW:0] ins_idx = do_pop ? (la_cnt - {{PW{1'b0}}, 1'b1}) : la_cnt;

  integer i;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      word_ptr          <= {(PW+1){1'b0}};
      la_cnt            <= {(PW+1){1'b0}};
      fill_armed        <= 1'b0;
      eop_fetched       <= 1'b0;
      cycle_offset_q         <= {W_OFF{1'b0}};
      resolver_rst_q        <= 1'b0;
      table_exhausted_o <= 1'b0;
      err_malformed_o   <= 1'b0;
      for (i = 0; i < LOOKAHEAD; i = i + 1) begin
        la_index[i] <= {W_IDX{1'b0}};
        la_vld[i] <= 1'b0;
      end
    end else begin
      resolver_rst_q <= resolver_rst;

      if (resolver_rst) begin
        // Soft reset. Preserved: word_ptr, cycle_offset_q,
        // table_exhausted_o, err_malformed_o.
        la_cnt      <= {(PW+1){1'b0}};
        fill_armed  <= 1'b0;
        eop_fetched <= 1'b0;
        for (i = 0; i < LOOKAHEAD; i = i + 1)
          la_vld[i] <= 1'b0;
      end else begin
        // ---- Arm the fill window on the falling edge of resolver_rst.
        // The whole inter-trial gap (reset window + the run up to
        // FI_Cycle) is then available to pre-fill, so arming at the
        // trigger is a pure register load with no fetch latency.
        //
        // cycle_offset_q is read by fi_time_ctrl on exactly this edge and
        // still holds the PREVIOUS pattern's offset there: filling
        // cannot overwrite it before the next cycle. One register is
        // therefore enough, no pend/live handover needed.
        if (resolver_rst_q)
          fill_armed <= 1'b1;

        // ---- Consume the head
        if (do_pop) begin
          for (i = 0; i < LOOKAHEAD-1; i = i + 1) begin
            la_index[i] <= la_index[i+1];
            la_vld[i] <= la_vld[i+1];
          end
          la_vld[LOOKAHEAD-1] <= 1'b0;
        end

        // ---- Fetch one word per cycle. tbl_rdata_i is a combinational
        // read of word_ptr, so advancing the pointer is the whole
        // "memory access": the word is usable on the next cycle.
        if (do_push) begin
          la_index[ins_idx] <= ent_index;
          la_vld[ins_idx] <= 1'b1;
          word_ptr        <= word_ptr + {{PW{1'b0}}, 1'b1};

          if (ent_eop) begin
            cycle_offset_q   <= ent_cycle_offset;   // only ever read from an EOP entry
            eop_fetched <= 1'b1;      // stop fetching: pattern complete
          end
        end

        case ({do_push, do_pop})
          2'b10:   la_cnt <= la_cnt + {{PW{1'b0}}, 1'b1};
          2'b01:   la_cnt <= la_cnt - {{PW{1'b0}}, 1'b1};
          default: ;
        endcase

        if (malformed_now) begin
          err_malformed_o <= 1'b1;
          eop_fetched     <= 1'b1;
          cycle_offset_q       <= {W_OFF{1'b0}};
        end

        // ---- End of batch.
        // Must wait for done_i: the index stream is consumed all the
        // way through the pass, so retiring the table any earlier
        // would drop the remaining bits of the last pattern.
        if (done_i && ptr_at_end)
          table_exhausted_o <= 1'b1;
      end
    end
  end

  assign entry_index_o   = {{(32-W_IDX){1'b0}}, la_index[0]};
  assign entry_valid_o = la_vld[0];

  // Ready to start a pass once the whole pattern is in hand, or the
  // lookahead is full (patterns longer than LOOKAHEAD keep refilling
  // while the pass runs), or there is simply no more table to read.
  assign entry_ready_o = la_vld[0] &
                         (eop_fetched | (la_cnt == LOOKAHEAD[PW:0]) | ptr_at_end);

  assign cycle_offset_o = {{(32-W_OFF){1'b0}}, cycle_offset_q};

`ifndef SYNTHESIS
  always @(posedge clk) begin
    if (rst_n && malformed_now)
      $display("[FI-ERR] %m: table ran out at word %0d without an EOP entry -- last FI_Entry must have bit31 set",
               word_ptr);
  end
`endif

endmodule
