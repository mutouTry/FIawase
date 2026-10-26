#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2025-2026 the FIawase authors
# Regressions for the wrapper's timing-critical pieces. Needs only iverilog.
#
#   ./run.sh
#
#   tb_fi_clk_gate      syn/fi_clk_gate.v masks exactly the clock edges of the
#                       reference scan_en_sync.v, driven by the real
#                       fi_scan_ctrl over a rotate-and-restore pass
#   tb_fi_scrub         the scrub of fi_scan_ctrl shifts SCRUB_LEN cells
#   tb_fi_obs           fi_uart_obs and fi_slow_clk keep the DUT's time
#                       across scan windows
#   tb_fi_sram_restore  rtl/fi_sram_restore.vh puts a memory back
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

SRC="$HERE/tb_fi_clk_gate.v
     $ROOT/rtl/fi_scan_ctrl.v
     $HERE/scan_en_sync.v
     $ROOT/syn/fi_clk_gate.v"

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
rc=0

# simulate $OUT/tb; show the lines matching $1; no "| PASS" fails the run
run() {
    "$OUT/tb" > "$OUT/log" 2>&1 < /dev/null || true
    grep -E "$1" "$OUT/log" || cat "$OUT/log"
    grep -qE '\| PASS$' "$OUT/log" || rc=1
}

# L, FI_INDEX, PASSES
for cfg in "1 0 1" "2 1 1" "3 1 2" "5 2 1" "8 3 2" "8 8 1" "17 8 1" "64 32 2" "257 128 1" "4143 2071 1"; do
    set -- $cfg
    iverilog -g2005 -o "$OUT/tb" \
        -Ptb_fi_clk_gate.L=$1 -Ptb_fi_clk_gate.FI_INDEX=$2 -Ptb_fi_clk_gate.PASSES=$3 \
        $SRC
    run '^L='
done

# Scrub length (fi_scan_ctrl SCRUB_LEN): L, SCRUB_LEN, FI_INDEX
for cfg in "2 1 1" "8 3 2" "8 0 5" "8 8 7" "8 20 0" "8 -1 3" "17 9 16" "4143 992 2071" "4143 0 0"; do
    set -- $cfg
    iverilog -g2005 -o "$OUT/tb" \
        -Ptb_fi_scrub.L=$1 -Ptb_fi_scrub.SCRUB_LEN=$2 -Ptb_fi_scrub.FI_INDEX=$3 \
        "$HERE/tb_fi_scrub.v" "$ROOT/rtl/fi_scan_ctrl.v"
    run '^(L=|FAIL)'
done

# The DUT's time on the wrapper side: L, UART bit period, slow clock period
for cfg in "37 5 16" "1 3 4" "300 16 16"; do
    set -- $cfg
    iverilog -g2005 -o "$OUT/tb" \
        -Ptb_fi_obs.L=$1 -Ptb_fi_obs.CPB=$2 -Ptb_fi_obs.DIV=$3 \
        "$HERE/tb_fi_obs.v" "$ROOT/rtl/fi_scan_ctrl.v" "$ROOT/syn/fi_clk_gate.v" \
        "$ROOT/rtl/fi_uart_obs.v" "$ROOT/rtl/fi_slow_clk.v"
    run '^(L=|FAIL)'
done

# Memory restore: 0 = UNDO, 1 = FILL
for kind in 0 1; do
    iverilog -g2005 -I "$ROOT/rtl" -o "$OUT/tb" \
        -Ptb_fi_sram_restore.KIND=$kind "$HERE/tb_fi_sram_restore.v"
    run '^(kind=|FAIL)'
done

if [ $rc -eq 0 ]; then echo "ALL PASS"; else echo "*** SOME FAILED ***"; fi
exit $rc
