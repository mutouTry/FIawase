# SPDX-License-Identifier: Apache-2.0
# Copyright 2025-2026 the FIawase authors
# ==========================================================================
# Gate-level FI simulation with VCS, for any DUT. A DUT's own Makefile sets
# what is specific to it and includes this file last:
#
#     NETLIST      the scan-inserted netlist
#     TB_SRC       the testbench sources (sim/fi_tb_template.sv is a start)
#     TB_INCDIRS   include directories the testbench needs
#     PLUSARGS     runtime arguments of the testbench
#     SDF_INSTANCE the DUT instance $sdf_annotate targets
#     include /path/to/FIawase/sim/fi_sim.mk
#
# The simulator, OpenOCD and the library models come from site.mk at the
# top of FIawase (site.mk.example lists them). Then:
#
#     make              build and run
#     make wave         same, dumping a waveform
#     make run          re-run without rebuilding
#     make openocd      OpenOCD for this netlist, in a second shell
#     make echo-config  show the resolved configuration
# ==========================================================================

FIAWASE   := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)

.DEFAULT_GOAL := all

FI_SITE   ?= $(FIAWASE)/site.mk
-include $(FI_SITE)

SIM_TOOL       ?= vcs
# A command prefix, so a container or a site wrapper works too:
#     VCS := singularity exec /path/to/vcs.sif vcs
VCS            ?= vcs
OPENOCD        ?= openocd
NETLIST        ?=
STDCELL_MODELS ?=
UDP_MODELS     ?=
MEM_MODELS     ?=
SDF            ?=
SDF_INSTANCE   ?=
SDF_CORNER     ?= MAXIMUM
DEFINES        ?=
DUMPWAVE       ?= 0
EXTRA_SRC      ?=
EXTRA_INCDIRS  ?=
EXTRA_OPTS     ?=
CLEAN_EXTRA    ?=

# Uninitialised flops start at a random value (+vcs+initreg+random), so the
# seed decides what the workload reads before it writes. It is pinned to make
# a campaign reproducible; a trial whose outcome moves with SEED depends on
# state the workload never initialised.
SEED           ?= 1

# The wrapper's fi_scan_cfg.vh and the host's fi_scan_cfg.tcl are the ones
# synthesis wrote next to the netlist, so all three always match.
FI_CFG_DIR     ?= $(patsubst %/,%,$(dir $(NETLIST)))

# site.mk is hand-written; an inline comment after a value leaves trailing
# blanks that break the strings built below.
override SIM_TOOL     := $(strip $(SIM_TOOL))
override VCS          := $(strip $(VCS))
override SDF          := $(strip $(SDF))
override SDF_CORNER   := $(strip $(SDF_CORNER))
override SDF_INSTANCE := $(strip $(SDF_INSTANCE))
override NETLIST      := $(strip $(NETLIST))
override FI_CFG_DIR   := $(strip $(FI_CFG_DIR))

# ---- required inputs ------------------------------------------------------
# Checked only for goals that build or run something, so `make clean` and
# `make help` work without a site.mk.
CONFIG_HINT   := -- copy site.mk.example to site.mk at the top of FIawase and fill it in
NEEDS_CONFIG  := all build wave run openocd echo-config
ACTIVE_GOALS  := $(or $(MAKECMDGOALS),all)

ifneq (,$(filter $(NEEDS_CONFIG),$(ACTIVE_GOALS)))
  ifeq ($(NETLIST),)
    $(error NETLIST is not set $(CONFIG_HINT))
  endif
  # ALLOW_NO_STDCELL=1 if the netlist carries its own cell models.
  ifeq ($(strip $(STDCELL_MODELS)),)
    ifneq ($(ALLOW_NO_STDCELL),1)
      $(error STDCELL_MODELS is not set -- every cell in $(notdir $(NETLIST)) would be an undefined module $(CONFIG_HINT))
    endif
  endif
  ifeq ($(wildcard $(FI_CFG_DIR)/fi_scan_cfg.vh),)
    $(error $(FI_CFG_DIR)/fi_scan_cfg.vh not found -- synthesis writes it next to the netlist only when the checks pass; set FI_CFG_DIR if your flow puts it elsewhere)
  endif
  # The campaign needs host JTAG, and host JTAG needs the jtagdpi C++ bridge,
  # which iverilog does not compile. tests/run.sh is the iverilog check.
  ifneq ($(SIM_TOOL),vcs)
    $(error SIM_TOOL=$(SIM_TOOL) is not supported -- the gate-level campaign needs VCS. For a PDK-free check run tests/run.sh instead)
  endif
endif

