// SPDX-License-Identifier: Apache-2.0
// Copyright 2025-2026 the FIawase authors
module scan_en_sync (
    input  wire clk,       // Clock input for synchronization
    input  wire rst_n,      // Active-low asynchronous reset

    input  wire clk_gate,       // Input from core domain
    output wire clk_gate_clk    // Gated clock output (high when scan_en is inactive)
);

    reg scan_en_q1, scan_en_q2;
    wire scan_en_bus;     // Synchronized signal in clk domain


    // 2-stage synchronizer to safely bring clk_gate into clk domain
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scan_en_q1 <= 1'b0;
            // scan_en_q2 <= 1'b0;
        end else begin
            scan_en_q1 <= clk_gate;
            // scan_en_q2 <= scan_en_q1;
        end
    end

    assign scan_en_bus    = scan_en_q1;
    // always @(*) begin
    //     if (~clk) scan_en_bus = scan_en_q1;
    // end



    assign clk_gate_clk  = clk & ~scan_en_bus;

endmodule
