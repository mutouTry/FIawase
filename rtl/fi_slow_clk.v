// SPDX-License-Identifier: Apache-2.0
// Copyright 2025-2026 the FIawase authors
// ============================================================
// fi_slow_clk -- a DUT slow clock derived from the FI clock
// ------------------------------------------------------------
// Drives a DUT clock input that on silicon comes from a separate slow
// oscillator (an RTC or always-on clock). In an FI build it is a fixed
// divider of the functional clock instead, and that is what keeps the slow
// domain consistent with the rest of the DUT:
//
//   * it counts only functional edges (run_i = 1, the same edges the
//     freeze gate lets through to the off-chain blocks), so it loses
//     exactly the L window edges with them: the slow domain does not
//     advance while the chain is scrambled, and resumes in the phase it
//     would have had. A clock enable rather than a gated clock: the same on
//     an FPGA;
//   * rst_ni is the DUT reset (fi_rst), so every trial -- and the
//     fault-free reference -- starts the slow clock at the same phase.
//
// A slow clock that kept running through the window would move the slow
// domain by about L / DIV edges per injection relative to the program;
// software that reads a timer clocked by it would then behave differently
// with the wrapper than without.
//
// DIV is the slow period in functional cycles, even and >= 2. The output
// toggles on a rising edge of clk_i, so its edges never fall inside a
// functional clock's low phase.
// ============================================================
module fi_slow_clk #(
    parameter integer DIV = 16
)(
    input  wire clk_i,     // free-running functional clock
    input  wire run_i,     // 1 = a functional edge (fi_wrapper_top run_o)
    input  wire rst_ni,    // the DUT reset, active low
    output reg  slow_o
);

    localparam integer HALF = DIV / 2;
    localparam integer CW   = (HALF > 1) ? $clog2(HALF) : 1;

    reg [CW-1:0] cnt;
    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            cnt    <= {CW{1'b0}};
            slow_o <= 1'b0;
        end else if (run_i) begin
            if (cnt == HALF - 1) begin
                cnt    <= {CW{1'b0}};
                slow_o <= ~slow_o;
            end else begin
                cnt    <= cnt + 1'b1;
            end
        end
    end

endmodule
