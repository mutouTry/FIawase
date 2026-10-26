// SPDX-License-Identifier: Apache-2.0
// Copyright 2025-2026 the FIawase authors
// ============================================================
// fi_uart_obs -- reads a DUT's UART output in the DUT's own time
// ------------------------------------------------------------
// An 8N1 receiver that advances only on functional edges (run_i = 1, the
// edges the freeze gate lets through). A scan window has none, so the
// receiver sees exactly the sequence of TX levels the DUT produces on its
// functional edges, i.e. the same bytes at the same program cycles as a run
// without the wrapper. The DUT's UART
// needs no change: it is simply frozen with everything else (or even left
// on the chain -- whatever its pin does while the chain shifts is never
// sampled). This replaces the FIFO + CDC a DUT would otherwise need to keep
// a transmission alive across the window.
//
// CLKS_PER_BIT is the bit period in functional cycles, as the DUT's own
// divisor makes it (>= 2); take it from a fault-free run. Receiver and
// transmitter share the clock, so each bit is sampled at a fixed cycle,
// CLKS_PER_BIT/2 into it, with no jitter: short bit periods are exact too.
// A frame whose stop bit is 0 is reported with ferr_o and no byte.
//
// On an FPGA the byte stream goes into a FIFO the host reads; in
// simulation the testbench prints it.
// ============================================================
module fi_uart_obs #(
    parameter integer CLKS_PER_BIT = 16
)(
    input  wire       clk_i,     // free-running functional clock
    input  wire       run_i,     // 1 = a functional edge (fi_wrapper_top run_o)
    input  wire       rst_ni,
    input  wire       rx_i,      // the DUT's TX line, idle high
    output reg  [7:0] data_o,
    output reg        valid_o,   // one cycle per received byte
    output reg        ferr_o     // one cycle per framing error
);

    localparam integer CW = $clog2(CLKS_PER_BIT + 1);
    localparam [1:0] IDLE = 2'd0, START = 2'd1, DATA = 2'd2, STOP = 2'd3;

    reg [1:0]    st;
    reg [CW-1:0] cnt;
    reg [2:0]    bit_i;
    reg [7:0]    sh;
    reg          rx_q;

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            st <= IDLE; cnt <= {CW{1'b0}}; bit_i <= 3'd0; sh <= 8'd0;
            rx_q <= 1'b1; data_o <= 8'd0; valid_o <= 1'b0; ferr_o <= 1'b0;
        end else begin
            valid_o <= 1'b0;
            ferr_o  <= 1'b0;
            if (run_i) begin
                rx_q    <= rx_i;
                case (st)
                    // rx_q lags the line by one cycle, the IDLE test by one more:
                    // counting CLKS_PER_BIT/2 - 1 lands CLKS_PER_BIT/2 into the bit
                    IDLE:  if (!rx_q) begin st <= START; cnt <= CLKS_PER_BIT / 2 - 1; end
                    START: if (cnt == 0) begin
                               // mid start bit: still low, or it was a glitch
                               if (!rx_q) begin st <= DATA; cnt <= CLKS_PER_BIT - 1; bit_i <= 3'd0; end
                               else       st <= IDLE;
                           end else cnt <= cnt - 1'b1;
                    DATA:  if (cnt == 0) begin
                               sh  <= {rx_q, sh[7:1]};
                               cnt <= CLKS_PER_BIT - 1;
                               if (bit_i == 3'd7) st <= STOP;
                               bit_i <= bit_i + 1'b1;
                           end else cnt <= cnt - 1'b1;
                    STOP:  if (cnt == 0) begin
                               st <= IDLE;
                               if (rx_q) begin data_o <= sh; valid_o <= 1'b1; end
                               else      ferr_o <= 1'b1;
                           end else cnt <= cnt - 1'b1;
                endcase
            end
        end
    end

endmodule
