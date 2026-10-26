// SPDX-License-Identifier: Apache-2.0
// Copyright 2025-2026 the FIawase authors
// Genesys2 (xc7k325tffg900-2) top for the example FI system.
// Clock: the 200 MHz LVDS oscillator through an MMCM to the 12.5 MHz functional clock
// (VCO 1000 MHz = 200 x 5; /80). Reset: CPU RESET button and MMCM lock, synchronised.
// Host JTAG: J17's FT2232H on the port wired to PROG_D0..3 (MPSSE TCK, TDI, TDO, TMS).
// UART: to J15's FT232R, 115,741 baud 8N1 (12.5 MHz / 108): the DUT's uart0 output, decoded and
// split by trial (fi_board_uart in fi_dut_core.vh). uart0 itself runs at 12.5 MHz / TINY_UART_CPB, the
// divisor the program sets (fi_dut_core.vh).
// The FI system itself is fi_dut_core.vh, which a simulation testbench can include as well.
`timescale 1ns/1ps
module fpga_top (
    input  wire       sys_clk_p,
    input  wire       sys_clk_n,
    input  wire       cpu_resetn,
    input  wire       jtag_tck,
    input  wire       jtag_tms,
    input  wire       jtag_tdi,
    output wire       jtag_tdo,
    output wire       uart_tx,
    input  wire       uart_rx,
    output wire [7:0] led
);
    // ---- clock
    wire clk200, clkfb, clk_mmcm, locked;
    IBUFDS u_ibufds (.I(sys_clk_p), .IB(sys_clk_n), .O(clk200));
    MMCME2_BASE #(
        .CLKIN1_PERIOD   (5.000),
        .DIVCLK_DIVIDE   (1),
        .CLKFBOUT_MULT_F (5.000),
        .CLKOUT0_DIVIDE_F(80.000)
    ) u_mmcm (
        .CLKIN1(clk200), .CLKFBIN(clkfb), .CLKFBOUT(clkfb), .CLKFBOUTB(),
        .CLKOUT0(clk_mmcm), .CLKOUT0B(), .CLKOUT1(), .CLKOUT1B(), .CLKOUT2(), .CLKOUT2B(),
        .CLKOUT3(), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6(),
        .LOCKED(locked), .PWRDWN(1'b0), .RST(1'b0)
    );
    wire clk_i;
    BUFG u_bufg (.I(clk_mmcm), .O(clk_i));

    // ---- reset: asserted at once, released two edges after the button and the lock
    wire rst_async_n = cpu_resetn & locked;
    (* ASYNC_REG = "TRUE" *) reg [2:0] rst_q = 3'b000;
    always @(posedge clk_i or negedge rst_async_n)
        if (!rst_async_n) rst_q <= 3'b000;
        else              rst_q <= {rst_q[1:0], 1'b1};
    wire rst_ni = rst_q[2];

    // ---- the FI system
    wire        sim_jtag_tck = jtag_tck;
    wire        sim_jtag_tms = jtag_tms;
    wire        sim_jtag_tdi = jtag_tdi;
    wire        sim_jtag_tdo;
    wire        halted;
    wire [15:0] io_pins;
    `include "fi_dut_core.vh"
    assign jtag_tdo = sim_jtag_tdo;

    assign uart_tx = fi_host_tx;          // the DUT's output split by trial (fi_board_uart)

    // ---- LEDs: 0 clock alive (1.5 Hz), 1 MMCM locked, 2 DUT in reset, 3 a scan pass (stretched),
    //            4 host UART activity (stretched), 5 DUT halted
    reg [23:0] beat = 24'd0;
    always @(posedge clk_i) beat <= beat + 1'b1;
    reg [19:0] pass_s = 20'd0, tx_s = 20'd0;
    always @(posedge clk_i) begin
        pass_s <= clk_gate_o   ? {20{1'b1}} : (pass_s != 0 ? pass_s - 1'b1 : 20'd0);
        tx_s   <= !fi_host_tx  ? {20{1'b1}} : (tx_s   != 0 ? tx_s   - 1'b1 : 20'd0);
    end
    assign led = {2'b00, halted, tx_s != 0, pass_s != 0, !fi_rst, locked, beat[23]};
endmodule
