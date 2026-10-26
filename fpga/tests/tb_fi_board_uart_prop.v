// SPDX-License-Identifier: Apache-2.0
// Copyright 2025-2026 the FIawase authors
// fi_board_uart: properties checked at every cycle, random traffic, small FIFO (FIFO_AW = 3, so the pointers wrap often).
//  P1 full only when the true occupancy (pointer difference mod 2^(AW+1)) >= DEPTH-2
//  P2 the true occupancy never exceeds DEPTH (no overwrite)
//  P3 every byte on the line is the next byte the sequencer pushed (FIFO integrity across wraps)
// Traffic: random trial lengths (some shorter than the drain time, so records land in a non-empty FIFO),
// random gaps (dense bursts genuinely fill the FIFO), bytes C0/DB frequent (escape path). +SEED=<n> picks the traffic.
`timescale 1ns/1ps
module tb_fi_board_uart_prop;
    localparam integer AW = 3, DIV = 3, DEPTH = 1 << AW, NT = 3000;
    reg clk = 0, rst_n = 0, dut_rst_n = 0, run = 0, bv = 0;
    reg [7:0] bd = 0;
    wire tx;
    always #5 clk = ~clk;
    fi_board_uart #(.OUT_DIV(DIV), .FIFO_AW(AW)) dut (
        .clk_i(clk), .rst_ni(rst_n), .dut_rst_ni(dut_rst_n), .trial_run_i(run),
        .byte_v_i(bv), .byte_i(bd), .abort_i(1'b0), .tx_o(tx));
    integer occ, p1 = 0, p2 = 0, p3 = 0, full_cyc = 0, gen_full_cyc = 0, wraps = 0, nline = 0, nobs = 0, nflag2 = 0;
    reg [7:0] q [0:1048575];
    integer wi = 0, ri = 0;
    reg [AW:0] wp_d = 0;
    always @(posedge clk) if (rst_n) begin
        occ = (dut.wp - dut.rdp) & ((1 << (AW + 1)) - 1);
        if (dut.full) begin full_cyc = full_cyc + 1; if (occ >= DEPTH - 2) gen_full_cyc = gen_full_cyc + 1; end
        if (dut.full && occ < DEPTH - 2) p1 = p1 + 1;
        if (occ > DEPTH) p2 = p2 + 1;
        if (dut.push) begin q[wi] = dut.push_d; wi = wi + 1; end
        if (dut.wp == 0 && wp_d != 0) wraps = wraps + 1;
        wp_d = dut.wp;
        if (bv && run) nobs = nobs + 1;
    end
    // line decoder: raw bytes, compared with the pushed sequence; count records with flags bit 1
    integer k, nr = -1;
    reg [7:0] x;
    reg esc = 0;
    always begin
        @(negedge tx);
        repeat (DIV / 2) @(posedge clk);
        for (k = 0; k < 8; k = k + 1) begin repeat (DIV) @(posedge clk); x[k] = tx; end
        repeat (DIV) @(posedge clk);
        if (ri >= wi || x !== q[ri]) p3 = p3 + 1;
        ri = ri + 1; nline = nline + 1;
        if (x == 8'hC0) begin nr = 0; esc = 0; end
        else if (x == 8'hDB) esc = 1;
        else if (nr >= 0) begin
            if (esc) begin x = (x == 8'hDC) ? 8'hC0 : 8'hDB; esc = 0; end
            nr = nr + 1;
            if (nr == 8) begin if (x[1]) nflag2 = nflag2 + 1; nr = -1; end
        end
    end
    integer t, c, len, gap, seed;
    initial begin
        if (!$value$plusargs("SEED=%d", seed)) seed = 1;
        repeat (5) @(posedge clk); rst_n <= 1;
        for (t = 0; t < NT; t = t + 1) begin
            dut_rst_n <= 0; run <= 0; bv <= 0;
            repeat (2 + {$random(seed)} % 8) @(posedge clk);
            dut_rst_n <= 1; run <= 1;
            len = 40 + {$random(seed)} % 700;
            gap = 1 + {$random(seed)} % 60;
            for (c = 0; c < len; c = c + 1) begin
                @(posedge clk);
                bv <= 0;
                if (c > 15 && c < len - 5 && ({$random(seed)} % gap) == 0) begin
                    bv <= 1;
                    case ({$random(seed)} % 6) 0: bd <= 8'hC0; 1: bd <= 8'hDB; default: bd <= $random(seed); endcase
                end
            end
            bv <= 0; run <= 0;
            repeat ({$random(seed)} % 4) @(posedge clk);
        end
        dut_rst_n <= 0; repeat (3) @(posedge clk); dut_rst_n <= 1;
        repeat (DEPTH * 20 * DIV * 10) @(posedge clk);
        $display("trials %0d, DUT bytes in window %0d, pushes %0d, line bytes %0d, wp wraps %0d, records with flags bit 1: %0d",
                 NT, nobs, wi, nline, wraps, nflag2);
        $display("full cycles %0d (with true occupancy >= DEPTH-2: %0d)", full_cyc, gen_full_cyc);
        $display("P1 false-full cycles %0d | P2 overflow cycles %0d | P3 line != pushed %0d (+ %0d pushed not yet sent)",
                 p1, p2, p3, wi - ri);
        $display("%s", (p1 == 0 && p2 == 0 && p3 == 0 && wi == ri) ? "PROPERTY PASS" : "PROPERTY FAIL");
        $finish;
    end
endmodule
