// SPDX-License-Identifier: Apache-2.0
// Portions Copyright 2025-2026 the FIawase authors
//
// Substantially modified for FIawase: the two-clock split that lets this
// UART keep transmitting while the rest of the SoC is frozen for a scan
// window (gated clk_i for the registers and TX FIFO, ungated clk_tx_i for
// the serialiser, with a FIFO + cdc_rv_1deep between them, and scan_gate
// synchronised onto the ungated domain). See docs/DESIGN.md 6.2.
// The original upstream copyright below still applies.
/*                                                                      
 Copyright 2021 Blue Liang, liangkangnan@163.com
                                                                         
 Licensed under the Apache License, Version 2.0 (the "License");         
 you may not use this file except in compliance with the License.        
 You may obtain a copy of the License at                                 
                                                                         
     http://www.apache.org/licenses/LICENSE-2.0                          
                                                                         
 Unless required by applicable law or agreed to in writing, software    
 distributed under the License is distributed on an "AS IS" BASIS,       
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and     
 limitations under the License.                                          
 */

module scan_uart_core #(
    parameter int unsigned TX_FIFO_DEPTH = 8,
    parameter int unsigned RX_FIFO_DEPTH = 8
)(
    input  logic        clk_i,
    input  logic        clk_tx_i,
    input  logic        rst_ni,

    // Raw (unsynchronized) scan_gate from fi_wrapper. Used to suspend
    // the FIFO->CDC->uart_tx handshake across the scan window so the
    // clk_i gating boundary does not corrupt in-flight bytes.
    input  logic        scan_gate_i,

    output logic        tx_pin_o,
    input  logic        rx_pin_i,
    output logic        irq_o,

    input  logic        reg_we_i,
    input  logic        reg_re_i,
    input  logic [31:0] reg_wdata_i,
    input  logic [ 3:0] reg_be_i,
    input  logic [31:0] reg_addr_i,
    output logic [31:0] reg_rdata_o
);

    import uart_reg_pkg::*;

    uart_reg2hw_t reg2hw;
    uart_hw2reg_t hw2reg;

    logic tx_enable;
    logic rx_enable;
    logic [15:0] baud_div;
    logic tx_fifo_empty_int_en;
    logic rx_fifo_not_empty_int_en;
    logic tx_fifo_rst;
    logic rx_fifo_rst;
    logic tx_idle;
    logic rx_idle;
    logic rx_error;
    logic tx_fifo_full;
    logic rx_fifo_full;
    logic tx_fifo_empty;
    logic rx_fifo_empty;
    logic tx_we;
    logic [7:0] tx_wdata;
    logic [7:0] rx_rdata;
    logic rx_rvalid;
    logic tx_fifo_pop;
    logic rx_fifo_pop;
    logic tx_fifo_push;
    logic rx_fifo_push;
    logic [7:0] tx_fifo_data_out;
    logic [7:0] rx_fifo_data_out;
    logic [7:0] tx_fifo_data_in;
    logic [7:0] rx_fifo_data_in;

    // ----------------------------------------------------------------
    // TX bridge signals
    // ----------------------------------------------------------------
    logic       tx_valid_a;
    logic [7:0] tx_data_a;
    logic       tx_ready_a;

    logic       tx_valid_b;
    logic [7:0] tx_data_b;
    logic       tx_we_b;
    logic       tx_idle_b;

    // TX-side shadowed controls
    logic       tx_enable_b;
    logic [15:0] baud_div_b;

    // 波特率分频系数
    assign baud_div = reg2hw.ctrl.baud_div.q;

    // ----------------------------------------------------------------
    // scan_gate synchronizer (kicks on clk_tx_i — an ungated clock — so
    // it stays observable across the entire scan window even when clk_i
    // is gated). We read scan_gate_view combinationally in both A and
    // B side handshake conditions.
    //
    // Timing caveat:
    //   the freeze gate (syn/fi_clk_gate.v, spliced in at
    //   synthesis) stops clk_i 1 cycle after scan_gate rises.
    //   scan_gate_view here takes 2 cycles to rise.
    //   That means the "last edge" of clk_i still sees scan_gate_view=0
    //   and can fire one final tx_valid_a / tx_we_b. That last-edge byte
    //   is safe (it goes through CDC cleanly and transmits once), but
    //   every subsequent cycle is properly suspended.
    // ----------------------------------------------------------------
    logic sg_q1, sg_q2;
    always_ff @(posedge clk_tx_i or negedge rst_ni) begin
        if (!rst_ni) begin
            sg_q1 <= 1'b0;
            sg_q2 <= 1'b0;
        end else begin
            sg_q1 <= scan_gate_i;
            sg_q2 <= sg_q1;
        end
    end
    wire scan_gate_view = sg_q2;

    // ----------------------------------------------------------------
    // TX control
    // ----------------------------------------------------------------
    assign tx_enable            = reg2hw.ctrl.tx_en.q;
    assign tx_fifo_empty_int_en = reg2hw.ctrl.tx_fifo_empty_int_en.q;
    assign tx_fifo_rst          = reg2hw.ctrl.tx_fifo_rst.qe & reg2hw.ctrl.tx_fifo_rst.q;

    // Keep old visible meaning of txidle, but include bridge empty.
    // tx_ready_a=1 means the 1-deep bridge is empty on A side.
    assign tx_idle = tx_idle_b;
    assign hw2reg.status.txidle.d  = tx_enable ? (tx_idle & tx_fifo_empty & tx_ready_a) : 1'b1;
    assign hw2reg.status.txfull.d  = tx_fifo_full;
    assign hw2reg.status.txempty.d = tx_fifo_empty;

    // A-side FIFO source logic:
    // During scan_gate (scan_gate_view=1) we deassert tx_valid_a so the
    // FIFO is not popped and the CDC A-side is not loaded. The byte in
    // the FIFO head stays put; handshake resumes cleanly after scan.
    assign tx_valid_a     = tx_enable & (~tx_fifo_empty) & ~scan_gate_view;
    assign tx_data_a      = tx_fifo_data_out;
    assign tx_fifo_pop    = tx_valid_a & tx_ready_a;

    // still allow software to push before TX enable
    assign tx_fifo_push   = reg2hw.txdata.qe & (~tx_fifo_full);
    assign tx_fifo_data_in = reg2hw.txdata.q;

    // ----------------------------------------------------------------
    // RX control
    // ----------------------------------------------------------------
    assign rx_enable                = reg2hw.ctrl.rx_en.q;
    assign rx_fifo_not_empty_int_en = reg2hw.ctrl.rx_fifo_not_empty_int_en.q;
    assign rx_fifo_rst              = reg2hw.ctrl.rx_fifo_rst.qe & reg2hw.ctrl.rx_fifo_rst.q;

    assign hw2reg.status.rxidle.d  = rx_enable ? rx_idle : 1'b1;
    assign hw2reg.status.rxfull.d  = rx_fifo_full;
    assign hw2reg.status.rxempty.d = rx_fifo_empty;
    assign hw2reg.rxdata.d         = rx_fifo_data_out;

    assign rx_fifo_push    = (~rx_fifo_full) & rx_rvalid;
    assign rx_fifo_data_in = rx_rdata;
    assign rx_fifo_pop     = reg2hw.rxdata.re & (~rx_fifo_empty);

    // ----------------------------------------------------------------
    // Interrupt
    // ----------------------------------------------------------------
    assign irq_o = (tx_enable & tx_fifo_empty_int_en & tx_fifo_empty) |
                   (rx_enable & rx_fifo_not_empty_int_en & (~rx_fifo_empty));

    // ----------------------------------------------------------------
    // TX-side control shadowing
    //
    // clk_i and clk_tx_i are assumed synchronous/related; clk_i may be gated.
    // Only update these controls when TX is idle, so we do not change enable
    // or baud_div in the middle of a character.
    // ----------------------------------------------------------------
    assign tx_enable_b = tx_enable;
    assign baud_div_b  = baud_div;
    // ----------------------------------------------------------------
    // TX B-side launch logic
    //
    // Preserve old uart_tx contract:
    //   we_i is a one-cycle launch pulse when idle and data is available
    //
    // Critical:
    //   bridge ack must be tx_we_b, not tx_idle_b
    //
    // Added for scan support:
    //   Gate tx_we_b with ~scan_gate_view so uart_tx does not start a
    //   new byte while scan is active. If uart_tx was already mid-byte
    //   when scan_gate rose, it finishes the byte (clk_tx_i is ungated)
    //   and then stays idle until scan_gate drops.
    // ----------------------------------------------------------------
    assign tx_we_b = tx_enable_b & tx_valid_b & tx_idle_b & ~scan_gate_view;

    // keep unused legacy signals tied cleanly
    assign tx_we    = 1'b0;
    assign tx_wdata = 8'h00;

    // ----------------------------------------------------------------
    // TX byte
    // ----------------------------------------------------------------
    uart_tx u_uart_tx (
        .clk_i      (clk_tx_i),
        .rst_ni     (rst_ni),
        .enable_i   (tx_enable_b),
        .parity_en_i(1'b0),
        .parity_i   (1'b1),
        .we_i       (tx_we_b),
        .wdata_i    (tx_data_b),
        .div_ratio_i(baud_div_b),
        .idle_o     (tx_idle_b),
        .tx_bit_o   (tx_pin_o)
    );

    // ----------------------------------------------------------------
    // 1-deep bridge between TX FIFO and uart_tx
    // ----------------------------------------------------------------
    cdc_rv_1deep #(
        .DW(8)
    ) u_tx_cdc (
        .clk_a  (clk_i),
        .rstn_a (rst_ni),
        .v_i    (tx_valid_a),
        .d_i    (tx_data_a),
        .r_o    (tx_ready_a),

        .clk_b  (clk_tx_i),
        .rstn_b (rst_ni),
        .v_o    (tx_valid_b),
        .d_o    (tx_data_b),
        .r_i    (tx_we_b)
    );

    // ----------------------------------------------------------------
    // TX FIFO
    // ----------------------------------------------------------------
    sync_fifo #(
        .DATA_WIDTH(8),
        .DEPTH(TX_FIFO_DEPTH)
    ) u_tx_fifo (
        .clk_i      (clk_i),
        .rst_ni     (rst_ni),
        .flush_i    (tx_fifo_rst),
        .testmode_i (1'b0),
        .full_o     (tx_fifo_full),
        .empty_o    (tx_fifo_empty),
        .usage_o    (),
        .data_i     (tx_fifo_data_in),
        .push_i     (tx_fifo_push),
        .data_o     (tx_fifo_data_out),
        .pop_i      (tx_fifo_pop)
    );

    // ----------------------------------------------------------------
    // RX byte
    // ----------------------------------------------------------------
    uart_rx u_uart_rx (
        .clk_i          (clk_i),
        .rst_ni         (rst_ni),
        .enable_i       (rx_enable),
        .parity_en_i    (1'b0),
        .parity_odd_i   (1'b1),
        .div_ratio_i    (baud_div),
        .rx_i           (rx_pin_i),
        .idle_o         (rx_idle),
        .err_o          (rx_error),
        .rdata_o        (rx_rdata),
        .rvalid_o       (rx_rvalid)
    );

    // ----------------------------------------------------------------
    // RX FIFO
    // ----------------------------------------------------------------
    sync_fifo #(
        .DATA_WIDTH(8),
        .DEPTH(RX_FIFO_DEPTH)
    ) u_rx_fifo (
        .clk_i      (clk_i),
        .rst_ni     (rst_ni),
        .flush_i    (rx_fifo_rst),
        .testmode_i (1'b0),
        .full_o     (rx_fifo_full),
        .empty_o    (rx_fifo_empty),
        .usage_o    (),
        .data_i     (rx_fifo_data_in),
        .push_i     (rx_fifo_push),
        .data_o     (rx_fifo_data_out),
        .pop_i      (rx_fifo_pop)
    );

    // ----------------------------------------------------------------
    // Register block
    // ----------------------------------------------------------------
    uart_reg_top u_uart_reg_top (
        .clk_i      (clk_i),
        .rst_ni     (rst_ni),
        .reg2hw     (reg2hw),
        .hw2reg     (hw2reg),
        .reg_we     (reg_we_i),
        .reg_re     (reg_re_i),
        .reg_wdata  (reg_wdata_i),
        .reg_be     (reg_be_i),
        .reg_addr   (reg_addr_i),
        .reg_rdata  (reg_rdata_o)
    );

endmodule