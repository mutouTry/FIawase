#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2025-2026 the FIawase authors
"""Turn the clock gates of a netlist into clock enables, for an FPGA.

Every clock gate (library ICG, RTL latch gate, the FIawase freeze gate and freeze cells; see
clocktrace.py) stops gating: its output net is driven by its input clock instead, and the
condition under which it passed an edge travels next to the clock as an enable net, named
<clock net>__fien. Gates in series multiply. Each flop behind a gate becomes <cell>_FICE with
FICE = that enable; each memory or black box behind a gate gets fi_ce_i. A module port that
carries a gated clock gets a companion port <port>__fien. Nothing else changes, so the netlist
keeps its hierarchy, its names and its scan chain.

Memories also get the FI restore wires (fi_restore_i in, fi_done_o / fi_abort_o / fi_bad_o out),
brought up to the top as fi_mem_restore_i and fi_mem<k>_{done,abort,bad}_o. A Verilog snippet
(--glue) combines them for the wrapper.

--observe <net>=<port> brings a net of the top module out as an output port, for an observer
outside the netlist that the simulation reads by hierarchical name (e.g. a UART's TX before the
pin mux).

The library's cells (clock gates, latches, buffers and their pins) are described in --cells, a file of
the form of cells.py next to this script (which is an illustration). <cell>_FICE, the flop with a clock
enable, is a model you supply with the cell models for the FPGA build.

usage: fi_fpga_ce.py <netlist.v> <top> --models <cell lib> [<memory models> ...] --cells <cells.py>
                     --out <converted.v> [--glue <glue.vh>] [--mem-cell <cell> ...]
                     [--drop-module <module> ...] [--observe <net>=<port> ...]
"""
import argparse
import re
import sys
from collections import Counter, defaultdict

