# SPDX-License-Identifier: Apache-2.0
# Copyright 2025-2026 the FIawase authors
"""Trace the clock of every register, latch and memory of a netlist back to a top-level clock
port, and classify what sits on the way: buffers, inverters, clock gates.

A clock gate is either a library integrated clock gate (Q = CP & latch(E | TE)) or a
two-input gate whose other input is a latch that is transparent while the clock is low
(an RTL latch gate, or the FIawase freeze gate and freeze cells, which are built the same
way). On an FPGA each gate becomes a clock enable on what it drives:
  icg     CE = E | TE
  latch   CE = the latch's D, inverted if the gate inverts the latch output
Gates in series multiply. Anything else on a clock path is reported, not guessed. Which cells are
gates, latches, buffers and inverters, and their pins, comes from a description of the library
(cells.py).

usage: clocktrace.py <netlist.v> <top> <cells.py> <cell models.v> ...
"""
import importlib.util
import re
import sys
from collections import Counter, defaultdict

import vnet


def load_cells(path):
    """The library description: cells.py, or a file of the same form."""
    spec = importlib.util.spec_from_file_location('cells', path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def first_pin(names, dirs):
    """The first of names the cell has (the last one if it has none)."""
    return next((p for p in names if p in dirs), names[-1])


def role(cell, dirs, cells):
    """What a leaf cell is, from its name and pins."""
    ins = sorted(p for p, d in dirs.items() if d == 'input')
    outs = sorted(p for p, d in dirs.items() if d == 'output')
    b = cells.base(cell)
    if re.match(cells.ICG, b):
        return 'icg'
    if cells.ICG_NEG and re.match(cells.ICG_NEG, b):
        return 'icg_n'
    if any(p in ins for p in cells.FLOP_CLOCKS) and cells.Q in outs:
        return 'flop'
    if re.match(cells.LATCH, b) and cells.Q in outs:
        return 'latch'
    if ins == list(cells.BUF[0]) and outs == list(cells.BUF[1]):
        return 'buf'
    if ins == list(cells.INV[0]) and outs == list(cells.INV[1]):
        return 'inv'
    if b in cells.GATE2:
        return 'gate2'
    if re.match(cells.MACRO, cell):
        return 'macro'
    return 'comb'


class Trace:
    def __init__(self, netlist, top, models, cells):
        self.cells = cells
        self.mods, _ = vnet.parse(netlist)
        self.f = vnet.Flat(self.mods, top, vnet.read_cell_dirs(models))
        f = self.f
        self.role = {}
        for li, (path, inst, owner) in enumerate(f.leaves):
            d = f.mods[inst.cell].dirs if inst.cell in f.blackbox else f.cell_dirs[inst.cell]
            self.role[li] = 'blackbox' if inst.cell in f.blackbox else role(inst.cell, d, cells)
        # driver of each net: (leaf index, pin) or ('port', name) or ('const', v)
        self.driver = {}
        for r, pins in f.pins.items():
            for li, pin, d in pins:
                if d == 'output':
                    if r in self.driver:
                        raise ValueError(f'two drivers on {r}')
                    self.driver[r] = (li, pin)
        topmod = f.mods[top]
        for p, d in topmod.dirs.items():
            if d == 'input':
                for b in vnet.port_bits(topmod, p):
                    r = f.find(f.key('', b))
                    self.driver.setdefault(r, ('port', b))
        for r, v in f.const.items():
            self.driver.setdefault(f.find(r), ('const', v))
        self.memo = {}

    def leaf_name(self, li):
        path, inst, _ = self.f.leaves[li]
        return f'{path}/{inst.name}' if path else inst.name

    def pin_net(self, li, pin):
        path, inst, owner = self.f.leaves[li]
        e = inst.conns.get(pin, '')
        bits = vnet.expr_bits(e, self.f.mods[owner].width)
        if len(bits) != 1:
            return None
        return self.f.find(self.f.key(path, bits[0]))

    def clock_of(self, r):
        """(root port, inverted, [gates]) for net r, or ('?', reason) if it is not a clock
        derived from a port through buffers, inverters and gates. A gate is
        (kind, leaf index, enable description)."""
        if r in self.memo:
            return self.memo[r]
        self.memo[r] = ('?', 'loop')
        drv = self.driver.get(r)
        if drv is None:
            res = ('?', 'undriven')
        elif drv[0] == 'port':
            res = (drv[1], False, [])
        elif drv[0] == 'const':
            res = ('?', 'constant ' + drv[1])
        else:
            li, pin = drv
            ro = self.role[li]
            cell = self.f.leaves[li][1].cell
            if ro in ('buf', 'inv'):
                up = self.clock_of(self.pin_net(li, (self.cells.BUF if ro == 'buf' else self.cells.INV)[0][0]))
                res = up if up[0] == '?' else (up[0], up[1] ^ (ro == 'inv'), up[2])
            elif ro == 'icg':
                up = self.clock_of(self.pin_net(li, self.cells.ICG_CLOCK))
                res = up if up[0] == '?' else (up[0], up[1], up[2] + [('icg', li, None)])
            elif ro == 'gate2':
                res = self._gate2(li, cell)
            else:
                res = ('?', f'driven by {ro} {cell} {self.leaf_name(li)}.{pin}')
        self.memo[r] = res
        return res

    def _gate2(self, li, cell):
        (pa, pb), fn = self.cells.GATE2[self.cells.base(cell)]
        na, nb = self.pin_net(li, pa), self.pin_net(li, pb)
        for clk_pin, clk_net, oth_pin, oth_net, ck_first in ((pa, na, pb, nb, True), (pb, nb, pa, na, False)):
            d = self.driver.get(oth_net)
            if not d or d[0] in ('port', 'const') or self.role[d[0]] != 'latch':
                continue
            lat = d[0]
            lcell = self.f.leaves[lat][1].cell
            ldirs = self.f.cell_dirs[lcell]
            en_pin = first_pin(self.cells.LATCH_ENABLES, ldirs)
            active_low = bool(re.match(self.cells.LATCH_LOW, self.cells.base(lcell)))
            up = self.clock_of(clk_net)
            if up[0] == '?':
                continue
            lup = self.clock_of(self.pin_net(lat, en_pin))
            if lup[0] != up[0]:
                continue
            # the latch must be transparent while this gate's clock input is low
            clk_low_open = (lup[1] == up[1]) == active_low
            if not clk_low_open:
                return ('?', f'latch {self.leaf_name(lat)} open while the clock is high')
            f = (lambda c, x: fn(c, x)) if ck_first else (lambda c, x: fn(x, c))
            # an edge passes iff out goes 0 -> 1 with the clock (non-inverting gate) or
            # 1 -> 0 (inverting gate); the gate is static while the clock is low
            if f(0, 0) == f(0, 1) == 0 and (f(1, 0), f(1, 1)) in ((0, 1), (1, 0)):
                inv_x = f(1, 1) == 0
                return (up[0], up[1], up[2] + [('latch', li, (lat, inv_x, clk_pin))])
            if f(0, 0) == f(0, 1) == 1 and (f(1, 0), f(1, 1)) in ((0, 1), (1, 0)):
                inv_x = f(1, 0) == 0
                return (up[0], not up[1], up[2] + [('latch', li, (lat, inv_x, clk_pin))])
            return ('?', f'gate {cell} {self.leaf_name(li)} is not an AND-type gate')
        return ('?', f'2-input cell {cell} {self.leaf_name(li)} on a clock path without a gating latch')

    def sinks(self):
        """Every clock pin of a register, latch, ICG, memory or black box."""
        out = []
        for li, (path, inst, owner) in enumerate(self.f.leaves):
            ro = self.role[li]
            d = self.f.cell_dirs.get(inst.cell, {})
            if ro == 'flop':
                out.append((li, first_pin(self.cells.FLOP_CLOCKS, d), ro))
            elif ro == 'latch':
                out.append((li, first_pin(self.cells.LATCH_ENABLES, d), ro))
            elif ro == 'macro':
                out.append((li, self.cells.MACRO_CLOCK, ro))
            elif ro == 'blackbox':
                for pin in inst.conns:
                    if re.search(r'clk|clock', pin, re.I) and self.f.mods[inst.cell].dirs.get(pin) == 'input':
                        out.append((li, pin, ro))
        return out


def main():
    netlist, top, cells = sys.argv[1], sys.argv[2], load_cells(sys.argv[3])
    models = sys.argv[4:]
    t = Trace(netlist, top, models, cells)
    sinks = t.sinks()
    by = Counter()
    bad = defaultdict(list)
    gates = Counter()
    gate_regs = Counter()
    for li, pin, ro in sinks:
        r = t.pin_net(li, pin)
        c = t.clock_of(r) if r else ('?', 'unconnected')
        cell = t.f.leaves[li][1].cell
        if c[0] == '?':
            # latches inside clock gates are part of the gate
            bad[c[1]].append(f'{ro} {cell} {t.leaf_name(li)}.{pin}')
            continue
        chain = '+'.join(g[0] for g in c[2]) or 'none'
        by[(c[0], 'inv' if c[1] else 'pos', ro, pin, chain)] += 1
        for g in c[2]:
            gates[(g[0], t.leaf_name(g[1]))] += 0
            gate_regs[(g[0], t.leaf_name(g[1]))] += 1
    print('== clock sinks by root, polarity, kind, pin, gates in series')
    for k, n in sorted(by.items(), key=lambda x: (-x[1], x[0])):
        print(f'{n:7d}  ' + '  '.join(map(str, k)))
    print('== gates:', Counter(k for k, _ in gate_regs))
    print('== sinks not traced to a port (%d kinds)' % len(bad))
    for reason, items in sorted(bad.items(), key=lambda x: -len(x[1])):
        print(f'{len(items):6d}  {reason}')
        for s in items[:4]:
            print('          ', s)


if __name__ == '__main__':
    main()
