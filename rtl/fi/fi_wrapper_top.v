// SPDX-License-Identifier: Apache-2.0
// Copyright 2025-2026 the FIawase authors

`include "fi_scan_cfg.vh"

// ============================================================
// FI wrapper                                      (paper Fig. 4)
// ------------------------------------------------------------
// The wrapper that makes a user DUT FI-enabled. It is placed AROUND
// the DUT, never inside it, so replay control stays reachable while the
// DUT is paused, corrupted, or being reset for recovery.
//
// Two wrapper-side modules, exactly as in Fig. 4:
//   fi_transporter   FI Transporter -- AON JTAG, host control, FI regs
//   fi_executor      FI Executor    -- FI Table + the three controllers
//
// DUT-facing contract (Fig. 4, right-hand side):
//   scan_out_i / scan_in_o / scan_en_o   the DUT scan chain
//   clk_gate_o                           Clk_Gate, freezes the unscanned
//                                        part of the DUT
//   fi_rst                               "Reset for next FI", active low
// ============================================================
module fi_wrapper_top #(
  parameter integer DMI_ADDR_BITS = 7,
  parameter integer DMI_DATA_BITS = 32,
  parameter integer DMI_OP_BITS   = 2,
  parameter integer DW            = 32,
  parameter integer TBL_WORDS     = 256,
  parameter [31:0]  IDCODE_VALUE  = 32'hF17E_0006,

  // ==========================================================
  // FI_Entry encoding bound. Only ceil(log2(N_FF)) is used: it fixes
  // W_IDX and therefore where Cycle_Offset and fi_index sit in the word.
  // Deliberately a power of two so the table format does not move when
  // the real chain length drifts across re-synthesis. The runtime chain
  // length is CFG_SCAN_LEN (DMI 0x63), NOT this.
  // Contract: L <= N_FF - 1. Default comes from fi_scan_cfg.vh, which
  // the scan insertion flow generates (syn/ writes results/fi_scan_cfg.vh;
  // copy it over after every synthesis run).
  // ==========================================================
  parameter integer N_FF          = `FI_N_FF,
  parameter integer LOOKAHEAD     = 4,

  // ==========================================================
  // Does this DUT have an independent slow (RTC / lf) clock domain?
  // ----------------------------------------------------------
  //   1 : yes. The auto-FI reset window is aligned to rising edges of
  //       aon_lfclk_i so that the phase at which the DUT leaves reset
  //       is identical every iteration.
  //   0 : no (single-clock DUT). aon_lfclk_i takes no part in the reset
  //       logic at all and may be tied off; the reset window is paced by
  //       RST_CYC cycles of aon_hfclk_i instead, which is deterministic
  //       by construction.
  // RST_CYC is the reset pulse width in hf cycles, used when
  // RTC_ALIGN_EN = 0.
  // ==========================================================
  parameter integer RTC_ALIGN_EN  = 0,
  parameter integer RST_CYC       = 32
)(
  // ==========================================================
  // Host / wrapper clocks and reset
  // ==========================================================
  input  wire                         aon_hfclk_i,
  input  wire                         aon_lfclk_i,
  input  wire                         aon_rst_ni,

  // ==========================================================
  // Host JTAG
  // ==========================================================
  input  wire                         jtag_tck_i,
  input  wire                         jtag_tms_i,
  input  wire                         jtag_tdi_i,
  input  wire                         jtag_trst_ni,
  output wire                         jtag_tdo_o,

  // ==========================================================
  // DUT JTAG
  // ==========================================================
  output wire                         dut_jtag_tck_o,
  output wire                         dut_jtag_tms_o,
  output wire                         dut_jtag_tdi_o,
  input  wire                         dut_jtag_tdo_i,

  // ==========================================================
  // DUT-facing scan / clock / reset interface
  // ==========================================================
  input  wire                         scan_out_i,   // Scan_Out
  output wire                         scan_in_o,    // Scan_In
  output wire                         scan_en_o,    // Scan_En
  output wire                         testmode_o,

  output wire                         clk_gate_o,   // Clk_Gate
  output wire                         fi_rst        // Reset for next FI, active low

  // Future DUT controlled clock/reset ports can be added here.
);

  // ==========================================================
  // FI Transporter -> FI Executor control/config
  // ==========================================================
  wire                         fi_mode_w;
  wire                         cfg_auto_w;
  wire                         cfg_start_w;
  wire [31:0]                  cfg_scan_len_w;
  wire [31:0]                  cfg_fi_index_w;
  wire                         cfg_end_w;
  wire [31:0]                  cfg_fi_cycle_w;
  wire                         cfg_fi_cycle_wr_w;
  wire [31:0]                  cfg_to_thr_w;
  wire [31:0]                  cfg_tbl_len_w;

  // ==========================================================
  // FI Transporter -> FI Executor, FI Table host port
  // ==========================================================
  wire                         tbl_host_wr_en_w;
  wire                         tbl_host_rd_en_w;
  wire [$clog2(TBL_WORDS)-1:0] tbl_host_addr_w;
  wire [DW-1:0]                tbl_host_wdata_w;
  wire [DW/8-1:0]              tbl_host_wmask_w;
  wire [DW-1:0]                tbl_host_rdata_w;

  // ==========================================================
  // FI Executor -> FI Transporter status
  // ==========================================================
  wire                         cfg_en_able_w;
  wire [31:0]                  fi_cycle_w;
  wire                         table_exhausted_w;
  wire                         err_order_w;
  wire                         err_malformed_w;
  wire                         fi_cycle_ovf_w;

  // Internal executor control outputs not exported directly
  // wire                         clk_gate_w;
  wire                         resolver_rst_w;

  // Current fi_executor does not provide explicit busy/error.
  wire                         fi_busy_w;
  wire                         fi_error_w;

  assign fi_busy_w  = 1'b0;
  assign fi_error_w = 1'b0;

  // ==========================================================
  // FI Transporter
  // ==========================================================
  fi_transporter #(
    .DMI_ADDR_BITS (DMI_ADDR_BITS),
    .DMI_DATA_BITS (DMI_DATA_BITS),
    .DMI_OP_BITS   (DMI_OP_BITS),
    .DW            (DW),
    .TBL_WORDS     (TBL_WORDS),
    .IDCODE_VALUE  (IDCODE_VALUE)
  ) u_fi_transporter (
    .aon_clk_i         (aon_hfclk_i),
    .aon_rst_ni        (aon_rst_ni),

    .jtag_tck_i        (jtag_tck_i),
    .jtag_tms_i        (jtag_tms_i),
    .jtag_tdi_i        (jtag_tdi_i),
    .jtag_trst_ni      (jtag_trst_ni),
    .jtag_tdo_o        (jtag_tdo_o),

    .dut_jtag_tck_o    (dut_jtag_tck_o),
    .dut_jtag_tms_o    (dut_jtag_tms_o),
    .dut_jtag_tdi_o    (dut_jtag_tdi_o),
    .dut_jtag_tdo_i    (dut_jtag_tdo_i),

    .fi_mode_o         (fi_mode_w),
    .cfg_auto_o        (cfg_auto_w),
    .cfg_start_o       (cfg_start_w),
    .cfg_scan_len_o         (cfg_scan_len_w),
    .cfg_fi_index_o       (cfg_fi_index_w),
    .cfg_end_o         (cfg_end_w),
    .cfg_fi_cycle_o      (cfg_fi_cycle_w),
    .cfg_fi_cycle_wr_o   (cfg_fi_cycle_wr_w),
    .cfg_to_thr_o      (cfg_to_thr_w),
    .cfg_tbl_len_o     (cfg_tbl_len_w),

    .tbl_host_wr_en_o  (tbl_host_wr_en_w),
    .tbl_host_rd_en_o  (tbl_host_rd_en_w),
    .tbl_host_addr_o   (tbl_host_addr_w),
    .tbl_host_wdata_o  (tbl_host_wdata_w),
    .tbl_host_wmask_o  (tbl_host_wmask_w),
    .tbl_host_rdata_i  (tbl_host_rdata_w),

    .cfg_en_able_i     (cfg_en_able_w),
    .fi_cycle_i        (fi_cycle_w),
    .table_exhausted_i (table_exhausted_w),
    .err_order_i       (err_order_w),
    .err_malformed_i   (err_malformed_w),
    .fi_cycle_ovf_i    (fi_cycle_ovf_w)
  );

  // ==========================================================
  // FI Executor
  // ==========================================================
  fi_executor #(
    .DW           (DW),
    .TBL_WORDS    (TBL_WORDS),
    .RTC_ALIGN_EN (RTC_ALIGN_EN),
    .RST_CYC      (RST_CYC),
    .N_FF         (N_FF),
    .LOOKAHEAD    (LOOKAHEAD)
  ) u_fi_executor (
    .cfg_auto_i        (cfg_auto_w),
    .cfg_start_i       (cfg_start_w),
    .cfg_scan_len_i         (cfg_scan_len_w),
    .cfg_fi_index_i       (cfg_fi_index_w),
    .cfg_end_i         (cfg_end_w),
    .cfg_fi_cycle_i      (cfg_fi_cycle_w),
    .cfg_fi_cycle_wr_i   (cfg_fi_cycle_wr_w),
    .cfg_to_thr_i      (cfg_to_thr_w),
    .cfg_tbl_len_i     (cfg_tbl_len_w),

    .tbl_host_wr_en_i  (tbl_host_wr_en_w),
    .tbl_host_rd_en_i  (tbl_host_rd_en_w),
    .tbl_host_addr_i   (tbl_host_addr_w),
    .tbl_host_wdata_i  (tbl_host_wdata_w),
    .tbl_host_wmask_i  (tbl_host_wmask_w),
    .tbl_host_rdata_o  (tbl_host_rdata_w),

    .cfg_en_able_o     (cfg_en_able_w),
    .fi_cycle_o        (fi_cycle_w),
    .table_exhausted_o (table_exhausted_w),
    .err_order_o       (err_order_w),
    .err_malformed_o   (err_malformed_w),
    .fi_cycle_ovf_o    (fi_cycle_ovf_w),

    .resolver_rst_o        (resolver_rst_w),
    .clk_gate_o       (clk_gate_o),
    .scan_out_i        (scan_out_i),
    .scan_in_o         (scan_in_o),
    .scan_en_o         (scan_en_o),
    .testmode_o        (testmode_o),

    .aon_rtcToggle_a   (aon_lfclk_i),
    .clk               (aon_hfclk_i),
    .rst_n             (aon_rst_ni)
  );

  // ==========================================================
  // Clk_Gate
  // ----------------------------------------------------------
  // clk_gate_o leaves the wrapper as a plain level. The actual clock
  // gates live inside the DUT netlist and are inserted by the synthesis
  // flow (syn/fi_scan_lib.tcl splices syn/fi_clk_gate.v onto every pin
  // in FI_GATE_PINS). Nothing here has to know which DUT clocks exist.
  // ==========================================================

  // ==========================================================
  // "Reset for next FI" (Fig. 4). Active low.
  // ==========================================================
  assign fi_rst = (aon_rst_ni) & ~resolver_rst_w;

endmodule
