-- test_notes.lua — буфер редактора заметок (без REAPER)
local DIR = debug.getinfo(1, 'S').source:match('^@(.*)/tests/') or '.'
local NT = dofile(DIR .. '/jf_tracker_notes.lua')
local n, bad = 0, 0
local function eq(a, b, what) n = n + 1; if a ~= b then bad = bad + 1; print(('FAIL %s: %s ~= %s'):format(what, tostring(a), tostring(b))) end end
NT.set('line one\nline two')
eq(#NT.lines, 2, 'two lines'); eq(NT.dirty, false, 'clean after set')
for ch in ('Hi '):gmatch('.') do NT.key(ch:byte()) end
eq(NT.lines[1], 'Hi line one', 'typing at start'); eq(NT.dirty, true, 'dirty after typing')
NT.key(1752132965 * 0 + 6647396)            -- End
NT.key(13); eq(#NT.lines, 3, 'enter splits'); eq(NT.lines[2], '', 'new empty line')
NT.key(8); eq(#NT.lines, 2, 'BS joins'); eq(NT.lines[1], 'Hi line one', 'joined back')
NT.key(1685026670); eq(NT.l, 2, 'down'); NT.key(1752132965); NT.key(8); eq(NT.lines[1], 'Hi line oneline two', 'BS at line start joins with previous')
eq(NT.text(), 'Hi line oneline two', 'text')
eq(NT.key(27), 'leave', 'esc leaves'); eq(NT.key(9), 'leave', 'tab leaves')
NT.set(''); eq(#NT.lines, 1, 'empty → one line')
print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
