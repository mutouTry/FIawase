// SPDX-License-Identifier: Apache-2.0
// Copyright 2025-2026 the FIawase authors
// =============================================================================
// cdc_rv_1deep: 1-deep bundled-data CDC bridge with toggle handshake.
//
// Protocol assumptions (caller responsibility):
//   - A side (clk_a) is allowed to be gated between transactions. The
//     bridge itself does not detect gating; the caller MUST ensure v_i=0
//     while clk_a is frozen or about to be frozen. Otherwise hold_a/req_a
//     could be updated on the "last active edge" while ack_a_sync is
//     still stale, leaving the bridge visibly non-empty from A but already
//     consumed from B — which forces A to wait an extra 2 clk_a cycles
//     after gate release to resynchronize ack.
//   - B side (clk_b) is assumed always-running; r_i may be held low
//     freely, but must not be pulsed while v_o=0.
//
// In the scan_uart_core caller, gating of v_i is achieved by ANDing
// tx_valid_a with ~scan_gate_view (2FF-synchronized scan_gate on
// clk_b=clk_tx_i, read combinationally in clk_a domain). See caller for
// the timing rationale.
// =============================================================================
module cdc_rv_1deep #(
  parameter DW = 8
)(
  // A = the gateable domain (connects to the FIFO)
  input  wire          clk_a, rstn_a,
  input  wire          v_i,
  input  wire [DW-1:0] d_i,
  output wire          r_o,   // bridge empty -> FIFO may pop

  // B = the always-on tx domain (connects to uart_tx)
  input  wire          clk_b, rstn_b,
  output wire          v_o,   // valid to uart_tx
  output reg  [DW-1:0] d_o,   // data to uart_tx
  input  wire          r_i    // ready from uart_tx
);
  // ===== A domain: latch the data first, then flip the request (bundled data) =====
  reg req_a;
  reg [DW-1:0] hold_a;
  wire ack_a_sync;

  wire empty_a = (req_a == ack_a_sync);
  assign r_o = empty_a;             // only pop the FIFO while the bridge is empty
  wire load  = v_i & empty_a;       // accept a new byte only when empty

  always @(posedge clk_a or negedge rstn_a) begin
    if(!rstn_a) begin
      req_a  <= 1'b0;
      hold_a <= {DW{1'b0}};
    end else if (load) begin
      hold_a <= d_i;                // settle the data first
      req_a  <= ~req_a;             // then flip the request: by the time B sees it the data has been stable >= 2 cycles
    end
  end

  // A <- B: synchronise ack_b
  reg ack_b;
  reg ack_a_d1, ack_a_d2;
  always @(posedge clk_a or negedge rstn_a) begin
    if(!rstn_a) {ack_a_d1,ack_a_d2} <= 2'b00;
    else        {ack_a_d1,ack_a_d2} <= {ack_b,ack_a_d1};
  end
  assign ack_a_sync = ack_a_d2;

  // B <- A: synchronise req_a
  reg req_b_d1, req_b_d2;
  always @(posedge clk_b or negedge rstn_b) begin
    if(!rstn_b) {req_b_d1,req_b_d2} <= 2'b00;
    else        {req_b_d1,req_b_d2} <= {req_a,req_b_d1};
  end

  // ===== B domain: one cycle to load, consumable from the next (skid stage) =====
  wire have_new = (req_b_d2 ^ ack_b);  // a new request arrived (toggle)

  reg holding_b;                       // do we hold a byte locally (drives v_o)
  assign v_o = holding_b;              // driven only by holding_b, so it lasts a full cycle

  always @(posedge clk_b or negedge rstn_b) begin
    if(!rstn_b) begin
      holding_b <= 1'b0;
      d_o       <= {DW{1'b0}};
      ack_b     <= 1'b0;
    end else begin
      // first sight of new data: load d_o and set holding_b
      if (have_new && !holding_b) begin
        d_o       <= hold_a;     // hold_a is settled by now (A latched first, req went through two sync stages)
        holding_b <= 1'b1;       // v_o goes high now, consumed from the next cycle
        // do not ack yet: valid must last at least one full cycle
      end
      // ack and release only while holding (v_o=1) and the sink is ready
      if (holding_b && r_i) begin
        holding_b <= 1'b0;
        ack_b     <= req_b_d2;   // one transfer complete
      end
    end
  end
endmodule






