-- tests/test_console.lua — консоль (jf_tracker_console.lua): разбор канала, план записи, редактор, история
local DIR = debug.getinfo(1, 'S').source:match('^@(.*)/tests/') or '.'
local C = dofile(DIR .. '/jf_tracker_console.lua')
local fails, n = 0, 0
local function ok(c, msg) n = n + 1; if not c then fails = fails + 1; print('FAIL ' .. msg) end end
local function near(a, b) return math.abs(a - b) < 1e-6 end

-- канал
local t, e = C.split('t2: n("c e")')
ok(t == 2 and e == 'n("c e")', 'tN: prefix')
t, e = C.split('  n("c")  ')
ok(t == nil and e == 'n("c")', 'no prefix - cursor track, trimmed')
t, e = C.split('t12:~')
ok(t == 12 and e == '~', 't12 and ~')

-- план: 1 такт, LPB 4 → 16 строк
local p = C.plan('t1: n("c e g b")', 1, 16)
ok(p.track_n == 1 and not p.clear and #p.events == 4, 'four notes')
ok(near(p.events[2].row_f, 4) and near(p.events[2].len_rows, 4), 'row 4, length 4 rows')
ok(p.events[1].pitch == 60 and p.events[1].vel == 102, 'pitch 60, vel 0.8 -> 102')

-- 2 такта: < > по тактам
p = C.plan('n("<c e>")', 2, 16)
ok(#p.events == 2 and p.events[1].pitch == 60 and p.events[2].pitch == 64 and near(p.events[2].row_f, 16), '<c e> over 2 bars')

-- дробная строка: c*3 на 16 строках → 5.333
p = C.plan('n("c*3")', 1, 16)
ok(#p.events == 3 and near(p.events[2].row_f, 16 / 3), 'fractional row kept: ' .. p.events[2].row_f)

-- слайсы и команды
p = C.plan('s("1 3 ~ 5").cmd("0R42")', 1, 16)
ok(#p.events == 3 and p.events[1].slice == 1 and p.events[3].slice == 5 and p.events[1].cmd == '0R42' and p.events[1].pitch == nil, 'slices with a command')
p = C.plan('n("c e").i(2).vel("1 0.5")', 1, 16)
ok(p.events[1].inst == 2 and p.events[1].vel == 127 and p.events[2].vel == 64, '.i and .vel pattern')

-- снять
p = C.plan('t3: ~', 1, 16)
ok(p.clear and p.track_n == 3 and not p.all, 't3: ~ clears the channel')
p = C.plan('hush', 1, 16)
ok(p.clear and p.all, 'hush clears all')
ok(not pcall(C.plan, 'n("c [e")', 1, 16), 'parse error raises')

-- редактор
C.set('')
for ch in ('t1: n("c")'):gmatch('.') do C.key(ch:byte()) end
ok(C.lines[1] == 't1: n("c")', 'typing')
ok(C.key(13) == 'eval', 'Enter evaluates')
ok(C.key(13, { cmd = true }) == 'evalall', 'Cmd+Enter evaluates all')
C.key(13, { shift = true })
ok(#C.lines == 2 and C.l == 2, 'Shift+Enter - new line')
ok(C.key(27) == 'leave', 'Esc leaves')
C.key(8); ok(#C.lines == 1 and C.c == #C.lines[1], 'BS at line start joins')
-- история в пустой строке
C.set(''); C.push_hist('t1: n("c")'); C.push_hist('t2: s("1")')
C.key(30064); ok(C.lines[1] == 't2: s("1")', 'Up - last history')
C.key(30064); ok(C.lines[1] == 't1: n("c")', 'Up again - older')
C.key(1685026670); ok(C.lines[1] == 't2: s("1")', 'Down - newer')

-- раскраска
local st = C.style('t1: n("c e").fast(2)')
ok(st[1] == 'CHAN' and st[3] == 'CHAN', 'channel green')
ok(st[7] == 'STR' and st[10] == 'STR', 'quoted string amber')
ok(st[13] == 'FN' and st[17] == 'FN', '.fast cyan')

print(('test_console: %d/%d ok'):format(n - fails, n))
os.exit(fails == 0 and 0 or 1)
