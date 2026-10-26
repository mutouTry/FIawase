// SPDX-License-Identifier: Apache-2.0
// Copyright 2025-2026 the FIawase authors
// ============================================================
// fi_clk_gate -- the FI wrapper's freeze gate, spliced in by the flow
// ------------------------------------------------------------
// Not instantiated by any RTL: fi_insert_clock_gate compiles it and splices
// one instance into the mapped netlist, so the flow needs no library cell
// names. A library ICG can take the gate's place; the ports are the
// contract.
//
//   clk_gate_i = 1  ->  clk_o frozen low
//   clk_gate_i = 0  ->  clk_o == clk_i
//
// The edge account of fi_scan_ctrl.v:
//
//   S       clk_gate <= 1
//   S+1     scan_en_o <= 1                (SE trails the gate by 1)
//   S+2..S+L+1                            the L shift edges
//   S+L+1   scan_en_o <= 0, clk_gate <= 0 (both fall together)
//
// The chain takes L extra edges, so a frozen block must lose exactly the
// same L edges, S+2 .. S+L+1: one fewer and it advances while the chain is
// scrambled, one more and it resumes a cycle behind. The enable is
// therefore asymmetric: it engages on the registered gate (edge S+1
// passes) and releases on the raw one (edge S+L+2 passes), i.e.
// ~(gate_q & clk_gate_i). A plain clk_i & ~gate_q loses the same edges but
// leaves a runt pulse at S+1, and an ICG enabled by ~gate_q alone masks L+1.
//
// Two constraints:
//  1) Exactly one synchroniser flop: a second stage shifts the window by a
//     cycle and breaks the restore.
//  2) clk_gate_i is synchronous to clk_i: it is read combinationally, and
//     the account holds only in one clock domain. A wrapper on a clock of
//     its own needs the account re-derived; a synchroniser does not help.
//
// The latch has no reset (an async-set latch is not in every library):
// clk_o is X for at most the first half cycle, while the frozen blocks are
// held in their own reset.
// ============================================================
module fi_clk_gate (
    input  wire clk_i,       // free-running functional clock
    input  wire rst_ni,      // async, active low
    input  wire clk_gate_i, // 1 = freeze; synchronous to clk_i
    output wire clk_o,       // gated clock
    output wire freeze_o     // the freeze window, for fi_clk_freeze cells
);

    // one stage, no more
    reg gate_q;
    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) gate_q <= 1'b0;   // clock runs while in reset
        else         gate_q <= clk_gate_i;
    end

    // engage late (registered), release early (raw) -> exactly L masked
    wire freeze = gate_q & clk_gate_i;
    assign freeze_o = freeze;

    // negative-level latch: enable is sampled while clk_i is low and
    // held across the whole high phase, so every emitted pulse is full
    // width. This is the inside of an ICG.
    reg latch_e;
    always @(*) begin
        if (~clk_i) latch_e = ~freeze;
    end

    assign clk_o = clk_i & latch_e;

endmodule

// ============================================================
// fi_clk_freeze -- the second half of fi_clk_gate on its own
// ------------------------------------------------------------
// For a frozen clock pin that is NOT driven straight by the functional
// clock but by a clock gate of the DUT (an RTL gate, or one compile
// inserted). Spliced in series on that pin's net, so the DUT's own gate
// keeps working; fi_clk_gate's synchroniser, on the free-running clock,
// supplies freeze_i. A synchroniser behind the DUT's gate would only see
// clk_gate when that gate happens to be open.
//
// Same edge account: an edge passes iff the DUT's gate passes it AND
// freeze is low at it. freeze is high from just after edge S+1 to just
// after edge S+L+1, so exactly the L window edges are removed, whatever
// the DUT's gate does meanwhile (testmode forces it open). The latch
// samples freeze while clk_i is low, which a gated clock always is when
// its gate is closed, so every pulse is still full width.
// ============================================================
module fi_clk_freeze (
    input  wire clk_i,       // a clock derived from the functional clock
    input  wire freeze_i,    // fi_clk_gate.freeze_o
    output wire clk_o        // the same clock, frozen in the window
);

    reg latch_e;
    always @(*) begin
        if (~clk_i) latch_e = ~freeze_i;
    end

    assign clk_o = clk_i & latch_e;

endmodule

// ============================================================
// fi_latch_hold -- the freeze for a latch that stores data
// ------------------------------------------------------------
// A latch whose enable is data, not a clock, cannot be shifted, and freezing
// a clock does not stop it: while the chain shifts, its enable follows the
// scrambled logic and the stored value can change. Spliced in front of the
// latch's enable before the first compile, where every latch is a generic
// latch with an active-high enable, it keeps the latch opaque while the
// window is open (hold_i = fi_clk_gate.freeze_o). No latch inside, unlike
// fi_clk_freeze: a data enable may stay high across the end of the window,
// and the latch must be transparent again on that very cycle. Edge account:
// freeze covers the same L cycles, so the latch steps exactly as the
// frozen blocks do.
// ============================================================
module fi_latch_hold (
    input  wire en_i,     // the latch's own enable
    input  wire hold_i,   // the freeze window
    output wire en_o      // to the latch's enable pin
);

    assign en_o = en_i & ~hold_i;

endmodule

// ============================================================
// fi_clear -- the clear for state no pass and no reset restores
// ------------------------------------------------------------
// A register off the chain that has no reset of any kind keeps, from one
// trial to the next, whatever the last trial left in it, while the
// fault-free reference starts it at 0. One instance at the top, spliced
// before the first compile onto the generic clear pin of each such
// register (FI_CLEAR, fi_scan_lib.tcl): high while the DUT reset is
// asserted, so the register is 0 at power-on, as before, and again at the
// start of every trial. The DUT never relies on the value: it gave the
// register no reset.
// ============================================================
module fi_clear (
    input  wire rst_ni,   // the DUT reset, active low (FI_RST_PORT)
    output wire clear_o   // to the clear pin of each register
);

    assign clear_o = ~rst_ni;

endmodule
