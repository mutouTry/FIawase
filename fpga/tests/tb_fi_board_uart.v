// SPDX-License-Identifier: Apache-2.0
// Copyright 2025-2026 the FIawase authors
// fi_board_uart: every trial's record and bytes reach the host line intact while the FIFO pointers wrap.
// A small FIFO (FIFO_AW = 4) and a short host bit (OUT_DIV = 4) make the pointers wrap every two trials.
// Each trial: a record, then a burst of NB DUT bytes faster than the line drains them (the FIFO holds
// up to NB - 1 of them, well below its depth), then a quiet tail long enough to drain everything.
// The testbench decodes the line (8N1, SLIP) and checks every record (trial number, flags 0) and every
// byte. iverilog: see run.sh.
`timescale 1ns/1ps
module tb_fi_board_uart;
    localparam integer DIV = 4, AW = 4, NB = 8, NT = 60, GAP = 8, TLEN = 1000;
    reg clk = 0, rst_n = 0, dut_rst_n = 0, run = 0, bv = 0, abort = 0;
    reg [7:0] bd = 0;
    wire tx;
    always #5 clk = ~clk;
    fi_board_uart #(.OUT_DIV(DIV), .FIFO_AW(AW)) dut (
        .clk_i(clk), .rst_ni(rst_n), .dut_rst_ni(dut_rst_n), .trial_run_i(run),
        .byte_v_i(bv), .byte_i(bd), .abort_i(abort), .tx_o(tx));

    // host side (decoder below)
    integer k, n_rec = 0, nr = 0, cur = 0, pos = 0, errors = 0, got_bytes = 0;
    reg [7:0] x, r [0:7];
    reg esc = 0, in_rec = 0;

    function [7:0] val(input integer t, input integer i);
        val = 8'h10 + ((t * NB + i) % 96);           // never C0 or DB
    endfunction

    // stimulus: trial t = 1..NT (its record carries t - 1: run 0 is the first DUT run after the board reset),
    // NB bytes from cycle 500 of the trial
    integer t, i, c;
    initial begin
        repeat (5) @(posedge clk); rst_n <= 1;
        for (t = 1; t <= NT; t = t + 1) begin
            dut_rst_n <= 0; run <= 0; repeat (5) @(posedge clk);
            dut_rst_n <= 1; run <= 1;
            for (c = 0; c < TLEN; c = c + 1) begin
                @(posedge clk);
                bv <= 0;
                if (c >= 500 && c < 500 + NB * GAP && (c - 500) % GAP == 0) begin
                    bv <= 1; bd <= val(t, (c - 500) / GAP);
                end
            end
            run <= 0;
        end
        dut_rst_n <= 0; repeat (5) @(posedge clk); dut_rst_n <= 1;   // the record that closes trial NT
        repeat (40 * DIV * 10) @(posedge clk);
        if (n_rec != NT + 1 || errors != 0 || got_bytes != NT * NB)
            $display("FAIL: %0d records (want %0d), %0d bytes (want %0d), %0d errors", n_rec, NT + 1,
                     got_bytes, NT * NB, errors);
        else
            $display("PASS: %0d records, %0d bytes, no flags set", n_rec, got_bytes);
        $finish;
    end

    // host side: 8N1 at DIV clocks per bit, SLIP, records C0 54 <trial:2> <cycles:4> <flags:1>
    always begin
        @(negedge tx);
        repeat (DIV / 2) @(posedge clk);
        for (k = 0; k < 8; k = k + 1) begin repeat (DIV) @(posedge clk); x[k] = tx; end
        repeat (DIV) @(posedge clk);
        if (x == 8'hC0) begin in_rec = 1; nr = 0; esc = 0; end
        else if (x == 8'hDB) esc = 1;
        else begin
            if (esc) begin x = (x == 8'hDC) ? 8'hC0 : 8'hDB; esc = 0; end
            if (in_rec) begin
                r[nr] = x; nr = nr + 1;
                if (nr == 8) begin
                    in_rec = 0;
                    if (n_rec > 0 && pos != NB) begin
                        errors = errors + 1;
                        $display("trial %0d: %0d bytes before the next record", cur, pos);
                    end
                    if ({r[1], r[2]} != n_rec || r[7] != 0) begin
                        errors = errors + 1;
                        $display("record %0d: trial %0d, flags %0d", n_rec, {r[1], r[2]}, r[7]);
                    end
                    cur = {r[1], r[2]}; pos = 0; n_rec = n_rec + 1;
                end
            end else begin
                if (x != val(cur + 1, pos)) begin              // record n opens stimulus trial n + 1
                    errors = errors + 1;
                    $display("trial %0d byte %0d: %02h, want %02h", cur, pos, x, val(cur + 1, pos));
                end
                pos = pos + 1; got_bytes = got_bytes + 1;
            end
        end
    end
endmodule
