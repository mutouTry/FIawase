# SPDX-License-Identifier: Apache-2.0
# Copyright 2025-2026 the FIawase authors
"""Read a structural Verilog netlist (as Design Compiler writes it) into modules, and connect
it bit by bit across the hierarchy.

Only what DC emits is understood: named port connections, `assign` between nets or constants,
wire/input/output declarations with an optional [msb:lsb], concatenations and N'b/N'h
constants. Anything else raises.
"""
import re


class Inst:
    def __init__(self, cell, name, conns, start, end):
        self.cell = cell        # cell or module name
        self.name = name
        self.conns = conns      # pin -> expression text (stripped), '' if unconnected
        self.start = start      # character span of the statement in the module text
        self.end = end


class Module:
    def __init__(self, name, ports, text, start, end):
        self.name = name
        self.ports = ports      # port names, header order
        self.text = text        # body text between the header and endmodule
        self.start = start
        self.end = end
        self.dirs = {}          # port -> 'input' | 'output' | 'inout'
        self.width = {}         # net -> (msb, lsb) for buses
        self.insts = []
        self.assigns = []       # (lhs text, rhs text)
        self.supply = {}        # net -> '0' | '1'


_COMMENT = re.compile(r'//[^\n]*|/\*.*?\*/', re.S)
_MODULE = re.compile(r'\bmodule\s+(\w+)\s*\((.*?)\)\s*;(.*?)\bendmodule\b', re.S)
_DECL = re.compile(r'^\s*(input|output|inout|wire|tri|supply0|supply1)\b\s*(\[\s*(\d+)\s*:\s*(\d+)\s*\])?\s*(.*)$', re.S)
_INST = re.compile(r'^\s*(\w+)\s+(\w+)\s*\((.*)\)\s*$', re.S)
_CONN = re.compile(r'\.(\w+)\s*\(\s*([^()]*?)\s*\)')


def parse(path):
    text = _COMMENT.sub(lambda m: ' ' * len(m.group(0)), open(path).read())
    mods = {}
    for m in _MODULE.finditer(text):
        name, ports, body = m.group(1), m.group(2), m.group(3)
        mod = Module(name, [p.strip() for p in ports.split(',') if p.strip()], body,
                     m.start(3), m.end(3))
        pos = 0
        for stmt in body.split(';'):
            s0, s1 = pos, pos + len(stmt)
            pos = s1 + 1
            st = stmt.strip()
            if not st:
                continue
            d = _DECL.match(st)
            if d:
                kind = d.group(1)
                names = [n.strip() for n in d.group(5).split(',') if n.strip()]
                for n in names:
                    if d.group(2):
                        mod.width[n] = (int(d.group(3)), int(d.group(4)))
                    if kind in ('input', 'output', 'inout'):
                        mod.dirs[n] = kind
                    elif kind in ('supply0', 'supply1'):
                        mod.supply[n] = kind[-1]
                continue
            if st.startswith('assign'):
                lhs, rhs = st[len('assign'):].split('=', 1)
                mod.assigns.append((lhs.strip(), rhs.strip()))
                continue
            i = _INST.match(st)
            if not i:
                raise ValueError(f'{name}: cannot parse statement: {st[:120]}')
            conns = {p: e for p, e in _CONN.findall(i.group(3))}
            mod.insts.append(Inst(i.group(1), i.group(2), conns, s0, s1))
        mods[name] = mod
    return mods, text


def expr_bits(expr, width):
    """Bits of an expression, MSB first: net names ('n' or 'n[3]') or constants '0'/'1'.
    `width` maps a bus name to (msb, lsb)."""
    expr = expr.strip()
    if expr == '':
        return []
    if expr.startswith('{'):
        assert expr.endswith('}'), expr
        out = []
        for part in _split_top(expr[1:-1]):
            out += expr_bits(part, width)
        return out
    c = re.fullmatch(r"(\d+)'([bhd])([0-9a-fA-FxXzZ_]+)", expr)
    if c:
        n, base, v = int(c.group(1)), c.group(2), c.group(3).replace('_', '')
        val = int(v, {'b': 2, 'h': 16, 'd': 10}[base])
        return [str((val >> k) & 1) for k in range(n - 1, -1, -1)]
    r = re.fullmatch(r'(\w+)\s*\[\s*(\d+)\s*:\s*(\d+)\s*\]', expr)
    if r:
        n, a, b = r.group(1), int(r.group(2)), int(r.group(3))
        step = -1 if a >= b else 1
        return [f'{n}[{k}]' for k in range(a, b + step, step)]
    r = re.fullmatch(r'(\w+)\s*\[\s*(\d+)\s*\]', expr)
    if r:
        return [f'{r.group(1)}[{r.group(2)}]']
    if re.fullmatch(r'\w+', expr):
        if expr in width:
            a, b = width[expr]
            step = -1 if a >= b else 1
            return [f'{expr}[{k}]' for k in range(a, b + step, step)]
        return [expr]
    raise ValueError(f'unsupported expression: {expr}')


def _split_top(s):
    parts, depth, cur = [], 0, ''
    for ch in s:
        if ch == '{':
            depth += 1
        elif ch == '}':
            depth -= 1
        if ch == ',' and depth == 0:
            parts.append(cur)
            cur = ''
        else:
            cur += ch
    if cur.strip():
        parts.append(cur)
    return parts


