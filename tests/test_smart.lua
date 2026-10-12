-- test_smart.lua — смарт-панель (jf_tracker_smart.lua): сетки, клавиши, раскладка
local DIR = debug.getinfo(1, 'S').source:sub(2):match('(.*)/tests/') or '.'
local SM = dofile(DIR .. '/jf_tracker_smart.lua')
local n, bad = 0, 0
local function eq(a, b, m) n = n + 1; if a ~= b then bad = bad + 1; print('FAIL ' .. m .. ': ' .. tostring(a) .. ' ~= ' .. tostring(b)) end end
-- ноты: C-4 = 60, выбор стартует на текущей ноте
local items, cols, sel = SM.notes(64, 4)
eq(cols, 12, 'notes in 12 columns'); eq(items[sel].label, 'E-4', 'cursor on the current note')
eq(items[sel].on, true, 'current note marked')
eq(SM.note_label(60), 'C-4', 'C-4 = 60'); eq(SM.note_label(61), 'C#4', 'C#4')
eq(items[#items].v, 'del', 'last = delete'); eq(items[#items - 1].v, 'off', 'then OFF')
eq((#items - 2) % 12, 0, 'OFF starts a row')
items, cols, sel = SM.notes(nil, 3); eq(items[sel].v, 48, 'empty cell: C of the octave')
-- значения
items, cols, sel = SM.values(128, 0x40, true, 'clear'); eq(#items, 129, '128 + clear'); eq(items[sel].label, '40', 'hex label')
items = SM.values(128, nil, false); eq(items[101].label, '100', 'decimal label')
-- клавиши: h j k l, границы, Enter → on_pick, следующая сетка
local got
SM.open({ title = 't', items = SM.values(256, nil, true), cols = 16, sel = 1, on_pick = function(it) got = it.v end })
SM.key(('l'):byte()); SM.key(('j'):byte()); eq(SM.p.sel, 18, 'l j')
SM.key(('k'):byte()); SM.key(('k'):byte()); eq(SM.p.sel, 2, 'k stops at the top')
SM.key(('$'):byte()); eq(SM.p.sel, 16, '$ row end'); SM.key(('^'):byte()); eq(SM.p.sel, 1, '^ row start (0 is a digit here)')
SM.key(('G'):byte()); SM.key(13); eq(got, 255, 'G Enter picks the last'); eq(SM.p, nil, 'closed after pick')
-- 12 окт: набор с клавиатуры — 9E выбирает 9E, Backspace назад, чужой символ не ломает выбор
SM.open({ title = 't', items = SM.values(256, 0x5B, true), cols = 16, sel = 0x5C, on_pick = function(it) got = it.v end })
SM.key(('9'):byte()); eq(SM.typed, '9', 'typed 9'); eq(SM.p.items[SM.p.sel].label:sub(1, 1), '9', '9: a 9x cell')
SM.key(('e'):byte()); eq(SM.p.items[SM.p.sel].label, '9E', '9e -> 9E (lower case too)')
SM.key(8); eq(SM.typed, '9', 'BS -> 9'); SM.key(('E'):byte())
SM.key(('z'):byte()); eq(SM.p.items[SM.p.sel].label, '9E', 'z: no such value, selection stays')
SM.key(13); eq(got, 0x9E, 'Enter picks the typed value')
local vi = SM.values(256, nil, true)
eq(vi[0x9F].sub, '158', 'hex cell shows the decimal'); eq(vi[0x9F].tip:find('9E = 158', 1, true) ~= nil, true, 'tip: 9E = 158')
eq(SM.FX_MEAN['0U'](8), '+0.5 semitone per row', '0U 08 meaning'); eq(SM.FX_MEAN.SF(0x8E), '+14 cents', 'SF 8E meaning'); eq(SM.FX_MEAN.ZT(0x80), 'tempo 128 BPM', 'ZT 80 meaning')
SM.open({ title = 'n', items = (SM.notes(60, 4)), cols = 12, sel = 49, on_pick = function(it) got = it.v end })
SM.key(('d'):byte()); SM.key(('#'):byte()); SM.key(('4'):byte()); SM.key(13); eq(got, 63, 'd#4 typed -> D#4')
SM.open({ title = 'c', items = (SM.fx_letters()), cols = 4, on_pick = function(it) got = it.v end })
SM.key(('0'):byte()); SM.key(('u'):byte()); SM.key(13); eq(got, '0U', '0u typed -> 0U')
SM.open({ title = 'cmd', items = (SM.fx_letters()), cols = 8, on_pick = function(it) return { title = it.v .. 'xx', items = (SM.values(256)), cols = 16 } end }, { x = 5, y = 5 })
SM.key(13); eq(SM.p and SM.p.title, '0Sxx', 'code → its values'); eq(SM.p.anchor and SM.p.anchor.x, 5, 'second stage keeps the place')
SM.key(27); eq(SM.p, nil, 'Esc closes')
-- раскладка: в окне, над ячейкой, если снизу нет места
local L = { pad = 2, rh = 14 }
local function ms(s) return #s * 7 end
SM.open({ title = 'note', items = (SM.notes(60, 4)), cols = 12 }, { x = 990, y = 700, top = 686 })
local x, y, w, h = SM.layout(L, ms, 1000, 720)
eq(x + w <= 998, true, 'inside on the right'); eq(y + h <= 686, true, 'above the cell when no room below')
eq(y >= 2, true, 'inside on the top')
print(('test_smart: %d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