import clocktrace
import vnet


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('netlist')
    ap.add_argument('top')
    ap.add_argument('--models', nargs='+', required=True)
    ap.add_argument('--cells', required=True, help='the library description (the form of cells.py)')
    ap.add_argument('--out', required=True)
    ap.add_argument('--glue')
    ap.add_argument('--mem-cell', nargs='*', default=[], help='memory cells or black boxes that get the restore wires')
    ap.add_argument('--drop-module', nargs='*', default=[], help='module definitions the FPGA build supplies instead')
    ap.add_argument('--observe', nargs='*', default=[], help='<net>=<port>: a net of the top module, out as a port')
    args = ap.parse_args()

    cells = clocktrace.load_cells(args.cells)
    t = clocktrace.Trace(args.netlist, args.top, args.models, cells)
    f, mods = t.f, t.mods
    path_mod = {'': args.top}
    _paths(mods, args.top, '', path_mod)

    # ---- the gated clock nets and the gates
    sinks = t.sinks()
    for li, pin, ro in sinks:
        r = t.pin_net(li, pin)
        if r is not None:
            t.clock_of(r)
    gn = {r: v for r, v in t.memo.items() if v[0] != '?' and v[2]}
    gates = {}
    for v in gn.values():
        for g in v[2]:
            gates[g[1]] = g
    if not gn:
        print('no clock gates: nothing to convert')

    # local names of every gated net, per module path
    local = defaultdict(list)          # (path, r) -> [local names]
    for path, mname in path_mod.items():
        mod = mods[mname]
        names = set(mod.ports) | set(mod.width) | set(mod.dirs)
        for inst in mod.insts:
            for e in inst.conns.values():
                names.update(_idents(e))
        for lhs, rhs in mod.assigns:
            names.update(_idents(lhs + ' ' + rhs))
        for n in names:
            if n in mod.width:
                continue                                   # buses never carry a clock here
            k = f'{path}/{n}'
            if k not in f.parent:
                continue
            r = f.find(k)
            if r in gn:
                local[(path, r)].append(n)

    def owner_path(li):
        return f.leaves[li][0]

    def relation(path, r):
        d = t.driver[r]
        pd = owner_path(d[0])
        if pd == path:
            return 'local'
        if (path == '' and pd != '') or pd.startswith(path + '/'):
            return 'child'
        return 'parent'

    canon = {}
    for (path, r), names in local.items():
        mod = mods[path_mod[path]]
        rel = relation(path, r)
        ins = sorted(n for n in names if mod.dirs.get(n) == 'input')
        outs = sorted(n for n in names if mod.dirs.get(n) == 'output')
        if rel == 'parent':
            if not ins:
                sys.exit(f'{path or args.top}: gated clock {names} enters without an input port')
            canon[(path, r)] = ins[0]
        else:
            canon[(path, r)] = outs[0] if outs else sorted(names)[0]

    def fien(path, r):
        return canon[(path, r)] + '__fien'

    # ---- edits, per module
    new_ports = defaultdict(list)      # mname -> [(dir, name)]
    new_wires = defaultdict(list)
    new_assigns = defaultdict(list)
    inst_edit = defaultdict(dict)      # mname -> {inst name: (new cell, {pin: expr} additions, {pin: expr} replacements)}
    dead = Counter()

    def edit(mname, iname, cell=None, add=None, repl=None):
        e = inst_edit[mname].setdefault(iname, [None, {}, {}])
        if cell:
            e[0] = cell
        if add:
            e[1].update(add)
        if repl:
            e[2].update(repl)

    for (path, r), names in sorted(local.items()):
        mname = path_mod[path]
        mod = mods[mname]
        c = canon[(path, r)]
        for n in names:
            dr = mod.dirs.get(n)
            if dr in ('input', 'output'):
                new_ports[mname].append((dr, n + '__fien'))
                if dr == 'output' and n != c:
                    new_assigns[mname].append(f'{n}__fien = {c}__fien')
        if mod.dirs.get(c) is None:
            new_wires[mname].append(c + '__fien')
        if relation(path, r) == 'local':
            li, pin = t.driver[r]
            inst = f.leaves[li][1]
            ro = t.role[li]
            if li in gates:
                kind, _, info = gates[li]
                if kind == 'icg':
                    in_pin = cells.ICG_CLOCK
                    en = '(' + ' | '.join(inst.conns[p] for p in cells.ICG_ENABLES) + ')'
                else:
                    lat, inv_x, in_pin = info
                    lpath, linst, lowner = f.leaves[lat]
                    if lpath != path:
                        sys.exit(f'gate {t.leaf_name(li)}: its latch is in another module')
                    en = ('~' if inv_x else '') + linst.conns[cells.LATCH_D]
                r_in = t.pin_net(li, in_pin)
                expr = f'{fien(path, r_in)} & {en}' if r_in in gn else en
                new_assigns[mname].append(f'{c}__fien = {expr}')
                # the gate stops gating: its output follows its input clock
                k = sum(dead.values())
                dead[mname] += 1
                dn = f'fi_ce_dead_{k}'
                new_wires[mname].append(dn)
                edit(mname, inst.name, repl={pin: dn})
                new_assigns[mname].append(f'{inst.conns[pin]} = {inst.conns[in_pin]}')
            elif ro in ('buf', 'inv'):
                r_in = t.pin_net(li, (cells.BUF if ro == 'buf' else cells.INV)[0][0])
                new_assigns[mname].append(f'{c}__fien = {fien(path, r_in)}')
            else:
                sys.exit(f'{t.leaf_name(li)}: unexpected driver of a gated clock ({ro})')

    # child instance connections
    for path, mname in path_mod.items():
        mod = mods[mname]
        for inst in mod.insts:
            if inst.cell not in mods or inst.cell in f.blackbox:
                continue
            for pin, e in inst.conns.items():
                bits = vnet.expr_bits(e, mod.width)
                if len(bits) != 1 or bits[0] in ('0', '1'):
                    continue
                r = f.find(f.key(path, bits[0]))
                if r in gn:
                    edit(mname, inst.name, add={pin + '__fien': fien(path, r)})

    # sinks
    count = Counter()
    for li, pin, ro in sinks:
        path, inst, owner = f.leaves[li]
        r = t.pin_net(li, pin)
        if ro == 'macro' or (ro == 'blackbox' and inst.cell in args.mem_cell):
            edit(owner, inst.name, add={'fi_ce_i': fien(path, r) if r in gn else "1'b1"})
            count[f'{ro} fi_ce_i' + (' gated' if r in gn else ' free')] += 1
            continue
        if r not in gn:
            continue
        if ro == 'flop':
            edit(owner, inst.name, cell=inst.cell + '_FICE', add={'FICE': fien(path, r)})
            count[f'flop {inst.cell}'] += 1
        elif ro == 'latch':
            q = t.pin_net(li, cells.Q)
            loads = [(l, p) for l, p, d in f.pins.get(q, []) if d == 'input']
            if not all(l in gates for l, p in loads):
                sys.exit(f'latch {t.leaf_name(li)} on a gated clock drives more than clock gates')
            count['gate latch (left in place)'] += 1
        elif ro == 'blackbox':
            sys.exit(f'black box {t.leaf_name(li)}.{pin} on a gated clock is not a listed memory')
        else:
            sys.exit(f'{t.leaf_name(li)}: unexpected clock sink {ro}')

    # ---- memory restore wires, brought up to the top
    mems = sorted((f'{path}/{inst.name}' if path else inst.name, li)
                  for li, (path, inst, owner) in enumerate(f.leaves)
                  if inst.cell in args.mem_cell)
    glue = []
    for k, (mpath, li) in enumerate(mems):
        path, inst, owner = f.leaves[li]
        sig = {'fi_restore_i': 'fi_mem_restore_i', 'fi_done_o': f'fi_mem{k}_done_o',
               'fi_abort_o': f'fi_mem{k}_abort_o', 'fi_bad_o': f'fi_mem{k}_bad_o'}
        edit(owner, inst.name, add=dict(sig))
        # every module from the memory's owner up to the top passes the wires on
        hier = path.split('/') if path else []
        for depth in range(len(hier), -1, -1):
            p = '/'.join(hier[:depth])
            mname = path_mod[p]
            for port, s in sig.items():
                dr = 'input' if port == 'fi_restore_i' else 'output'
                if (dr, s) not in new_ports[mname]:
                    new_ports[mname].append((dr, s))
            if depth > 0:
                parent = '/'.join(hier[:depth - 1])
                edit(path_mod[parent], hier[depth - 1], add={s: s for s in sig.values()})
        glue.append((mpath, k))

    # ---- observation points: a net of the top module, out as a plain output port
    top = mods[args.top]
    for spec in args.observe:
        net, _, port = spec.partition('=')
        m = re.fullmatch(r'([A-Za-z_]\w*)(\[\d+\])?', net)
        if not port or not m:
            sys.exit(f'--observe {spec}: expected <net>[<bit>]=<port>')
        if not re.search(r'\b' + m.group(1) + r'\b', top.text):
            sys.exit(f'--observe {spec}: {args.top} has no net {m.group(1)}')
        if port in top.ports or port in top.dirs:
            sys.exit(f'--observe {spec}: {args.top} already has a port {port}')
        new_ports[args.top].append(('output', port))
        new_assigns[args.top].append(f'{port} = {net}')

    # ---- write
    text = []
    for mname, mod in mods.items():
        if mname in args.drop_module:
            continue
        ports = mod.ports + [n for d, n in new_ports[mname] if n not in mod.ports]
        body = mod.text
        reps = []
        for inst in mod.insts:
            e = inst_edit[mname].get(inst.name)
            if not e:
                continue
            cell = e[0] or inst.cell
            conns = dict(inst.conns)
            conns.update(e[2])
            conns.update(e[1])
            s = f'\n  {cell} {inst.name} ( ' + ', '.join(f'.{p}({x})' for p, x in conns.items()) + ' )'
            reps.append((inst.start, inst.end, s))
        for s0, s1, s in sorted(reps, reverse=True):
            body = body[:s0] + s + body[s1:]
        decl = ''
        for d, n in new_ports[mname]:
            if n not in mod.dirs:
                decl += f'\n  {d} {n};'
        for n in dict.fromkeys(new_wires[mname]):
            decl += f'\n  wire {n};'
        tail = ''.join(f'\n  assign {a};' for a in new_assigns[mname])
        text.append(f'module {mname} ( ' + ', '.join(ports) + ' );' + decl + body + tail + '\nendmodule\n')
    open(args.out, 'w').write(
        '// GENERATED by fpga/tools/fi_fpga_ce.py from ' + args.netlist + '\n'
        '// clock gates turned into clock enables (<net>__fien, <cell>_FICE, fi_ce_i)\n\n' + '\n'.join(text))

    if args.glue:
        # for the includer: wires fi_mem_req (in), fi_mem_done / fi_mem_abort / fi_mem_bad
        # (declared by it), and `FI_MEM_PORTS for the DUT instance's port list
        g = ["// GENERATED by fpga/tools/fi_fpga_ce.py: the DUT memories' restore wires",
             '// ' + ', '.join(f'fi_mem{k} = {p}' for p, k in glue)]
        n = len(glue)
        for k in range(n):
            g.append(f'wire fi_mem{k}_done_o, fi_mem{k}_abort_o, fi_mem{k}_bad_o;')
        if n:
            g.append('assign fi_mem_done  = ' + ' & '.join(f'fi_mem{k}_done_o' for k in range(n)) + ';')
            g.append('assign fi_mem_abort = ' + ' | '.join(f'fi_mem{k}_abort_o' for k in range(n)) + ';')
            g.append('assign fi_mem_bad   = ' + ' | '.join(f'fi_mem{k}_bad_o' for k in range(n)) + ';')
            ports = ['.fi_mem_restore_i(fi_mem_req)'] + [
                f'.fi_mem{k}_{s}_o(fi_mem{k}_{s}_o)' for k in range(n) for s in ('done', 'abort', 'bad')]
            g.append('`define FI_MEM_PORTS ' + ', '.join(ports))
        else:
            g += ['assign fi_mem_done = 1\'b1;', 'assign fi_mem_abort = 1\'b0;', 'assign fi_mem_bad = 1\'b0;',
                  '`define FI_MEM_PORTS']
        open(args.glue, 'w').write('\n'.join(g) + '\n')

    kinds = Counter(g[0] for g in gates.values())
    print(f'gates turned into enables: {dict(kinds)}; gated nets {len(gn)}; dead gate outputs {sum(dead.values())}')
    for k, v in sorted(count.items()):
        print(f'  {v:6d}  {k}')
    print(f'memories with restore wires: {[p for p, k in glue]}')
    if args.observe:
        print(f'observed: {args.observe}')
    print(f"new ports: {sum(len(v) for v in new_ports.values())} in {sum(1 for v in new_ports.values() if v)} modules")


def _idents(e):
    """Scalar net names in an expression (no constants, no indexed bus bits)."""
    e = re.sub(r"\d+'[bBhHdD][0-9a-fA-FxXzZ_]+", ' ', e)
    return re.findall(r'\b([A-Za-z_]\w*)\b(?!\s*\[)', e)


def _paths(mods, mname, path, out):
    for inst in mods[mname].insts:
        if inst.cell in mods and (mods[inst.cell].insts or mods[inst.cell].assigns):
            p = f'{path}/{inst.name}' if path else inst.name
            out[p] = inst.cell
            _paths(mods, inst.cell, p, out)


if __name__ == '__main__':
    main()
