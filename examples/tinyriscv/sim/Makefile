# SPDX-License-Identifier: Apache-2.0
# Copyright 2025-2026 the FIawase authors
# ==========================================================================
# Gate-level FI simulation of the example SoC. The build itself is
# sim/fi_sim.mk; this file names the netlist, the testbench and its inputs.
# The simulator and the library models come from site.mk at the top of
# FIawase.
#
#     make              # build and run
#     make openocd      # second shell
# ==========================================================================

EX           := $(abspath $(CURDIR)/..)

NETLIST      ?= $(abspath $(EX)/../../syn/flow/results/tinyriscv_soc_top.mapped.v)
DEFINES      ?= +define+T22NM
TB_SRC       := $(wildcard $(EX)/tb/*.sv) $(wildcard $(EX)/tb/*.v)
TB_INCDIRS   := $(EX)/rtl/core $(EX)/rtl/debug $(EX)/rtl/perips $(EX)/rtl/pkg
SDF_INSTANCE ?= chaos_soc_tb.u_tinyriscv_soc_top
FIRMWARE     ?= $(EX)/firmware/application_intmix.verilog
PLUSARGS      = +firmware=$(FIRMWARE)
CLEAN_EXTRA  := inst_valid_log.txt fi_exec_window.txt uart_*.log

include $(EX)/../../sim/fi_sim.mk

# T22NM, the example SoC's own switch, selects memory macros over inferred
# RAM, so the netlist then instantiates macros that need models.
ifneq (,$(filter $(NEEDS_CONFIG),$(ACTIVE_GOALS)))
  ifneq (,$(findstring T22NM,$(DEFINES)))
    ifeq ($(strip $(MEM_MODELS)),)
      $(warning DEFINES contains T22NM but MEM_MODELS is empty -- the SRAM macros will be undefined modules)
    endif
  endif
endif
