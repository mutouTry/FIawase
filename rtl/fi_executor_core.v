// SPDX-License-Identifier: Apache-2.0
// Copyright 2025-2026 the FIawase authors
// ============================================================
// FI Executor core                        (docs/DESIGN.md 1.2)
// ------------------------------------------------------------
// Wiring between the three replay-execution controllers plus the
// FI_Index source select. The blocks themselves are:
//   fi_time_ctrl   FI Time Controller (and FI Resolver)
//   fi_scan_ctrl   FI Scan Controller
//   fi_table_ctrl  FI Table Controller
// ============================================================
module fi_executor_core #(
  // Reset-window pacing; see fi_time_ctrl for the full description.
  //   RTC_ALIGN_EN = 1 -> align the reset window to aon_rtcToggle_a
  //                       (DUT has an independent slow clock domain)
  //   RTC_ALIGN_EN = 0 -> single-clock DUT, pace by RST_CYC hf cycles
  //                       and ignore aon_rtcToggle_a entirely
  parameter integer RTC_ALIGN_EN = 0,
  parameter integer RST_CYC      = 32,
  parameter integer SCRUB        = 1,
  parameter integer SCRUB_LEN    = -1,  // shifts of a scrub (fi_scan_ctrl); negative: the whole chain
  parameter integer MEM_RESTORE  = 1,

  // FI table geometry. N_FF is an encoding bound (only its ceil(log2)
  // matters, it fixes the FI_Entry field boundaries); TBL_WORDS must
  // match fi_table.
  parameter integer N_FF         = 8192,
  parameter integer TBL_WORDS    = 256,
  parameter integer LOOKAHEAD    = 4
)(
  // =========================
  // Config inputs from the FI Transporter
  // =========================
  input  wire        cfg_auto_i,       // 1 = table driven, 0 = static CFG_FI_INDEX
  input  wire        cfg_start_i,      // user-visible start request
  input  wire [31:0] cfg_scan_len_i,   // Scan_Len
  input  wire [31:0] cfg_fi_index_i,   // FI_Index, static (non-auto) mode only
  input  wire        cfg_end_i,        // end/stop flag for the Time Controller
  input  wire [31:0] cfg_fi_cycle_i,   // FI_Cycle base
  input  wire        cfg_fi_cycle_wr_i,// 1-cycle strobe: host wrote CFG_FI_CYCLE
  input  wire [31:0] cfg_to_thr_i,     // TO_Thr
  input  wire [31:0] cfg_tbl_len_i,    // number of FI_Entry words in this batch

  // =========================
  // FI Table read path
  // =========================
  output wire        cfg_en_able_o,    // 1 = table-driven mode is active
  output wire [31:0] tbl_rd_addr_o,    // word address into the FI Table
  input  wire [31:0] tbl_rdata_i,      // FI_Entry read back

  // =========================
  // Status back to the host
  // =========================
  output wire [31:0] fi_cycle_o,       // current (running) FI_Cycle
  output wire        table_exhausted_o,
  output wire        err_order_o,
  output wire        err_malformed_o,
  output wire        fi_cycle_ovf_o,

  // =========================
  // DUT scan / test interface
  // =========================
  output wire        resolver_rst_o,
  output wire        clk_gate_o,
  input  wire        scan_out_i,
  output wire        scan_in_o,
  output wire        scan_en_o,
  output wire        testmode_o,

  // =========================
  // DUT memory restore (FI memory models, rtl/fi_sram_restore.vh)
  // =========================
  output wire        mem_req_o,
  input  wire        mem_done_i,
  input  wire        mem_abort_i,
  input  wire        mem_bad_i,
  output wire        mem_halt_o,
  output wire        mem_abort_last_o,
  output wire        stopped_o,        // the trial has stopped (fi_time_ctrl)

  // =========================
  // Clocks / reset
  // =========================
  input  wire        aon_rtcToggle_a,
  input  wire        clk,              // system/control clock domain
  input  wire        rst_n
);

  // --------------------------------------------------------------------------
  // Internal derived config/control
  // --------------------------------------------------------------------------
  wire        scan_start;

  wire        resolver_rst;
  wire        testmode_rst;
  wire        testmode_sc;             // testmode from fi_scan_ctrl

  reg         cfg_en_able_r;
  reg         resolver_rst_q;

  wire        resolver_rst_rise;

  wire        scan_done_int;
  wire        clk_gate_int;

  wire        start_usr;
  wire        scan_ctrl_cfg_start;
  wire        scrub_req;                // FI Time Controller -> Scan Controller
  wire        scrub_done;
  wire        scrub_run;                // the scrub is shifting
  wire        scrub_last;               // its last shift edge

  wire [31:0] cycle_offset_w;

  // Injection target stream: table side vs static side
  wire [31:0] tbl_index;
  wire        tbl_valid;
  wire        tbl_ready;
  wire        entry_pop;

  wire [31:0] entry_index_sel;
  wire        entry_valid_sel;
  wire        arm_ok;

  reg         static_first;

  reg s1, s2;

  assign resolver_rst_rise = resolver_rst & ~resolver_rst_q;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cfg_en_able_r <= 1'b0;
      resolver_rst_q    <= 1'b0;
    end else begin
      resolver_rst_q <= resolver_rst;
      if (!cfg_auto_i)
        cfg_en_able_r <= 1'b0;
      else if (table_exhausted_o || fi_cycle_ovf_o)
        // Batch is over: either every entry has been replayed, or the
        // cycle sweep has stepped past the trial window. table_exhausted
        // is raised on the last pattern's done pulse, never mid-pass --
        // the index stream is consumed all the way through a pass, so
        // retiring it earlier would drop the tail of the last pattern.
        // Ranked above resolver_rst_rise, which would otherwise re-assert
        // cfg_en_able for a cycle at every reset after the batch.
        cfg_en_able_r <= 1'b0;
      else if (resolver_rst_rise)
        cfg_en_able_r <= 1'b1;
    end
  end

  assign cfg_en_able_o = cfg_en_able_r;

  // --------------------------------------------------------------------------
  // Injection target source select.
  //
  // Table mode (auto): the Table Controller streams one entry per hit,
  // so a whole pattern lands inside a single scan pass.
  //
  // Static mode: a one-entry stream out of CFG_FI_INDEX, the manual
  // single-flip path for bring-up. After the batch cfg_en_able_r is 0 and
  // CFG_FI_INDEX is 0, so arm_ok is 0 and no pass starts.
  // --------------------------------------------------------------------------
  assign entry_index_sel   = cfg_en_able_r ? tbl_index   : cfg_fi_index_i;
  assign entry_valid_sel = cfg_en_able_r ? tbl_valid : static_first;
  assign arm_ok          = cfg_en_able_r ? tbl_ready : (cfg_fi_index_i != 32'd0);

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      static_first <= 1'b1;
    else if (start_usr)
      static_first <= 1'b1;    // two cycles before the scan controller arms
    else if (entry_pop)
      static_first <= 1'b0;    // exactly one flip per pass in static mode
  end

  assign testmode_o   = testmode_sc & !testmode_rst;
  assign resolver_rst_o   = resolver_rst;
  assign clk_gate_o  = clk_gate_int;

  assign start_usr = cfg_start_i | scan_start;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s1 <= 1'b0;
      s2 <= 1'b0;
    end else begin
      s1 <= start_usr;
      s2 <= s1;
    end
  end

  assign scan_ctrl_cfg_start = s2;

  fi_scan_ctrl #(
    .SCRUB_LEN       (SCRUB_LEN)
  ) u_fi_scan_ctrl (
    .clk             (clk),
    .rst_n           (rst_n),
    .cfg_start_i     (scan_ctrl_cfg_start),
    .cfg_scan_len_i       (cfg_scan_len_i),
    .entry_index_i     (entry_index_sel),
    .entry_valid_i   (entry_valid_sel),
    .entry_ready_i   (arm_ok),
    .entry_pop_o     (entry_pop),
    .clk_gate       (clk_gate_int),
    .scan_out_i      (scan_out_i),
    .scan_in_o       (scan_in_o),
    .scan_en_o       (scan_en_o),
    .testmode_o      (testmode_sc),
    .done_o          (scan_done_int),
    .scrub_req_i     (scrub_req),
    .scrub_done_o    (scrub_done),
    .scrub_run_o     (scrub_run),
    .scrub_last_o    (scrub_last),
    .err_order_o     (err_order_o)
  );

  fi_time_ctrl #(
    .RTC_ALIGN_EN (RTC_ALIGN_EN),
    .RST_CYC      (RST_CYC),
    .SCRUB        (SCRUB),
    .MEM_RESTORE  (MEM_RESTORE)
  ) u_fi_time_ctrl (
    .clk             (clk),
    .rst_n           (rst_n),
    .aon_rtcToggle_a (aon_rtcToggle_a),
    .cfg_end_i   (cfg_end_i),
    .cfg_fi_cycle_i    (cfg_fi_cycle_i),
    .cfg_fi_cycle_wr_i (cfg_fi_cycle_wr_i),
    .cfg_to_thr_i    (cfg_to_thr_i),
    .cycle_offset_i       (cycle_offset_w),
    .scan_start_o  (scan_start),
    .resolver_rst_o      (resolver_rst),
    .testmode_rst_o  (testmode_rst),
    .fi_cycle_o      (fi_cycle_o),
    .fi_cycle_ovf_o  (fi_cycle_ovf_o),
    .scrub_req_o     (scrub_req),
    .scrub_done_i    (scrub_done),
    .scrub_run_i     (scrub_run),
    .scrub_last_i    (scrub_last),
    .mem_req_o       (mem_req_o),
    .mem_done_i      (mem_done_i),
    .mem_abort_i     (mem_abort_i),
    .mem_bad_i       (mem_bad_i),
    .mem_halt_o      (mem_halt_o),
    .mem_abort_last_o(mem_abort_last_o),
    .stopped_o       (stopped_o)
  );

  fi_table_ctrl #(
    .TBL_WORDS (TBL_WORDS),
    .N_FF      (N_FF),
    .LOOKAHEAD (LOOKAHEAD)
  ) u_fi_table_ctrl (
    .clk               (clk),
    .rst_n             (rst_n),
    .resolver_rst          (resolver_rst),
    .batch_start_i     (cfg_fi_cycle_wr_i),
    .cfg_tbl_len_i     (cfg_tbl_len_i),
    .done_i            (scan_done_int),
    .tbl_rd_addr_o     (tbl_rd_addr_o),
    .tbl_rdata_i       (tbl_rdata_i),
    .entry_index_o       (tbl_index),
    .entry_valid_o     (tbl_valid),
    .entry_ready_o     (tbl_ready),
    .entry_pop_i       (entry_pop & cfg_en_able_r),
    .cycle_offset_o         (cycle_offset_w),
    .table_exhausted_o (table_exhausted_o),
    .err_malformed_o   (err_malformed_o)
  );

endmodule
