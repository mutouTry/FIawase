# SPDX-License-Identifier: Apache-2.0
# Copyright 2025-2026 the FIawase authors
"""The standard-cell library as clocktrace.py and fi_fpga_ce.py see it: which cells are clock gates,
latches, flops, buffers and inverters, and their pin names. The values here are an illustration with
generic names: write this file for your library and pass it with --cells.
"""
import re


def base(cell):
    """A cell's function name, without drive strength or library suffix: AND2_X1 -> AND2."""
    return re.sub(r'_X\d+$', '', cell)


ICG = r'ICGP'                # integrated clock gate, Q = CP & latch(E | TE): base-name pattern (re.match)
ICG_NEG = r'ICGN'            # its negative-edge form, reported but not converted (None if there is none)
ICG_CLOCK = 'CP'
ICG_ENABLES = ('E', 'TE')
FLOP_CLOCKS = ('CP', 'CPN')  # a cell with one of these inputs and the output Q is a flop
Q = 'Q'
LATCH = r'LAT'               # latches: base-name pattern
LATCH_LOW = r'LATN'          # the latches whose enable is active low
LATCH_ENABLES = ('EN', 'E')  # the latch's enable pin: the first of these it has
LATCH_D = 'D'
BUF = (('I',), ('Z',))       # (inputs, outputs) of a buffer
INV = (('I',), ('ZN',))      # (inputs, outputs) of an inverter
# two-input cells that can gate a clock: base name -> ((pin a, pin b), the function of (a, b))
GATE2 = {
    'AND2':  (('A1', 'A2'), lambda a, b: a & b),
    'ANDN2': (('A1', 'B1'), lambda a, b: a & (1 - b)),
    'NAND2': (('A1', 'A2'), lambda a, b: 1 - (a & b)),
    'NOR2':  (('A1', 'A2'), lambda a, b: 1 - (a | b)),
    'OR2':   (('A1', 'A2'), lambda a, b: a | b),
}
MACRO = r'sram_'             # memory macros: cell-name pattern
MACRO_CLOCK = 'clk'
