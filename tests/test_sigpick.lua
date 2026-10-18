-- tests/test_sigpick.lua — выпадашка размера: клавиши, набор, раскладка (18 окт)
local DIR = debug.getinfo(1, 'S').source:match('^@(.*)/tests/') or '.'
local SP = dofile(DIR .. '/jf_tracker_sigpick.lua')
local n, bad = 0, 0
local function eq(name, got, want) n = n + 1; if got ~= want then bad = bad + 1; print(('FAIL %s: got %s want %s'):format(name, tostring(got), tostring(want))) end end
local function k(s) for ch in s:gmatch('.') do SP.key(ch:byte()) end end
SP.open(4, 4, 'here', 3, 'A1', 10, 10)
eq('open: scope here', SP.scope, 'here'); eq('cmd', SP.cmd(), '4/4 here')
k('7'); eq('type n', SP.n, 7)
k('/8'); eq('type d', SP.d, 8); eq('cmd 7/8', SP.cmd(), '7/8 here')
k('/12'); eq('two digits n', SP.n, 12)
k('/16'); eq('d 16 via 1', SP.d, 16)
k('3'); eq('d 3 rejected', SP.d, 16)
k('/'); k('h'); eq('h: n-1', SP.n, 11); k('l'); k('l'); eq('l: n+1', SP.n, 13)
SP.d = 4; k('j'); eq('j: down the table', SP.d, 8); k('k'); k('k'); eq('k: up', SP.d, 2); k('k'); eq('k: top', SP.d, 2)
k('a'); eq('a: whole project', SP.scope, 'all'); k('a'); eq('a: back', SP.scope, 'here')
SP.field, SP.buf, SP.n = 'n', '', 45; SP.key(8); eq('BS: 45 -> 4', SP.n, 4); k('7'); eq('BS then a digit: 47', SP.n, 47)
eq('Enter apply', SP.key(13), 'apply'); eq('Esc close', SP.key(27), 'close'); eq('closed', SP.on, false)
SP.open(3, 4, 'here', nil, nil); eq('no pattern: all', SP.scope, 'all'); k('a'); eq('no pattern: a stays', SP.scope, 'all')
local lay = SP.layout(8, 14, 4, 3, 300, 200)
eq('cells', #lay.cells, 64); eq('fits the width', lay.x + lay.w <= 300 or lay.x == 0, true); eq('fits the height', lay.y + lay.h <= 200, true)
local c = lay.cells[16 + 7]   -- /4, 7
eq('cell 7/4', c.n .. '/' .. c.d, '7/4'); eq('hit cell', SP.hit(lay, c.x + 1, c.y + 1).cell, c)
print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
