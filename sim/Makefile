# SPDX-License-Identifier: Apache-2.0
# Copyright 2025-2026 the FIawase authors
# ==========================================================================
# Gate-level FI simulation.
#
#     cp config.mk.example config.mk    # then edit it
#     make                              # build and run
#     make echo-config                  # show the resolved configuration
#     make wave                         # same as make, dumping a waveform
#     make run                          # re-run without rebuilding
#
# Nothing foundry-owned is in this repository: the netlist, the standard
# cell simulation models and the SRAM models all come from config.mk.
# Everything else -- the FI wrapper, the testbench, the JTAG DPI bridge and
# the workload -- is here.
#
# Once it is running, drive the campaign from the host side:
#     openocd -f ../host/fi_openocd.cfg
# ==========================================================================

ROOT      := $(abspath $(CURDIR)/..)

# `help` is defined first for readability, so name the real default explicitly.
.DEFAULT_GOAL := all

-include config.mk

SIM_TOOL       ?= vcs
# How to invoke the simulator. Override in config.mk when it lives behind a
# container or a module wrapper, e.g.
#     VCS := singularity exec /path/to/vcs.sif vcs
VCS            ?= vcs
NETLIST        ?=
STDCELL_MODELS ?=
UDP_MODELS     ?=
MEM_MODELS     ?=
SDF            ?=
SDF_INSTANCE   ?= chaos_soc_tb.u_tinyriscv_soc_top
SDF_CORNER     ?= MAXIMUM
FIRMWARE       ?= $(ROOT)/firmware/application_intmix.verilog
DEFINES        ?= +define+T22NM
DUMPWAVE       ?= 0
EXTRA_SRC      ?=
EXTRA_INCDIRS  ?=
EXTRA_OPTS     ?=

# The build randomises every uninitialised flop (+vcs+initreg+random below),
# and this DUT has plenty: the GPRs have no reset and the SRAM starts empty.
# So the seed is part of the experiment, not an implementation detail -- it
# decides what the firmware reads before it writes.
#
# It is PINNED, not automatic. With a fresh seed per run the same campaign
# returns different verdicts for the same fault, which makes a result
# impossible to reproduce, to bisect, or to compare across two netlists.
#
# Change it deliberately: a trial whose class (masked / SDC / crash) moves
# with the seed is a trial whose outcome depends on state the workload never
# initialised. That is a real property of the fault, and worth knowing --
# just not something to discover by accident.
SEED           ?= 1

# config.mk is hand-written, so an inline comment after a value is likely.
# `:=` keeps the padding, which silently corrupts every string below --
# BUILD_TAG, the SDF defines, and the SIM_TOOL comparison. Collapse it once.
override SIM_TOOL     := $(strip $(SIM_TOOL))
override VCS          := $(strip $(VCS))
override SDF          := $(strip $(SDF))
override SDF_CORNER   := $(strip $(SDF_CORNER))
override SDF_INSTANCE := $(strip $(SDF_INSTANCE))
override NETLIST      := $(strip $(NETLIST))

# ---- required inputs ------------------------------------------------------
# Checked only for goals that actually build or run something, so that
# `make clean` / `make help` still work in a fresh clone with no config.mk.
CONFIG_HINT   := -- copy config.mk.example to config.mk and edit it
NEEDS_CONFIG  := all build wave run echo-config
ACTIVE_GOALS  := $(or $(MAKECMDGOALS),all)

ifneq (,$(filter $(NEEDS_CONFIG),$(ACTIVE_GOALS)))

  ifeq ($(strip $(NETLIST)),)
    $(error NETLIST is not set $(CONFIG_HINT))
  endif

  # A netlist without cell models links to nothing. Fail here rather than
  # with a wall of "undefined module" ten minutes into elaboration. Override
  # with ALLOW_NO_STDCELL=1 if your netlist carries its own cell models.
  ifeq ($(strip $(STDCELL_MODELS)),)
    ifneq ($(ALLOW_NO_STDCELL),1)
      $(error STDCELL_MODELS is not set -- every cell in $(notdir $(NETLIST)) would be an undefined module $(CONFIG_HINT))
    endif
  endif

  # T22NM means the netlist instantiates SRAM macros. Warn rather than fail:
  # a different DUT may define T22NM and supply its macros via EXTRA_SRC.
  ifneq (,$(findstring T22NM,$(DEFINES)))
    ifeq ($(strip $(MEM_MODELS)),)
      $(warning DEFINES contains T22NM but MEM_MODELS is empty -- the SRAM macros will be undefined modules)
    endif
  endif

endif

