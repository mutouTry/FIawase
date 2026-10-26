# SPDX-License-Identifier: Apache-2.0
# Copyright 2025-2026 the FIawase authors
# ==========================================================================
# A minimal Design Compiler flow: RTL -> scan-inserted, FI-ready netlist.
#
#     make dc PORT=/path/to/port RUN=/path/to/rundir
#
# PORT holds one DUT's design.tcl, fi_scan_cfg.tcl and SDC; without it, the
# example DUT's (examples/tinyriscv/port). RUN is where dc_shell runs and
# writes WORK/, results/, reports/ and dc_fi.log; without it, this directory.
# SURVEY=1 also writes fi_survey.rpt; SURVEY=only stops after it.
# INPUT_DDC=/path/to/<top>.compiled.ddc starts from an earlier run's mapped
# design instead of the RTL.
#
# DC_SHELL and the libraries come from site.mk at the top of FIawase.
#
# What comes out, in $(RESULTS):
#     <top>.mapped.v        the netlist
#     fi_scanmap.txt        FI_Index -> flop, for picking targets
#     fi_scan_cfg.vh        the wrapper's header; the simulation includes it from here
#     fi_scan_cfg.tcl       the same values for the host (FI_CFG)
#     fi_scan_path.rpt      the report_scan_path the map was parsed from
#     fi_clock_gates.txt    every clock gate on a register's clock path
#
# If you already have a Design Compiler flow, you need nothing in this
# directory: call the steps of ../fi_scan_lib.tcl from it (../README.md).
# ==========================================================================

# tee would otherwise mask dc_shell's exit status.
SHELL       := /bin/bash
.SHELLFLAGS := -o pipefail -c

ROOT      := $(abspath $(CURDIR)/../..)
FI_SITE   ?= $(ROOT)/site.mk
-include $(FI_SITE)

DC_SHELL  ?= dc_shell
PORT      ?= $(ROOT)/examples/tinyriscv/port
RUN       ?= $(CURDIR)
RESULTS   ?= $(RUN)/results
REPORTS   ?= $(RUN)/reports
SURVEY    ?=
INPUT_DDC ?=

# The library settings reach dc_fi.tcl through the environment.
export FI_SEARCH_PATH FI_TARGET_LIBRARY FI_MACRO_LIBRARY \
       FI_BUF_CELL FI_BUF_CELL_PIN FI_IO_CELL FI_IO_CELL_PIN
FI_ENV    := FI_PORT_DIR=$(abspath $(PORT)) FI_SURVEY=$(SURVEY) \
             FI_INPUT_DDC=$(if $(strip $(INPUT_DDC)),$(abspath $(INPUT_DDC)))

.PHONY: dc gui clean help site-check
help:
	@echo "make dc      synthesise, insert the scan chain, check, export"
	@echo "make gui     same, interactive (dc_shell stays open)"
	@echo "make clean   remove results, reports and WORK"

site-check:
	@[ -n "$(strip $(FI_TARGET_LIBRARY))" ] || { \
	   echo "No standard cell library: copy $(ROOT)/site.mk.example to $(FI_SITE) and fill it in."; \
	   exit 1; }

dc: site-check
	mkdir -p $(RUN)
	cd $(RUN) && $(FI_ENV) $(DC_SHELL) -64bit -f $(CURDIR)/dc_fi.tcl 2>&1 | tee dc_fi.log
	@echo
	@grep -E '^(Error: )?FI-(PASS|FAIL|ERROR|WARN)' $(RUN)/dc_fi.log || true
	@! grep -qE '^(Error: )?FI-ERROR' $(RUN)/dc_fi.log || { \
	   echo "make dc: an FIawase step failed (FI-ERROR in dc_fi.log). Do NOT use the netlist."; \
	   exit 1; }
	@[ "$(SURVEY)" = only ] || grep -q '^FI-PASS' $(RUN)/dc_fi.log || { \
	   echo "make dc: no FI-PASS in dc_fi.log -- the invariants did not pass."; \
	   echo "         Do NOT use the netlist. Grep the log for FI-FAIL."; \
	   exit 1; }

# Same, but without the final exit, so you can poke at the design after the
# checks run. dc_fi.tcl ends with `exit`, so strip it for this target.
gui: site-check
	@sed '/^exit$$/d' dc_fi.tcl > .dc_fi_gui.tcl
	mkdir -p $(RUN)
	cd $(RUN) && $(FI_ENV) $(DC_SHELL) -64bit -f $(CURDIR)/.dc_fi_gui.tcl

clean:
	rm -rf $(RESULTS) $(REPORTS) WORK alib-* \
	       dc_fi.log .dc_fi_gui.tcl check_design.rpt \
	       command.log filenames.log default.svf
