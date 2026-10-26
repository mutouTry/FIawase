# SPDX-License-Identifier: Apache-2.0
# Copyright 2025-2026 the FIawase authors
# ============================================================
# design.tcl -- how the example flow reads this DUT
# ------------------------------------------------------------
# Read by syn/flow/dc_fi.tcl. Relative paths are relative to this
# directory. The libraries are not here: they belong to the machine,
# and come from site.mk at the top of FIawase.
# ============================================================

set FI_DESIGN_TOP    tinyriscv_soc_top

# Directories handed to `analyze -autoread -recursive`; packages are
# resolved by autoread. The FI wrapper is not among them: it sits
# outside the DUT and is never synthesised into it.
set FI_RTL_DIRS      [list ../rtl/pkg \
                           ../rtl/core \
                           ../rtl/debug \
                           ../rtl/perips \
                           ../rtl/sys_bus \
                           ../rtl/utils \
                           ../rtl/top]
set FI_RTL_INCDIRS   [list ../rtl/core ../rtl/debug ../rtl/pkg]

# T22NM, the example SoC's own switch, selects memory macros over
# inferred RAM. The simulation uses the same define (../sim/Makefile).
set FI_RTL_DEFINES   [list T22NM]

set FI_SDC           fi_example.sdc
