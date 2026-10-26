// SPDX-License-Identifier: Apache-2.0
// Copyright 2025-2026 the FIawase authors
// The FPGA form of the example FI system: the FIawase wrapper, the converted DUT netlist
// (tinyriscv_soc_top.fpga.v) and its memories' restore wires (fi_mem_glue_fpga.vh), both written by
// prep.sh. Included by the board top (fpga_top.v); a simulation testbench that includes it too runs
// exactly what the board runs.
// The includer provides: clk_i (functional clock), rst_ni (wrapper reset, active low),
// sim_jtag_tck / sim_jtag_tms / sim_jtag_tdi (host JTAG in), sim_jtag_tdo (out), halted,
// io_pins[15:0]. It gets fi_host_tx: the DUT's UART output split by trial, for the host
// (fpga/rtl/fi_board_uart.v), at clk_i / FI_HOST_DIV per bit. That output is read the way a
// simulation observer reads it: uart0's TX before the pin mux, decoded by the testbench's receiver
// (uart_rx_tap), reset by fi_rst, counted inside the trial's output window.
    wire clk_gate_o;
    wire fi_rst;
    wire dut_jtag_tck, dut_jtag_tms, dut_jtag_tdi, dut_jtag_tdo;
    wire sc_scanin, sc_scanen, sc_testmode, tb_io_scanout;
    wire fi_mem_req, fi_mem_done, fi_mem_abort, fi_mem_bad;
    wire fi_trial_run, fi_obs_uart_tx;
    fi_wrapper_top #(
        .DMI_ADDR_BITS (7),
        .DMI_DATA_BITS (32),
        .DMI_OP_BITS   (2),
        .DW            (32),
        .TBL_WORDS     (256),
        .IDCODE_VALUE  (32'hF17E_0007),
        .N_FF          (8192)
        ) u_fi_wrapper_top (
        .aon_hfclk_i   (clk_i),
        .aon_lfclk_i   (1'b0),
        .aon_rst_ni    (rst_ni),
        .jtag_tck_i    (sim_jtag_tck),
        .jtag_tms_i    (sim_jtag_tms),
        .jtag_tdi_i    (sim_jtag_tdi),
        .jtag_trst_ni  (rst_ni),
        .jtag_tdo_o    (sim_jtag_tdo),
        .dut_jtag_tck_o(dut_jtag_tck),
        .dut_jtag_tms_o(dut_jtag_tms),
        .dut_jtag_tdi_o(dut_jtag_tdi),
        .dut_jtag_tdo_i(dut_jtag_tdo),
        .scan_out_i    (tb_io_scanout),
        .scan_in_o     (sc_scanin),
        .scan_en_o     (sc_scanen),
        .testmode_o    (sc_testmode),
        .clk_gate_o    (clk_gate_o),
        .fi_rst        (fi_rst),
        .trial_run_o   (fi_trial_run),
        .fi_mem_req_o  (fi_mem_req),
        .fi_mem_done_i (fi_mem_done),
        .fi_mem_abort_i(fi_mem_abort),
        .fi_mem_bad_i  (fi_mem_bad)
    );
    `include "fi_mem_glue_fpga.vh"
    tinyriscv_soc_top u_tinyriscv_soc_top (
        .clk_50m_i      (clk_i),
        .rst_ext_ni     (fi_rst),
        .halted_ind_pin (halted),
        .jtag_TCK_pin   (dut_jtag_tck),
        .jtag_TMS_pin   (dut_jtag_tms),
        .jtag_TDI_pin   (dut_jtag_tdi),
        .jtag_TDO_pin   (dut_jtag_tdo),
        .io_data_out    (io_pins),
        .io_data_in     (16'hFFFF),
        .flash_spi_dq_in(4'hF),
        .data_source    (1'b0),
        .io_testmode    (sc_testmode),
        .io_scanin      (sc_scanin),
        .io_scanen      (sc_scanen),
        .io_scanout     (tb_io_scanout),
        .scan_gate      (clk_gate_o),
        .fi_obs_uart_tx_o(fi_obs_uart_tx),
        `FI_MEM_PORTS
    );

    // ---- the DUT's UART for the host
    // uart0's TX before the pin mux, decoded by uart_rx_tap reset by fi_rst, one byte where
    // uart_done_d1 & ~uart_done_d2. Bit period TINY_UART_CPB cycles, the divisor the program sets:
    // 434 for firmware/application_intmix (50 MHz / 115200).
    // uart_rx_tap's UART_BPS is fixed at 115200, so the period is set through CLK_FREQ.
    // uart0 keeps running through the pass (FI_EXEMPT), so it is read on every clk_i edge.
`ifndef TINY_UART_CPB
`define TINY_UART_CPB 434
`endif
`ifndef FI_HOST_DIV
`define FI_HOST_DIV 108                // 12.5 MHz / 108 = 115,741 baud
`endif
    wire       fi_obs_done;
    wire [7:0] fi_obs_data;
    reg        fi_obs_done_d1, fi_obs_done_d2;
    uart_rx_tap #(.CLK_FREQ(115200 * `TINY_UART_CPB)) u_fi_obs_rx (
        .sys_clk(clk_i), .sys_rst_n(fi_rst), .uart_rxd(fi_obs_uart_tx),
        .uart_done(fi_obs_done), .uart_data(fi_obs_data));
    always @(posedge clk_i or negedge fi_rst)       // as uart_rx_tap's own uart_done_d1 / _d2
        if (!fi_rst) begin fi_obs_done_d1 <= 1'b0; fi_obs_done_d2 <= 1'b0; end
        else         begin fi_obs_done_d1 <= fi_obs_done; fi_obs_done_d2 <= fi_obs_done_d1; end
    wire fi_host_tx;
    fi_board_uart #(.OUT_DIV(`FI_HOST_DIV), .FIFO_AW(10)) u_fi_board_uart (
        .clk_i(clk_i), .rst_ni(rst_ni), .dut_rst_ni(fi_rst), .trial_run_i(fi_trial_run),
        .byte_v_i(fi_obs_done_d1 & ~fi_obs_done_d2), .byte_i(fi_obs_data),
        .abort_i(fi_mem_abort), .tx_o(fi_host_tx));