# ---- sources --------------------------------------------------------------
# The DUT comes from $(NETLIST) and the cells it is built from from the
# library models; the wrapper, the JTAG DPI bridge and the testbench are RTL.
FI_SRC    := $(wildcard $(FIAWASE)/rtl/*.v)
DPI_DIR   := $(FIAWASE)/sim/jtag_dpi
DPI_SRC   := $(DPI_DIR)/jtagdpi/jtagdpi.sv $(DPI_DIR)/jtagdpi/jtagdpi.cc \
             $(DPI_DIR)/common/tcp_server/tcp_server.cc
LIB_SRC   := $(STDCELL_MODELS) $(UDP_MODELS) $(MEM_MODELS)
SRC       := $(NETLIST) $(LIB_SRC) $(FI_SRC) $(DPI_SRC) $(TB_SRC) $(EXTRA_SRC)

INCDIRS   := $(FI_CFG_DIR) $(FIAWASE)/rtl \
             $(DPI_DIR)/jtagdpi $(DPI_DIR)/common/tcp_server \
             $(TB_INCDIRS) $(EXTRA_INCDIRS)

# ---- SDF ------------------------------------------------------------------
# SDF delays are in ps: at a 10ps precision every sub-nanosecond path would
# round to zero, so SDF moves the precision to 1ps.
ifeq ($(SDF),)
  TIMESCALE  := 1ns/10ps
  TIMING_OPT := +nospecify +notimingcheck
  SDF_DEF    :=
else
  TIMESCALE  := 1ns/1ps
  TIMING_OPT := +neg_tchk
  SDF_DEF    := +define+SDF_SIM \
                +define+FI_SDF_FILE=\"$(SDF)\" \
                +define+FI_SDF_INSTANCE=$(SDF_INSTANCE) \
                +define+FI_SDF_CORNER=\"$(SDF_CORNER)\" \
                +define+FI_SDF_SCALE=\"FROM_$(SDF_CORNER)\"
endif

# ---- waveform -------------------------------------------------------------
# $fsdbDump* needs the Verdi PLI linked in; without VERDI_HOME the testbench
# falls back to VCD (FI_FSDB undefined).
VERDI_PLI := $(strip $(VERDI_HOME))/share/PLI/VCS/linux64
ifneq ($(strip $(VERDI_HOME)),)
  ifneq ($(wildcard $(VERDI_PLI)/novas.tab),)
    WAVE_OPT := -P $(VERDI_PLI)/novas.tab $(VERDI_PLI)/libnovas.so +define+FI_FSDB
  endif
endif
WAVE_OPT ?=

# One binary per configuration, so toggling SDF never reuses the other build.
BUILD_TAG := $(SIM_TOOL)$(if $(SDF),.sdf,)

VCS_INC  := +incdir+$(subst $(subst ,, ),+,$(strip $(INCDIRS)))
SIMV     := ./simv.$(BUILD_TAG)
OPTS     := +v2k -sverilog -full64 -q -timescale=$(TIMESCALE) \
            +define+vcs +define+no_warning +vcs+initreg+random \
            $(TIMING_OPT) -negdelay \
            +lint=all,noSVA-NSVU,noVCDE,noUI,noSVA-CE,noSVA-DIU \
            +lint=noIWU,noOUDPE,noPCUDPE \
            -LDFLAGS -Wl,--no-as-needed -debug_access+all \
            $(DEFINES) $(SDF_DEF) $(WAVE_OPT) $(VCS_INC) $(EXTRA_OPTS)
BUILD    := $(VCS) $(OPTS) $(SRC) -o $(SIMV)
EXEC     := $(SIMV) +ntb_random_seed=$(SEED) +DUMPWAVE=$(DUMPWAVE) $(PLUSARGS)

.PHONY: all build wave run openocd echo-config clean help
help:
	@echo "make              build and run the campaign simulation"
	@echo "make wave         same, dumping a waveform"
	@echo "make run          re-run without rebuilding"
	@echo "make openocd      OpenOCD for this netlist (second shell)"
	@echo "make echo-config  show the resolved configuration"
	@echo "make clean        remove build products"

all: build
	$(EXEC)

build:
	$(BUILD)

wave:
	$(MAKE) all DUMPWAVE=1

run:
	$(EXEC)

openocd:
	$(OPENOCD) -c "set FI_CFG $(FI_CFG_DIR)/fi_scan_cfg.tcl" -f $(FIAWASE)/host/fi_openocd.cfg

echo-config:
	@echo "SIM_TOOL       = $(SIM_TOOL)"
	@echo "VCS            = $(VCS)"
	@echo "NETLIST        = $(NETLIST)"
	@echo "FI_CFG_DIR     = $(FI_CFG_DIR)"
	@echo "STDCELL_MODELS = $(STDCELL_MODELS)"
	@echo "UDP_MODELS     = $(UDP_MODELS)"
	@echo "MEM_MODELS     = $(MEM_MODELS)"
	@echo "DEFINES        = $(DEFINES)"
	@echo "SEED           = $(SEED)"
	@echo "SDF            = $(if $(SDF),$(SDF) [$(SDF_CORNER)] into $(SDF_INSTANCE),(none, timing off))"
	@echo "TIMESCALE      = $(TIMESCALE)"
	@echo "PLUSARGS       = $(PLUSARGS)"
	@echo "sources        = $(words $(SRC)) files"

clean:
	rm -rf simv.* csrc ucli.key *.fsdb *.vcd \
	       verdiLog novas.* DVEfiles annotate.log $(CLEAN_EXTRA)
