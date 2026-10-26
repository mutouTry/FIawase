#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2025-2026 the FIawase authors
"""A program image as the power-on content of a memory: a .verilog image (objcopy -O verilog: bytes,
@address) to one little-endian word per line for $readmemh (word i = {byte 4i+3, 4i+2, 4i+1, 4i}).

usage: mkrom.py <image.verilog> <out.hex> <words> [--width 32|64]
"""
import sys


def main():
    src, out, words = sys.argv[1], sys.argv[2], int(sys.argv[3])
    width = int(sys.argv[5]) if len(sys.argv) > 5 and sys.argv[4] == '--width' else 32
    nb = width // 8
    mem = bytearray(words * nb)
    addr = 0
    for tok in open(src).read().split():
        if tok.startswith('@'):
            addr = int(tok[1:], 16)
            continue
        if addr >= len(mem):
            sys.exit(f'{src}: byte address {addr:#x} beyond {words} words')
        mem[addr] = int(tok, 16)
        addr += 1
    with open(out, 'w') as f:
        for i in range(words):
            w = int.from_bytes(mem[i * nb:(i + 1) * nb], 'little')
            f.write(f'{w:0{nb * 2}x}\n')
    print(f'{src}: {words} words of {width} bits -> {out}')


if __name__ == '__main__':
    main()
