#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2025-2026 the FIawase authors
# Equivalence regression for the FI freeze gate. Needs only iverilog.
#
#   ./run.sh
#
# Proves that syn/fi_clk_gate.v masks exactly the same clock
# edges as the scan_en_sync that is in the current netlist, driven by
# the real fi_scan_ctrl over a real rotate-and-restore pass.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

SRC="$HERE/tb_fi_clk_gate.v
     $ROOT/rtl/fi/fi_scan_ctrl.v
     $HERE/scan_en_sync.v
     $ROOT/syn/fi_clk_gate.v"

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
rc=0

# L, FI_INDEX, PASSES
for cfg in "1 0 1" "2 1 1" "3 1 2" "5 2 1" "8 3 2" "17 8 1" "64 32 2" "257 128 1" "4143 2071 1"; do
    set -- $cfg
    iverilog -g2005 -o "$OUT/tb" \
        -Ptb_fi_clk_gate.L=$1 -Ptb_fi_clk_gate.FI_INDEX=$2 -Ptb_fi_clk_gate.PASSES=$3 \
        $SRC
    "$OUT/tb" > "$OUT/log" 2>&1 || true
    grep -E '^L=' "$OUT/log" || cat "$OUT/log"
    grep -qE '\| PASS$' "$OUT/log" || rc=1
done

if [ $rc -eq 0 ]; then echo "ALL PASS"; else echo "*** SOME FAILED ***"; fi
exit $rc
