#!/usr/bin/env python3
# Tera Term 本家の 1 バイト文字コードの対応表 (teraterm/teraterm/mapping/*.map) から
# Sources/TeraCore/SBCSTables.swift を作る (unicode.cpp GetSBCSTable / UnicodeFromSBCS / UnicodeToSBCS が使う表。#510 6a854d5ab)
# 使い方: python3 scripts/gen_sbcs_tables.py [teraterm/teraterm/mapping のディレクトリ]
import os
import re
import sys

here = os.path.dirname(os.path.abspath(__file__))
src = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, '..', '..', 'teraterm', 'teraterm', 'mapping')
out = os.path.join(here, '..', 'Sources', 'TeraCore', 'SBCSTables.swift')

re_entry = re.compile(r"\{\s*0x([0-9a-fA-F]+),\s*0x([0-9a-fA-F]+)\s*\}")

names = sorted(f[:-4] for f in os.listdir(src) if f.endswith('.map'))

lines = [
    '// このファイルは scripts/gen_sbcs_tables.py が作る (直接書き換えない)',
    '// 元: Tera Term 本家 teraterm/teraterm/mapping/*.map (Unicode Consortium の対応表。(C) 2004- TeraTerm Project, BSD 3-Clause)',
    '// 256 個の表。0xFFFF は対応する Unicode がない (UnicodeFromSBCS が 0 を返す)',
    '',
    'enum SBCSTables {',
]
for n in names:
    with open(os.path.join(src, n + '.map'), encoding='utf-8-sig') as f:
        text = f.read()
    table = [0xFFFF] * 256
    for m in re_entry.finditer(text):
        b = int(m.group(1), 16)
        u = int(m.group(2), 16)
        if b < 256 and table[b] == 0xFFFF:
            table[b] = u
    ident = n.replace('-', '_')
    lines.append('    static let %s: [UInt16] = [' % ident)
    for i in range(0, 256, 16):
        lines.append('        ' + ', '.join('0x%04X' % v for v in table[i:i + 16]) + ',')
    lines.append('    ]')
lines.append('}')
lines.append('')

with open(out, 'w', encoding='utf-8') as f:
    f.write('\n'.join(lines))
print('wrote', out, len(names), 'tables')
