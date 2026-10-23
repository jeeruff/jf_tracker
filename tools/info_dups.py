#!/usr/bin/env python3
"""info_dups.py (23 окт): ключи верхнего уровня таблицы info (draw.frame(..., { … })), встречающиеся дважды —
второй молча затирает первый (22 окт: modsel-число затёрло функцию, кадр падал)."""
import re, sys, collections
s = open('jf_tracker.lua', encoding='utf-8').read()
i = s.index('hover = draw.frame(L, snap, rows, state, {')
j = s.index('{', i + 30)
depth, blk, keys, line = 0, 0, collections.defaultdict(list), s[:j].count('\n') + 1
tok = re.compile(r"--\[\[.*?\]\]|--[^\n]*|'(?:\\.|[^'\\])*'|\"(?:\\.|[^\"\\])*\"|\[\[.*?\]\]|\n|[{}()\[\]]|[A-Za-z_]\w*\s*=(?!=)|[A-Za-z_]\w*|.", re.S)
for m in tok.finditer(s, j):
    t = m.group(0)
    if t == '\n': line += 1; continue
    if t.startswith('--') or t.startswith(("'", '"', '[[')): line += t.count('\n'); continue
    if t in ('function', 'if', 'do', 'repeat'): blk += 1; continue
    if t in ('end', 'until'): blk -= 1; continue
    if t in '{([': depth += 1
    elif t in '})]':
        depth -= 1
        if depth == 0: break
    elif depth == 1 and blk == 0 and t.endswith('=') and re.match(r'[A-Za-z_]', t):
        keys[t[:-1].strip()].append(line)
d = {k: v for k, v in keys.items() if len(v) > 1}
for k, v in sorted(d.items()): print(f'{k}: lines {v}')
print(f'{len(keys)} keys, {len(d)} duplicated')
sys.exit(1 if d else 0)
