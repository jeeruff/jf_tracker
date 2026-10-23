#!/usr/bin/env python3
"""comment_trap.py (23 окт): поля таблиц, спрятанные за комментарием в той же строке —
`a = 1,   -- пояснение b = 2, c = 3,` (b и c Lua не видит). Печатает подозрительные строки."""
import re, sys
files = sys.argv[1:] or ['jf_tracker.lua', 'jf_tracker_draw.lua', 'jf_tracker_matrix.lua', 'jf_tracker_vim.lua', 'jf_tracker_edit.lua', 'jf_tracker_model.lua']
bad = 0
for f in files:
    for i, l in enumerate(open(f, encoding='utf-8').read().split('\n'), 1):
        s = l.strip()
        if s.startswith('--'): continue
        m = re.search(r'--(?!\[)', l)
        if not m: continue
        code, com = l[:m.start()], l[m.end():]
        if code.count("'") % 2 or code.count('"') % 2: continue
        if not code.rstrip().endswith((',', '{')): continue          # строка-поле таблицы
        if re.search(r'(?:^|[\s,{])[A-Za-z_]\w*\s*=\s*(?:[A-Za-z_]\w*[.:(\[]|function\b|true\b|false\b|nil\b|\{)[^,]*,', com):
            bad += 1; print(f'{f}:{i}: {s[:160]}')
sys.exit(1 if bad else 0)