# ---- sources --------------------------------------------------------------
# rtl/fi is the wrapper. rtl/soc supplies only what the testbench needs
# around the netlist: the JTAG DPI bridge and the shared headers. The DUT
# logic itself comes from $(NETLIST), and the cells it is built from come
# from $(STDCELL_MODELS) / $(MEM_MODELS).
FI_SRC    := $(wildcard $(ROOT)/rtl/fi/*.v)
DPI_SRC   := $(wildcard $(ROOT)/rtl/soc/jtag_dpi/jtagdpi/*.sv) \
             $(wildcard $(ROOT)/rtl/soc/jtag_dpi/jtagdpi/*.cc) \
             $(wildcard $(ROOT)/rtl/soc/jtag_dpi/common/tcp_server/*.cc)
TB_SRC    := $(wildcard $(ROOT)/tb/*.sv) $(wildcard $(ROOT)/tb/*.v)
LIB_SRC   := $(STDCELL_MODELS) $(UDP_MODELS) $(MEM_MODELS)

SRC       := $(NETLIST) $(LIB_SRC) $(FI_SRC) $(DPI_SRC) $(TB_SRC) $(EXTRA_SRC)

INCDIRS   := $(ROOT)/rtl/fi $(ROOT)/rtl/soc/core $(ROOT)/rtl/soc/debug \
             $(ROOT)/rtl/soc/perips $(ROOT)/rtl/soc/pkg \
             $(ROOT)/rtl/soc/jtag_dpi/jtagdpi \
             $(ROOT)/rtl/soc/jtag_dpi/common/tcp_server \
             $(EXTRA_INCDIRS)

# ---- SDF ------------------------------------------------------------------
# With SDF set, timing is real: keep the specify blocks and the timing
# checks, and move the timescale precision to 1ps -- SDF delays are given in
# ps, so at 10ps every sub-nanosecond path rounds to zero and the run is
# silently zero-delay.
ifeq ($(strip $(SDF)),)
  TIMESCALE  := 1ns/10ps
  TIMING_OPT := +nospecify +notimingcheck
  SDF_DEF    :=
else
  TIMESCALE  := 1ns/1ps
  TIMING_OPT := +neg_tchk
  SDF_SCALE  := FROM_$(SDF_CORNER)
  # SDF_CORNER / SDF_INSTANCE are stripped above: trailing whitespace here
  # produces an unterminated string macro and vcs fails to compile the tb.
  SDF_DEF    := +define+SDF_SIM \
                +define+FI_SDF_FILE=\"$(SDF)\" \
                +define+FI_SDF_INSTANCE=$(SDF_INSTANCE) \
                +define+FI_SDF_CORNER=\"$(SDF_CORNER)\" \
                +define+FI_SDF_SCALE=\"$(SDF_SCALE)\"
endif

# ---- waveform -------------------------------------------------------------
# $fsdbDumpfile is a Verdi PLI task, not a VCS built-in: without the novas
# PLI linked in it is silently a no-op and `make wave` produces nothing. Link
# it when VERDI_HOME is set, and fall back to plain VCD otherwise so the
# target still works for someone who has VCS but not Verdi.
VERDI_PLI := $(strip $(VERDI_HOME))/share/PLI/VCS/linux64
ifneq ($(strip $(VERDI_HOME)),)
  ifneq ($(wildcard $(VERDI_PLI)/novas.tab),)
    WAVE_OPT := -P $(VERDI_PLI)/novas.tab $(VERDI_PLI)/libnovas.so +define+FI_FSDB
  endif
endif
WAVE_OPT ?=

# Distinct binaries per configuration, so toggling SDF cannot silently reuse
# the previous build.
BUILD_TAG := $(SIM_TOOL)$(if $(strip $(SDF)),.sdf,)

# ---- tool options ---------------------------------------------------------
ifeq ($(SIM_TOOL),vcs)
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
  EXEC     := $(SIMV) +ntb_random_seed=$(SEED)
endif

# There is deliberately no iverilog branch. A campaign needs host JTAG, host
# JTAG needs the jtagdpi C++ bridge, and iverilog compiles neither the .cc nor
# the `import "DPI-C"` in jtagdpi.sv. Shipping a branch that cannot build is
# worse than not shipping one, so an unknown tool is an error rather than an
# empty BUILD that "succeeds" and does nothing.
#
# iverilog is not useless here -- it runs tests/run.sh, the freeze-gate
# equivalence regression, which is the invariant everything else rests on.
ifneq (,$(filter $(NEEDS_CONFIG),$(ACTIVE_GOALS)))
  ifneq ($(SIM_TOOL),vcs)
    $(error SIM_TOOL=$(SIM_TOOL) is not supported -- the gate-level campaign needs VCS. For a PDK-free check run tests/run.sh instead)
  endif
endif

PLUSARGS  := +firmware=$(FIRMWARE) +DUMPWAVE=$(DUMPWAVE)

.PHONY: all build wave run echo-config clean help
help:
	@echo "make              build and run the campaign simulation"
	@echo "make wave         same, dumping a waveform"
	@echo "make run          re-run without rebuilding"
	@echo "make echo-config  show the resolved configuration"
	@echo "make clean        remove build products"
	@echo
	@echo "Configuration lives in config.mk (copy config.mk.example)."

all: build
	$(EXEC) $(PLUSARGS)

build:
	$(BUILD)

wave:
	$(MAKE) all DUMPWAVE=1

run:
	$(EXEC) $(PLUSARGS)

# Print the resolved configuration. First thing to check when a build fails.
echo-config:
	@echo "SIM_TOOL       = $(SIM_TOOL)"
	@echo "VCS            = $(VCS)"
	@echo "NETLIST        = $(NETLIST)"
	@echo "STDCELL_MODELS = $(STDCELL_MODELS)"
	@echo "UDP_MODELS     = $(UDP_MODELS)"
	@echo "MEM_MODELS     = $(MEM_MODELS)"
	@echo "DEFINES        = $(DEFINES)"
	@echo "SEED           = $(SEED)"
	@echo "SDF            = $(if $(SDF),$(SDF) [$(SDF_CORNER)] into $(SDF_INSTANCE),(none, timing off))"
	@echo "TIMESCALE      = $(TIMESCALE)"
	@echo "FIRMWARE       = $(FIRMWARE)"
	@echo "sources        = $(words $(SRC)) files"

clean:
	rm -rf simv.* csrc ucli.key *.fsdb *.vcd \
	       verdiLog novas.* DVEfiles annotate.log \
	       inst_valid_log.txt uart_*.log
