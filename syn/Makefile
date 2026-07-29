# SPDX-License-Identifier: Apache-2.0
# Copyright 2025-2026 the FIawase authors
# ==========================================================================
# Synthesis: RTL -> scan-inserted, FI-ready netlist.
#
#     cp tool_config.tcl.example tool_config.tcl   # then edit it
#     make dc
#
# What comes out, in $(RESULTS):
#     <top>.mapped.v        the netlist -- point sim/config.mk NETLIST at it
#     fi_scanmap.txt        FI_Index -> flop, for picking targets
#     fi_scan_cfg.vh        copy over rtl/fi/fi_scan_cfg.vh
#     fi_scan_cfg.tcl       the same numbers for host/tapename.tcl
#     fi_scan_path.rpt      the report_scan_path the map was parsed from
#
# Those four move TOGETHER with the netlist. A CFG_SCAN_LEN that does not
# match the netlist means the chain is never restored and the DUT dies on
# the first injection -- `make sync-check` below is the cheap guard.
#
# If you already have a Design Compiler flow, you do not need this Makefile
# or dc_fi.tcl: source scanchain.tcl into your own session instead. See
# "Two ways in" in README.md.
# ==========================================================================

# tee would otherwise mask dc_shell's exit status.
SHELL       := /bin/bash
.SHELLFLAGS := -o pipefail -c

# How to invoke Design Compiler. Leave as `dc_shell` when it is on PATH. This
# is a command prefix, not just a path, so anything that ends up exec'ing
# dc_shell works -- a container, a module wrapper, an absolute path:
#     make dc DC_SHELL='singularity exec /path/to/syn.sif dc_shell'
# `?=` also honours the environment, so `export DC_SHELL=...` in your shell
# profile does the same thing. Everything else -- libraries, RTL, SDC -- goes
# in tool_config.tcl, which dc_shell reads for itself.
DC_SHELL ?= dc_shell
RESULTS  ?= ./results
REPORTS  ?= ./reports
ROOT     := $(abspath $(CURDIR)/..)

.PHONY: dc gui sync-check clean help
help:
	@echo "make dc          synthesise + insert scan + assert + export"
	@echo "make gui         same, interactive (dc_shell stays open)"
	@echo "make sync-check  verify the netlist, the RTL header and the host"
	@echo "                 script agree on the chain length"
	@echo "make clean       remove results, reports and WORK"

tool_config.tcl:
	@echo "tool_config.tcl is missing. Start from the template:"
	@echo "    cp tool_config.tcl.example tool_config.tcl"
	@false

dc: tool_config.tcl
	$(DC_SHELL) -64bit -f ./dc_fi.tcl 2>&1 | tee dc_fi.log
	@echo
	@grep -E 'FI-(PASS|FAIL|ERROR|WARN)' dc_fi.log || true
	@grep -q 'FI-PASS' dc_fi.log || { \
	   echo "make dc: no FI-PASS in dc_fi.log -- the invariants did not pass."; \
	   echo "         Do NOT use the netlist. Grep the log for FI-FAIL."; \
	   exit 1; }

# Same, but without the final exit, so you can poke at the design after the
# assertions run. dc_fi.tcl ends with `exit`, so strip it for this target.
gui: tool_config.tcl
	@sed '/^exit$$/d' dc_fi.tcl > .dc_fi_gui.tcl
	$(DC_SHELL) -64bit -f ./.dc_fi_gui.tcl

# ---- the three-file sync guard -------------------------------------------
# fi_export_scanmap writes results/fi_scan_cfg.{vh,tcl}. Those have to be
# copied into rtl/fi/ and host/ before the simulation and the host script
# will agree with the netlist. This target says whether they currently do.
sync-check:
	@syn=$$(sed -n 's/^`define FI_SCAN_LEN *\([0-9]*\).*/\1/p' $(RESULTS)/fi_scan_cfg.vh 2>/dev/null); \
	 rtl=$$(sed -n 's/^`define FI_SCAN_LEN *\([0-9]*\).*/\1/p' $(ROOT)/rtl/fi/fi_scan_cfg.vh 2>/dev/null); \
	 hst=$$(sed -n 's/^set FI_SCAN_LEN *\([0-9]*\).*/\1/p'     $(ROOT)/host/tapename.tcl 2>/dev/null); \
	 echo "  synthesis  $(RESULTS)/fi_scan_cfg.vh : $${syn:-<not built>}"; \
	 echo "  rtl        rtl/fi/fi_scan_cfg.vh     : $${rtl:-<missing>}"; \
	 echo "  host       host/tapename.tcl         : $${hst:-<missing>}"; \
	 if [ -z "$$syn" ]; then \
	   echo "  -> nothing to compare against yet; run 'make dc' first"; \
	 elif [ "$$syn" = "$$rtl" ] && [ "$$syn" = "$$hst" ]; then \
	   echo "  -> IN SYNC"; \
	 else \
	   echo "  -> OUT OF SYNC. Copy the generated files over:"; \
	   echo "       cp $(RESULTS)/fi_scan_cfg.vh  $(ROOT)/rtl/fi/"; \
	   echo "       then update FI_SCAN_LEN in $(ROOT)/host/tapename.tcl"; \
	   exit 1; \
	 fi

clean:
	rm -rf $(RESULTS) $(REPORTS) WORK alib-* \
	       dc_fi.log .dc_fi_gui.tcl check_design.rpt \
	       command.log filenames.log default.svf