def port_bits(mod, port):
    if port in mod.width:
        a, b = mod.width[port]
        step = -1 if a >= b else 1
        return [f'{port}[{k}]' for k in range(a, b + step, step)]
    return [port]


def read_cell_dirs(paths):
    """Pin directions of leaf cells (library or memory models): cell -> {pin: dir}."""
    dirs = {}
    for p in paths:
        txt = _COMMENT.sub(' ', open(p).read())
        for m in re.finditer(r'\bmodule\s+(\w+)\s*(#\s*\(.*?\)\s*)?\((.*?)\)\s*;(.*?)\bendmodule\b', txt, re.S):
            name, hdr, body = m.group(1), m.group(3), m.group(4)
            d = {}
            # ANSI headers: "input wire [3:0] a, b, output reg q"
            cur = None
            for tok in re.split(r',', hdr):
                t = tok.strip()
                mm = re.match(r'(input|output|inout)\b(?:\s+(?:wire|reg|logic))?(?:\s*\[[^\]]*\])?\s*(\w+)$', t)
                if mm:
                    cur = mm.group(1)
                    d[mm.group(2)] = cur
                elif cur and re.fullmatch(r'\w+', t):
                    d[t] = cur
            for mm in re.finditer(r'^\s*(input|output|inout)\b(?:\s+(?:wire|reg|logic))?(?:\s*\[[^\]]*\])?\s*([^;]*);', body, re.M):
                for n in mm.group(2).split(','):
                    n = n.strip()
                    if re.fullmatch(r'\w+', n):
                        d[n] = mm.group(1)
            dirs[name] = d
    return dirs


class Flat:
    """The netlist connected bit by bit. A net is identified by '<inst path>/<bit>' (the top's
    path is ''); find() gives the representative of its connected set."""

    def __init__(self, mods, top, cell_dirs):
        self.mods, self.top, self.cell_dirs = mods, top, cell_dirs
        self.parent = {}
        self.const = {}         # representative -> '0' / '1'
        self.leaves = []        # (path of the instance, Inst, module it sits in)
        self.blackbox = {m for m, mod in mods.items() if not mod.insts and not mod.assigns}
        self._walk(top, '')
        self.pins = {}          # representative -> [(leaf index, pin, dir)]
        for li, (path, inst, owner) in enumerate(self.leaves):
            dirs = self._leaf_dirs(inst.cell)
            for pin, e in inst.conns.items():
                bits = expr_bits(e, self.mods[owner].width)
                pb = self._pin_bits(inst.cell, pin, len(bits))
                for b, p in zip(bits, pb):
                    r = self.find(self.key(path, b))
                    self.pins.setdefault(r, []).append((li, p, dirs.get(pin, '?')))

    def _leaf_dirs(self, cell):
        if cell in self.blackbox:
            return self.mods[cell].dirs
        if cell not in self.cell_dirs:
            raise KeyError(f'no model for cell {cell}')
        return self.cell_dirs[cell]

    def _pin_bits(self, cell, pin, n):
        if cell in self.blackbox and pin in self.mods[cell].width:
            return port_bits(self.mods[cell], pin)
        if n == 1:
            return [pin]
        return [f'{pin}[{k}]' for k in range(n - 1, -1, -1)]

    def key(self, path, bit):
        if bit in ('0', '1'):
            k = 'const/' + bit
            self.parent.setdefault(k, k)
            self.const[k] = bit
            return k
        k = f'{path}/{bit}'
        self.parent.setdefault(k, k)
        return k

    def find(self, k):
        p = self.parent.setdefault(k, k)
        while p != self.parent[p]:
            self.parent[p] = self.parent[self.parent[p]]
            p = self.parent[p]
        self.parent[k] = p
        return p

    def union(self, a, b):
        ra, rb = self.find(a), self.find(b)
        if ra == rb:
            return
        if ra.startswith('const/'):
            ra, rb = rb, ra
        self.parent[ra] = rb
        if ra in self.const:
            self.const[rb] = self.const[ra]

    def _walk(self, mname, path):
        mod = self.mods[mname]
        for n, v in mod.supply.items():
            self.union(self.key(path, n), self.key(path, v))
        for lhs, rhs in mod.assigns:
            lb, rb = expr_bits(lhs, mod.width), expr_bits(rhs, mod.width)
            if len(lb) != len(rb):
                raise ValueError(f'{mname}: width mismatch in assign {lhs} = {rhs}')
            for a, b in zip(lb, rb):
                self.union(self.key(path, a), self.key(path, b))
        for inst in mod.insts:
            if inst.cell in self.mods and inst.cell not in self.blackbox:
                child = self.mods[inst.cell]
                cpath = f'{path}/{inst.name}' if path else inst.name
                for pin, e in inst.conns.items():
                    pbits = expr_bits(e, mod.width)
                    cbits = port_bits(child, pin)
                    if pbits and len(pbits) != len(cbits):
                        raise ValueError(f'{mname}/{inst.name}.{pin}: width mismatch')
                    for a, b in zip(pbits, cbits):
                        self.union(self.key(path, a), self.key(cpath, b))
                self._walk(inst.cell, cpath)
            else:
                self.leaves.append((path, inst, mname))
