#!/usr/bin/env python3
# tools/srccheck.py — равные строки и имена функций jf_tracker против чужих исходников (SOURCES.md):
#   python3 tools/srccheck.py . <чужие файлы .lua>
import re, sys, glob, os, collections
def norm_lines(path):
    out = []
    try: txt = open(path, encoding='utf-8', errors='replace').read()
    except: return out
    txt = re.sub(r'--\[\[.*?\]\]', '', txt, flags=re.S)
    for i, l in enumerate(txt.split('\n'), 1):
        l = re.sub(r'--.*$', '', l)                     # комментарии
        l = re.sub(r'"[^"]*"|\'[^\']*\'', '"S"', l)     # строки — одинаково
        l = re.sub(r'\s+', ' ', l).strip()
        if len(l) >= 30: out.append((l, i))
    return out
def funcs(path):
    try: txt = open(path, encoding='utf-8', errors='replace').read()
    except: return set()
    return set(re.findall(r'function\s+([A-Za-z_][\w\.:]*)\s*\(', txt))
mine_dir, other = sys.argv[1], sys.argv[2:]
mine = {}
for p in glob.glob(os.path.join(mine_dir, '*.lua')):
    for l, i in norm_lines(p): mine.setdefault(l, []).append((os.path.basename(p), i))
myf = set()
for p in glob.glob(os.path.join(mine_dir, '*.lua')): myf |= {f.split('.')[-1].split(':')[-1] for f in funcs(p)}
hits = []
of = set()
for p in other:
    of |= {f.split('.')[-1].split(':')[-1] for f in funcs(p)}
    for l, i in norm_lines(p):
        if l in mine: hits.append((l, os.path.basename(p), i, mine[l][:2]))
uniq = collections.OrderedDict()
for h in hits: uniq.setdefault(h[0], h)
print('identical normalized lines (>=30 chars):', len(uniq))
for l, f, i, m in list(uniq.values())[:60]: print(f'  {f}:{i}  ~ {m[0][0]}:{m[0][1]}  | {l[:110]}')
common = sorted(f for f in (myf & of) if len(f) > 4)
print('shared function names (>4 chars):', len(common)); print('  ', ' '.join(common[:80]))
