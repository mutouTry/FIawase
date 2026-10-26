// SPDX-License-Identifier: Apache-2.0
// Copyright 2025-2026 the FIawase authors
// ============================================================
// fi_tb_template.sv -- a starting testbench for your DUT
// ------------------------------------------------------------
// The wrapper, your scan-inserted netlist and the host JTAG bridge, wired
// together. Copy it, rename the module, and fill in the lines marked EDIT.
// The DUT's port names are the ones your fi_scan_cfg.tcl gives:
// FI_CLK_PORT, FI_RST_PORT, FI_GATE_PORT, FI_SCAN_*_PORT, FI_TESTMODE_PORT.
// examples/tinyriscv/tb/chaos_soc_tb.sv is a complete testbench.
// ============================================================
module fi_tb;

  localparam integer CLK_HALF_NS = 10;          // EDIT: half the period of FI_CLK_PORT
  localparam integer UART_CPB    = 434;         // EDIT: UART bit period, in clock cycles
  localparam integer DRAIN_NS    = 2_000_000;   // EDIT: output time after the last trial

  reg clk   = 1'b0;
  reg rst_n = 1'b0;
  always #(CLK_HALF_NS) clk = ~clk;
  initial #(20 * CLK_HALF_NS) rst_n = 1'b1;

  // ---- host JTAG: OpenOCD connects here (remote_bitbang, port 44853) ----
  wire tck, tms, tdi, tdo, trst_n, srst_n;
  jtagdpi u_jtagdpi (
    .clk_i       (clk),
    .rst_ni      (rst_n),
    .jtag_tck    (tck),
    .jtag_tms    (tms),
    .jtag_tdi    (tdi),
    .jtag_tdo    (tdo),
    .jtag_trst_n (trst_n),
    .jtag_srst_n (srst_n)
  );

  // ---- the wrapper ----
  wire dut_tck, dut_tms, dut_tdi, dut_tdo;
  wire scan_in, scan_en, scan_out, testmode, clk_gate, fi_rst, run, trial_run;

  fi_wrapper_top u_fi (
    .aon_hfclk_i    (clk),
    .aon_lfclk_i    (1'b0),
    .aon_rst_ni     (rst_n),
    .jtag_tck_i     (tck),
    .jtag_tms_i     (tms),
    .jtag_tdi_i     (tdi),
    .jtag_trst_ni   (rst_n),
    .jtag_tdo_o     (tdo),
    .dut_jtag_tck_o (dut_tck),
    .dut_jtag_tms_o (dut_tms),
    .dut_jtag_tdi_o (dut_tdi),
    .dut_jtag_tdo_i (dut_tdo),
    .scan_out_i     (scan_out),
    .scan_in_o      (scan_in),
    .scan_en_o      (scan_en),
    .testmode_o     (testmode),
    .clk_gate_o     (clk_gate),
    .fi_rst         (fi_rst),
    .run_o          (run),
    .trial_run_o    (trial_run),
    .slow_clk_o     (),
    // memory restore: tied off until the DUT's memory models use rtl/fi_sram_restore.vh
    .fi_mem_req_o   (),
    .fi_mem_done_i  (1'b1),
    .fi_mem_abort_i (1'b0),
    .fi_mem_bad_i   (1'b0)
  );

  // ---- your DUT, the scan-inserted netlist ----
  wire uart_tx;

  your_dut_top u_dut (            // EDIT: the module and its port names
    .clk_i     (clk),             // FI_CLK_PORT
    .rst_ni    (fi_rst),          // FI_RST_PORT: the wrapper resets the DUT between trials
    .scan_gate (clk_gate),        // FI_GATE_PORT
    .scan_in   (scan_in),         // FI_SCAN_IN_PORT
    .scan_en   (scan_en),         // FI_SCAN_EN_PORT
    .scan_out  (scan_out),        // FI_SCAN_OUT_PORT
    .testmode  (testmode),        // FI_TESTMODE_PORT
    .jtag_tck  (dut_tck),         // the DUT's debug TAP, reached through the wrapper's
    .jtag_tms  (dut_tms),
    .jtag_tdi  (dut_tdi),
    .jtag_tdo  (dut_tdo),
    .uart_tx   (uart_tx)          // what the workload prints
    // tie every other input to its idle level: an open input reads X
  );

  // EDIT: load the workload into the DUT's program memory here; the example
  // writes its ROM through a hierarchical reference.

  // ---- the DUT's output, read in the DUT's own time ----
  wire [7:0] rx_byte;
  wire       rx_valid;
  fi_uart_obs #(.CLKS_PER_BIT (UART_CPB)) u_obs (
    .clk_i   (clk),
    .run_i   (run),
    .rst_ni  (fi_rst),
    .rx_i    (uart_tx),
    .data_o  (rx_byte),
    .valid_o (rx_valid),
    .ferr_o  ()
  );

  // One marker per trial, so an output that never came is still counted.
  integer uart_fd;
  integer trial_n = 0;
  reg     trial_q = 1'b0;
  initial uart_fd = $fopen("uart.log", "w");
  always @(posedge clk) begin
    trial_q <= trial_run;
    if (trial_run && !trial_q) begin
      trial_n <= trial_n + 1;
      $fwrite(uart_fd, "\n[FI-TRIAL %0d]\n", trial_n + 1);
    end
    if (rx_valid) $fwrite(uart_fd, "%c", rx_byte);
  end

  // ---- end: a campaign was armed and its table is exhausted ----
  initial begin
    wait (u_fi.cfg_en_able_w === 1'b1);
    wait (u_fi.cfg_en_able_w === 1'b0);
    #(DRAIN_NS);
    $fclose(uart_fd);
    $finish;
  end

`ifdef SDF_SIM
  initial $sdf_annotate(`FI_SDF_FILE, `FI_SDF_INSTANCE, , "annotate.log",
                        `FI_SDF_CORNER, "1.0:1.0:1.0", `FI_SDF_SCALE);
`endif

  integer dumpwave;
  initial if ($value$plusargs("DUMPWAVE=%d", dumpwave) && dumpwave != 0) begin
`ifdef FI_FSDB
    $fsdbDumpfile("fi_tb.fsdb");
    $fsdbDumpvars(0, fi_tb, "+mda");
`else
    $dumpfile("fi_tb.vcd");
    $dumpvars(0, fi_tb);
`endif
  end

endmodule
