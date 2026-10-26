// SPDX-License-Identifier: Apache-2.0
// Copyright 2025-2026 the FIawase authors
// ============================================================
// FI Executor                             (docs/DESIGN.md 1.1 and 1.2)
// ------------------------------------------------------------
// The FI Table plus the executor core. Consumes staged replay patterns
// and converts them into replay actions on the DUT scan / clock / reset
// interfaces.
// ============================================================
module fi_executor #(
  parameter integer DW          = 32,
  parameter integer TBL_WORDS   = 256,
  // Reset-window pacing; see fi_time_ctrl.
  //   1 = DUT has a slow clock domain, align the reset window to it
  //   0 = single-clock DUT, pace by RST_CYC hf cycles (aon_rtcToggle_a unused)
  parameter integer RTC_ALIGN_EN = 0,
  parameter integer RST_CYC      = 32,
  parameter integer SCRUB        = 1,   // zero the chain in the reset window (fi_time_ctrl)
  parameter integer SCRUB_LEN    = -1,  // shifts of that scrub (fi_scan_ctrl); negative: the whole chain
  parameter integer MEM_RESTORE  = 1,   // restore the DUT memories in the reset window (fi_time_ctrl)
  // FI_Entry encoding bound (only ceil(log2) is used) and lookahead depth.
  parameter integer N_FF         = 8192,
  parameter integer LOOKAHEAD    = 4
)(
  // Control/config from the FI Transporter
  input  wire                   cfg_auto_i,
  input  wire                   cfg_start_i,
  input  wire [31:0]            cfg_scan_len_i,
  input  wire [31:0]            cfg_fi_index_i,
  input  wire                   cfg_end_i,
  input  wire [31:0]            cfg_fi_cycle_i,
  input  wire                   cfg_fi_cycle_wr_i,
  input  wire [31:0]            cfg_to_thr_i,
  input  wire [31:0]            cfg_tbl_len_i,

  // Host-side FI Table access from the FI Transporter
  input  wire                   tbl_host_wr_en_i,
  input  wire                   tbl_host_rd_en_i,
  input  wire [$clog2(TBL_WORDS)-1:0] tbl_host_addr_i,
  input  wire [DW-1:0]          tbl_host_wdata_i,
  input  wire [DW/8-1:0]        tbl_host_wmask_i,
  output wire [DW-1:0]          tbl_host_rdata_o,

  // Status back to the FI Transporter
  output wire                   cfg_en_able_o,
  output wire [31:0]            fi_cycle_o,
  output wire                   table_exhausted_o,
  output wire                   err_order_o,
  output wire                   err_malformed_o,
  output wire                   fi_cycle_ovf_o,

  // DUT-facing scan/test interface
  output wire                   resolver_rst_o,
  output wire                   clk_gate_o,
  input  wire                   scan_out_i,
  output wire                   scan_in_o,
  output wire                   scan_en_o,
  output wire                   testmode_o,

  // DUT memory restore (FI memory models, rtl/fi_sram_restore.vh)
  output wire                   mem_req_o,
  input  wire                   mem_done_i,
  input  wire                   mem_abort_i,
  input  wire                   mem_bad_i,
  output wire                   mem_halt_o,
  output wire                   mem_abort_last_o,
  output wire                   stopped_o,

  // Clocks / reset
  input  wire                   aon_rtcToggle_a,
  input  wire                   clk,
  input  wire                   rst_n
);

  wire [31:0] tbl_rd_addr_w;
  wire [DW-1:0] tbl_rdata_w;

  fi_executor_core #(
    .RTC_ALIGN_EN (RTC_ALIGN_EN),
    .RST_CYC      (RST_CYC),
    .SCRUB        (SCRUB),
    .SCRUB_LEN    (SCRUB_LEN),
    .MEM_RESTORE  (MEM_RESTORE),
    .N_FF         (N_FF),
    .TBL_WORDS    (TBL_WORDS),
    .LOOKAHEAD    (LOOKAHEAD)
  ) u_fi_executor_core (
    .cfg_auto_i      (cfg_auto_i),
    .cfg_start_i     (cfg_start_i),
    .cfg_scan_len_i       (cfg_scan_len_i),
    .cfg_fi_index_i     (cfg_fi_index_i),
    .cfg_end_i       (cfg_end_i),
    .cfg_fi_cycle_i    (cfg_fi_cycle_i),
    .cfg_fi_cycle_wr_i (cfg_fi_cycle_wr_i),
    .cfg_to_thr_i    (cfg_to_thr_i),
    .cfg_tbl_len_i   (cfg_tbl_len_i),

    .cfg_en_able_o   (cfg_en_able_o),
    .tbl_rd_addr_o   (tbl_rd_addr_w),
    .tbl_rdata_i     (tbl_rdata_w),

    .fi_cycle_o        (fi_cycle_o),
    .table_exhausted_o (table_exhausted_o),
    .err_order_o       (err_order_o),
    .err_malformed_o   (err_malformed_o),
    .fi_cycle_ovf_o    (fi_cycle_ovf_o),

    .resolver_rst_o      (resolver_rst_o),
    .clk_gate_o     (clk_gate_o),
    .scan_out_i      (scan_out_i),
    .scan_in_o       (scan_in_o),
    .scan_en_o       (scan_en_o),
    .testmode_o      (testmode_o),

    .mem_req_o       (mem_req_o),
    .mem_done_i      (mem_done_i),
    .mem_abort_i     (mem_abort_i),
    .mem_bad_i       (mem_bad_i),
    .mem_halt_o      (mem_halt_o),
    .mem_abort_last_o(mem_abort_last_o),
    .stopped_o       (stopped_o),

    .aon_rtcToggle_a (aon_rtcToggle_a),
    .clk             (clk),
    .rst_n           (rst_n)
  );

  fi_table #(
    .DW      (DW),
    .TBL_WORDS (TBL_WORDS)
  ) u_fi_table (
    .clk          (clk),
    .rst_n        (rst_n),

    .host_wr_en_i (tbl_host_wr_en_i),
    .host_rd_en_i (tbl_host_rd_en_i),
    .host_addr_i  (tbl_host_addr_i),
    .host_wdata_i (tbl_host_wdata_i),
    .host_wmask_i (tbl_host_wmask_i),
    .host_rdata_o (tbl_host_rdata_o),

    .exec_rd_addr_i(tbl_rd_addr_w),
    .exec_rdata_o (tbl_rdata_w)
  );

endmodule
