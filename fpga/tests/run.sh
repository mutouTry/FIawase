#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2025-2026 the FIawase authors
# Unit tests of fpga/rtl/fi_board_uart.v. Needs only iverilog.
#
#   tb_fi_board_uart       every trial's record and bytes reach the host line intact while the
#                          FIFO pointers wrap
#   tb_fi_board_uart_prop  at every cycle: no false full, no overflow, the line carries exactly
#                          the pushed bytes (random traffic, seeds 1 2 3)
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
RTL="$HERE/../rtl/fi_board_uart.v"
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
rc=0

iverilog -g2005 -o "$OUT/tb" "$HERE/tb_fi_board_uart.v" "$RTL"
"$OUT/tb" > "$OUT/log" 2>&1 < /dev/null || true
grep -E '^(PASS|FAIL)' "$OUT/log" || cat "$OUT/log"
grep -q '^PASS' "$OUT/log" || rc=1

iverilog -g2005 -o "$OUT/tb" "$HERE/tb_fi_board_uart_prop.v" "$RTL"
for s in 1 2 3; do
    "$OUT/tb" +SEED=$s > "$OUT/log" 2>&1 < /dev/null || true
    echo "seed $s: $(grep -E 'PROPERTY (PASS|FAIL)' "$OUT/log" || tail -1 "$OUT/log")"
    grep -q 'PROPERTY PASS' "$OUT/log" || rc=1
done

if [ $rc -eq 0 ]; then echo "ALL PASS"; else echo "*** SOME FAILED ***"; fi
exit $rc
