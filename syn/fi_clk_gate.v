// SPDX-License-Identifier: Apache-2.0
// Copyright 2025-2026 the FIawase authors
// ============================================================
// fi_clk_gate -- the FI wrapper's freeze gate, inserted by tooling
// ------------------------------------------------------------
// This module is NOT instantiated by any RTL. fi_scan_lib.tcl
// analyzes/elaborates/compiles it and then splices one instance into
// the mapped netlist (see fi_insert_clock_gate). Keeping it as source
// rather than hand-wiring library cells is what makes the flow
// portable: no CKLNQD*/DFCNQD*/INVD* names to guess per PDK. Swap in
// your library's real ICG here if you want one; the port list is the
// contract.
//
//   clk_gate_i = 1  ->  clk_o frozen low
//   clk_gate_i = 0  ->  clk_o == clk_i
//
// ============================================================
// THE EDGE ACCOUNT -- the only thing that actually matters
// ------------------------------------------------------------
// The edge account in fi_scan_ctrl.v pins the window down:
//
//   S       clk_gate <= 1
//   S+1     scan_en_o <= 1                (SE trails gate by 1)
//   S+2..S+L+1                            the L shift edges
//   S+L+1   scan_en_o <= 0, clk_gate <= 0 (both fall together)
//
// The chain flops are never gated, so they take L extra edges. For the
// DUT to come back consistent, the frozen blocks must lose EXACTLY
// those same L functional edges: S+2 .. S+L+1. One too few and a frozen
// block advances while the chain is scrambled; one too many and it
// resumes a cycle behind everything else.
//
// The enable therefore has to be ASYMMETRIC: it must engage on the
// REGISTERED clk_gate (so edge S+1 still passes) and release on the
// RAW clk_gate (so edge S+L+2 passes). That is what
// `~(gate_q & clk_gate_i)` is -- not a trick, just the intersection of
// the two windows.
//
// Measured against the real fi_scan_ctrl (L=8), masked cycles:
//   clk_i & ~gate_q          8..15   = L    but with a runt at 7
//   ICG, E = ~gate_q         8..16   = L+1  WRONG, one cycle too long
//   ICG, E = ~(gate_q&gate)  8..15   = L    and every pulse full width
//
// So this is bit-for-bit the same freeze window as the old
// scan_en_sync in the netlist -- it just removes the two marginal
// pulses that scan_en_sync produces at the window boundaries:
//   * at S+1 scan_en_sync emits a RUNT (width = t_co of gate_q). It is
//     the edge that must pass, and whether it does is a race. TODO T1.
//   * at S+L+2 scan_en_sync emits a LATE edge (delayed by the same
//     t_co), eating into that cycle's setup margin.
// Here both are full width.
//
// TWO CONSTRAINTS, both load-bearing:
//
//  1) EXACTLY ONE synchronizer flop. Adding a second stage "for
//     metastability" shifts the whole window by a cycle and silently
//     breaks restoration.
//
//  2) clk_gate_i MUST be synchronous to clk_i. It is read
//     combinationally in the enable, and the L-cycle account is only
//     meaningful if gate and clock share a domain. In this SoC the FI
//     wrapper runs on aon_hfclk_i = clk_50m_i = the DUT clock, so this
//     holds. On a DUT where the wrapper has its own clock, the whole
//     edge account has to be re-derived -- a synchronizer will not save
//     it.
//
// The latch is unreset on purpose: an async-set latch is not in every
// library and buys nothing. At t=0 latch_e is X until the first falling
// clk_i edge, so clk_o is X for at most half a cycle -- during which
// the gated blocks are held by their own async reset, so no X reaches
// any state element.
// ============================================================
module fi_clk_gate (
    input  wire clk_i,       // free-running functional clock
    input  wire rst_ni,      // async, active low
    input  wire clk_gate_i, // 1 = freeze; synchronous to clk_i
    output wire clk_o        // gated clock
);

    // one stage, no more
    reg gate_q;
    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) gate_q <= 1'b0;   // clock runs while in reset
        else         gate_q <= clk_gate_i;
    end

    // engage late (registered), release early (raw) -> exactly L masked
    wire freeze = gate_q & clk_gate_i;

    // negative-level latch: enable is sampled while clk_i is low and
    // held across the whole high phase, so every emitted pulse is full
    // width. This is the inside of an ICG.
    reg latch_e;
    always @(*) begin
        if (~clk_i) latch_e = ~freeze;
    end

    assign clk_o = clk_i & latch_e;

endmodule
