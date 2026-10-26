#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2025-2026 the FIawase authors
# Load a bitstream (Vivado 2022.2 hardware manager; programming needs no license), then stop the
# hw_server it started so OpenOCD can open the FT2232H.
# usage: program.sh <file.bit>
set -e
VIVADO=${VIVADO:-vivado}
bit=$(readlink -f "$1")
cd "$(mktemp -d)"
$VIVADO -mode batch -nojournal -nolog -source "$(dirname "$(readlink -f "$0")")/program.tcl" -tclargs "$bit" | grep -E '^(TARGET|PROGRAMMED|ERROR)' || true
for p in $(pgrep -u "$USER" -x hw_server); do kill "$p"; done
echo "hw_server stopped"
