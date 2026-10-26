# SPDX-License-Identifier: Apache-2.0
# Copyright 2025-2026 the FIawase authors
# ============================================================
# fi_scan_cfg.tcl -- the FI description of one DUT, here the
#                    example tinyriscv_soc_top
# ------------------------------------------------------------
# The ONE FI file a port writes. It sits in the port directory
# next to design.tcl and the SDC, and whatever flow runs the
# FIawase steps sources it before syn/fi_scan_lib.tcl. Everything
# else (fi_scan_lib.tcl, fi_clk_gate.v) is DUT independent.
# Settings this file leaves out take the defaults at the top of
# syn/lib/common.tcl.
# ============================================================

# ---- DUT top-level ports -----------------------------------
set FI_CLK_PORT      clk_50m_i     ;# free-running functional clock
set FI_RST_PORT      rst_ext_ni    ;# async reset, active low
set FI_GATE_PORT     scan_gate     ;# freeze request from the FI wrapper.
                                    # FIawase calls this signal Clk_Gate; the
                                    # PORT name is the DUT's own, so put here
                                    # whatever your design already calls it.
                                    # If the DUT has no such port,
                                    # fi_insert_clock_gate creates it (and
                                    # warns) -- but then you must also wire it
                                    # at the next level up.

# Scan ports. These three are CREATED by fi_dft_config -- your DUT does not
# need to declare them; DFT insertion wires them up. Rename only if the
# names collide with something already at your top level.
set FI_SCAN_IN_PORT  io_scanin
set FI_SCAN_OUT_PORT io_scanout
set FI_SCAN_EN_PORT  io_scanen     ;# scan enable; the shift condition of A6-A8
set FI_TESTMODE_PORT io_testmode   ;# a DUT port, or created by the flow from FI_TESTMODE_PIN

# ---- THE single source of truth ----------------------------
# Clock PINS (not instances) that must stop during the scan window.
# Everything clocked by them is frozen AND kept off the scan chain --
# in this flow those are the same operation, applied by
# fi_insert_clock_gate + fi_apply_scan_exclusion and then proven by
# fi_check_invariants.
#
# Pin granularity matters: a block with two clocks may need only one
# of them frozen. uart0 is exactly that case -- see the note below.
set FI_GATE_PINS {
    u_rom/clk_i
    u_ram/clk_i
    u_jtag/clk_i
    uart0/clk_i
    spi0/clk_i
    xip/clk_i
    bootrom/clk_i
    u_pinmux/clk_i
    uart1/clk_i
    uart2/clk_i
    i2c0/clk_i
    timer0/clk_i
    timer1/clk_i
    timer2/clk_i
}
# uart1, uart2, i2c0 and timer0-2 are peripherals the example workload
# never access, so they are left out of the FI scope: frozen, not
# shifted. Outside the scan window they run as usual.
# uart0/clk_tx_i is deliberately NOT here. The in-flight byte has to
# finish shifting out while the core is frozen, which is the whole
# point of scan_uart_top's FIFO+CDC. That leaves uart0's tx-side flops
# neither gated nor on the
# chain, so uart0 also appears in FI_EXEMPT below.
#
# u_pinmux is here because with it on the chain, shifting
# scrambles the pad mux and garbles the UART output. Freezing it holds
# the pin selection steady across the whole scan window.

# ---- Explicit exemptions, by instance -----------------------
# Instances allowed to be NEITHER on the chain NOR frozen. Assertion A3
# reports everything else that ends up in that state, so this list is
# how you acknowledge a deliberate one. Every entry needs a reason.
#
# Listing an instance here ALSO exempts it from assertion A2. That is
# the escape hatch for a block with two clocks where only one is frozen
# and the other legitimately stays on the chain -- you are taking
# responsibility for that block.
set FI_EXEMPT {
    u_rst
    uart0
}
#   u_rst   reset generator; freezing it would self-lock the DUT, and
#           shifting it would fire spurious resets mid-window.
#   uart0   its clk_tx_i domain must keep running, see above.

# ---- Explicit exemptions, by clock --------------------------
# Whole clock domains that are outside the FI scheme: neither shifted
# nor frozen. Legitimate ONLY if the clock is idle during the scan
# window, so its state cannot drift while the chain is scrambled.
# Names are as they appear in report_clocks.
set FI_EXEMPT_CLOCKS {
    jtag_TCK
}
#   jtag_TCK  the debug TAP, the DTM, and the TCK side of the DMI
#             2-phase CDC, all under u_jtag. Driven by the host
#             adapter, which is not shifting while FI runs. They are
#             inside u_jtag, whose clk_i IS frozen -- so without this
#             declaration A3 would either hide them (if it guessed by
#             hierarchy) or report them every run.

# ---- Encoding bound ----------------------------------------
# Written into the generated fi_scan_cfg.vh and .tcl. Only
# ceil(log2()) of it is used -- it fixes the FI_Entry field split, so
# keeping it a power of two means re-synthesis moving L does not move
# the table format. Contract: measured L <= FI_N_FF - 1 (assertion A4).
set FI_N_FF          8192

# ---- Where the artefacts go --------------------------------
# Leave both EMPTY to let fi_init_flow_vars decide. It inherits the
# Synopsys DC Reference Methodology's RESULTS_DIR / REPORTS_DIR if your
# flow defines them (so an RM-based setup keeps its paths), and
# otherwise falls back to ./results and ./reports. Set them here only if
# you want to override both.
#
# The individual output FILENAMES are resolved the same way and are not
# listed here; see fi_init_flow_vars in syn/lib/common.tcl if you need to
# override one.
#
# FI_TOP defaults to DESIGN_NAME / $env(TOP) / the current design, in that
# order. Note it only feeds the FALLBACK filenames: if your flow defines the
# RM's DCRM_* variables, those still win, because an explicit setting always
# beats a derived default.
# Defaulted, not assigned: design.tcl (or your own flow) may already
# have set these, and sourcing this file must not silently discard that.
foreach fi__v {FI_RESULTS_DIR FI_REPORTS_DIR FI_TOP} {
    if {![info exists $fi__v]} { set $fi__v "" }
}
unset fi__v

# ---- Names of the objects the flow creates -----------------
# Change only if they collide with something in your DUT. (These are the
# defaults; the rest of the names are at the top of syn/lib/common.tcl.)
set FI_GATE_MODULE   fi_clk_gate
set FI_GATE_INST     u_fi_clk_gate
set FI_GATE_NET      fi_clk_gated

# HARD REQUIREMENT on FI_GATE_PORT: it must be synchronous to
# FI_CLK_PORT. The gate reads it combinationally, and the whole
# "chain gets L extra shift edges, frozen blocks lose exactly L" account
# only means anything inside one clock domain. Here the FI wrapper runs
# on aon_hfclk_i = clk_50m_i, so it holds. tests/run.sh checks the gate's
# edge account.
