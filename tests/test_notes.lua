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
-- markdown и задачи (4 окт)
NT.set('# Check\n- [ ] meters\n  - [x] delta\n- plain\n`code` and **b**')
eq(NT.todo('- [ ] meters'), 3, 'todo box position')
eq(select(2, NT.todo('  - [x] delta')), true, 'done todo')
eq(NT.todo('- plain'), nil, 'list is not a todo')
eq(NT.toggle(2), true, 'toggle open todo')
eq(NT.lines[2], '- [x] meters', 'open -> done')
eq(NT.dirty, true, 'toggle marks dirty')
NT.toggle(3); eq(NT.lines[3], '  - [ ] delta', 'done -> open')
eq(NT.toggle(4), false, 'toggle on a plain line: no')
local st = NT.style('# Check'); eq(st[3], 'HEAD1', 'heading colour')
st = NT.style('- [x] done thing'); eq(st[1], 'MARK', 'todo mark'); eq(st[8], 'DONE', 'done text dimmed')
st = NT.style('`code` and **b**'); eq(st[2], 'CODE', 'inline code'); eq(st[13], 'BOLD', 'bold')
-- 11 окт: режим кода (Video processor): Tab — отступ, не выход; Esc — выход; текст как есть
NT.code = true
NT.set('input_info(0, w, h);\n// comment')
eq(NT.key(9), true, 'code: Tab is eaten'); eq(NT.lines[1]:sub(1, 2), '  ', 'code: Tab inserts two spaces')
eq(NT.key(27), 'leave', 'code: Esc leaves')
eq(NT.text(), '  input_info(0, w, h);\n// comment', 'code: text round trip')
NT.code = false
eq(NT.key(9), 'leave', 'notes: Tab still leaves')
print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
