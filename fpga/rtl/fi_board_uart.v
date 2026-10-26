// SPDX-License-Identifier: Apache-2.0
// Copyright 2025-2026 the FIawase authors
// ============================================================
// fi_board_uart -- the DUT's output for a host, split by trial
// ------------------------------------------------------------
// A campaign runs its trials back to back with no host in the loop, so on a board
// the host needs to know which bytes belong to which trial. This block takes the
// DUT's output bytes from a decoder outside it (the one the simulation's observer
// uses for this DUT, so that both read the same bytes at the same cycles) and
// re-sends them to the host at a standard rate, with a record in front of every
// trial:
//
//   C0 54 <trial:2> <cycles:4> <flags:1>     (multi-byte fields big-endian)
//
//   trial   counts DUT reset releases since the board reset (0 = the run from
//           power-on); every trial of a campaign starts with one
//   cycles  clock cycles from the previous record to this one: the length of the
//           previous trial, reset window included, measured on the board
//   flags   about the previous trial: bit 0 a memory asked to end it (undo log full,
//           counted as DUE); bit 1 bytes were lost (the FIFO was full)
//
// A byte belongs to the trial only if the decoder completes it inside the trial's
// output window (trial_run_i, fi_wrapper_top trial_run_o), the rule a simulation
// observer applies too. A byte that
// completes during the scrub or the reset window after the trial stopped is not
// sent; the decoder is reset by fi_rst, so a frame cut off by the reset is dropped.
//
// Every other byte is the DUT's. Bytes C0 and DB in a record or in the DUT's data
// are sent as DB DC and DB DD (SLIP). The host line is 8N1 at clk_i / OUT_DIV.
// ============================================================
module fi_board_uart #(
    parameter integer OUT_DIV      = 108,
    parameter integer FIFO_AW      = 10
)(
    input  wire       clk_i,
    input  wire       rst_ni,         // board reset
    input  wire       dut_rst_ni,     // the DUT reset (fi_rst): each release starts a trial
    input  wire       trial_run_i,    // the trial's output window (fi_wrapper_top trial_run_o)
    input  wire       byte_v_i,       // the decoder received a byte (one cycle)
    input  wire [7:0] byte_i,
    input  wire       abort_i,        // a memory asks to end the trial
    output wire       tx_o
);
    // ---- the trial's bytes: what the decoder completes inside the window
    wire       obs_v = byte_v_i & trial_run_i;
    wire [7:0] obs_d = byte_i;

    // ---- trial boundaries
    reg        dut_rst_q;
    reg [15:0] trial;
    reg [31:0] cyc;
    reg        f_abort, f_lost;
    reg        rec_go;                       // a record is waiting to be sent
    reg [7:0]  rec [0:8];
    always @(posedge clk_i or negedge rst_ni)
        if (!rst_ni) dut_rst_q <= 1'b0;
        else         dut_rst_q <= dut_rst_ni;
    wire trial_start = dut_rst_ni && !dut_rst_q;

    // ---- the byte sequencer: a record, then the DUT's bytes, one FIFO push per cycle
    reg  [7:0] dbuf;
    reg        dbuf_v;
    reg  [3:0] rp;                           // next record byte
    reg        esc;                          // the second byte of an escape is due
    reg  [7:0] esc_b;
    wire       full;
    reg        push;
    reg  [7:0] push_d;
    wire [7:0] cur = rec[rp];
    wire       cur_esc = (rp != 0) && (cur == 8'hC0 || cur == 8'hDB);
    wire       d_esc = (dbuf == 8'hC0 || dbuf == 8'hDB);
    wire       take_d = !full && !esc && !rec_go && dbuf_v;   // the sequencer sends dbuf now

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            trial <= 16'd0; cyc <= 32'd0;
            f_abort <= 1'b0; f_lost <= 1'b0;
            rec_go <= 1'b0; rp <= 4'd0; esc <= 1'b0; esc_b <= 8'd0;
            dbuf <= 8'd0; dbuf_v <= 1'b0; push <= 1'b0; push_d <= 8'd0;
        end else begin
            push <= 1'b0;
            cyc  <= cyc + 1'b1;
            if (abort_i)  f_abort <= 1'b1;
            // the DUT's byte waits in dbuf; it is freed this cycle if the sequencer takes it
            if (obs_v) begin
                if (dbuf_v && !take_d) f_lost <= 1'b1;
                else begin dbuf <= obs_d; dbuf_v <= 1'b1; end
            end else if (take_d) begin
                dbuf_v <= 1'b0;
            end
            if (trial_start) begin
                if (rec_go) f_lost <= 1'b1;   // the previous record is still out: drop the new one
                else begin
                    rec[0] <= 8'hC0; rec[1] <= 8'h54;
                    rec[2] <= trial[15:8]; rec[3] <= trial[7:0];
                    rec[4] <= cyc[31:24]; rec[5] <= cyc[23:16]; rec[6] <= cyc[15:8]; rec[7] <= cyc[7:0];
                    rec[8] <= {6'd0, f_lost, f_abort || abort_i};
                    rec_go <= 1'b1; rp <= 4'd0;
                    f_abort <= 1'b0; f_lost <= 1'b0;
                end
                trial <= trial + 1'b1;
                cyc   <= 32'd1;
            end
            if (!full) begin
                if (esc) begin
                    push <= 1'b1; push_d <= esc_b; esc <= 1'b0;
                end else if (rec_go) begin
                    push <= 1'b1;
                    if (cur_esc) begin
                        push_d <= 8'hDB; esc <= 1'b1; esc_b <= (cur == 8'hC0) ? 8'hDC : 8'hDD;
                    end else push_d <= cur;
                    if (rp == 4'd8) rec_go <= 1'b0;
                    rp <= rp + 1'b1;
                end else if (take_d) begin
                    push <= 1'b1;
                    if (d_esc) begin
                        push_d <= 8'hDB; esc <= 1'b1; esc_b <= (dbuf == 8'hC0) ? 8'hDC : 8'hDD;
                    end else push_d <= dbuf;
                end
            end
        end
    end

    // ---- FIFO
    localparam integer DEPTH = 1 << FIFO_AW;
    reg [7:0]       mem [0:DEPTH-1];
    reg [FIFO_AW:0] wp, rdp;
    // the occupancy in the pointers' own width, so it stays right when wp has wrapped and rdp not yet
    // (compared directly with the 32-bit DEPTH, wp - rdp would be taken in 32 bits)
    wire [FIFO_AW:0] used = wp - rdp;
    assign full = used >= DEPTH - 2;              // room for the push in flight
    wire   empty = (wp == rdp);
    always @(posedge clk_i) if (push) mem[wp[FIFO_AW-1:0]] <= push_d;
    always @(posedge clk_i or negedge rst_ni)
        if (!rst_ni) wp <= 0; else if (push) wp <= wp + 1'b1;

    // ---- 8N1 transmitter
    localparam integer DW = $clog2(OUT_DIV + 1);
    reg [DW-1:0] div;
    reg [3:0]    nb;                              // bits left in the frame
    reg [9:0]    frame;
    reg          tx_q;
    assign tx_o = tx_q;
    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            rdp <= 0; div <= 0; nb <= 4'd0; frame <= 10'h3FF; tx_q <= 1'b1;
        end else if (nb == 4'd0) begin
            tx_q <= 1'b1;
            if (!empty) begin
                frame <= {1'b1, mem[rdp[FIFO_AW-1:0]], 1'b0};
                rdp   <= rdp + 1'b1;
                nb    <= 4'd10;
                div   <= 0;
            end
        end else begin
            tx_q <= frame[0];
            if (div == OUT_DIV - 1) begin
                div   <= 0;
                frame <= {1'b1, frame[9:1]};
                nb    <= nb - 1'b1;
            end else div <= div + 1'b1;
        end
    end
endmodule
