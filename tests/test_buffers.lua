-- tests/test_buffers.lua (12 ноя) — буферы панелей: id, регистрация, второй экземпляр, подмена состояния
package.path = './?.lua;' .. package.path
local B = dofile('jf_tracker_buffers.lua')
local PN = dofile('jf_tracker_panes.lua')
local n, fail = 0, 0
local function ok(c, m) n = n + 1; if not c then fail = fail + 1; print('FAIL ' .. m) end end

-- id
local b, k = B.base('dsp#2'); ok(b == 'dsp' and k == 2, 'base dsp#2')
b, k = B.base('dsp'); ok(b == 'dsp' and k == 1, 'base dsp')
ok(B.id('dsp', 1) == 'dsp' and B.id('dsp', 3) == 'dsp#3', 'id')
ok(B.base(nil) == nil, 'base nil')

-- модуль как есть: буфер 1 — та же таблица
local IN = { r = 1, c = 1, r0 = 1, c0 = 1, columns = function() end }
local b1 = B.register('inputs', IN, { 'r', 'c', 'r0', 'c0' }, { r = 1, c = 1, r0 = 1, c0 = 1 })
ok(b1.st == IN and b1.n == 1 and B.get('inputs') == b1, 'buffer 1 aliases the module')
ok(B.can_multi('inputs') and not B.can_multi('tracker'), 'can_multi')
ok(B.new('tracker') == nil, 'unregistered - no second buffer')

-- второй буфер: свои поля, подмена и возврат
IN.r = 5
local id2 = B.new('inputs')
ok(id2 == 'inputs#2' and B.get(id2).st.r == 1, 'new buffer from defaults ' .. tostring(id2))
ok(B.enter(id2) and IN.r == 1, 'enter swaps in')
IN.r = 7
ok(B.leave() and IN.r == 5 and B.get(id2).st.r == 7, 'leave swaps back, keeps change')
ok(not B.enter('inputs'), 'buffer 1 - no swap')
ok(not B.leave(), 'leave without enter')
local seen = B.with(id2, function(x) return IN.r + x end, 1)
ok(seen == 8 and IN.r == 5, 'with: inside buffer 2, restored after')
local okc, err = pcall(B.with, id2, function() error('boom', 0) end)
ok(not okc and err == 'boom' and IN.r == 5, 'with: error restores')
local id3 = B.new('inputs'); ok(id3 == 'inputs#3', 'third')
ok(#B.list('inputs') == 3 and B.list('inputs')[1] == 'inputs', 'list')
ok(B.drop(id3) and not B.get(id3) and not B.drop('inputs'), 'drop (never buffer 1)')
-- без defaults — текущие значения модуля
local RF = { sel = 4 }
B.register('reform', RF, { 'sel' })
ok(B.get(B.new('reform')).st.sel == 4, 'new from current values')

-- панели: PN.BY знает 'dsp#2' как dsp (реестр не меняется)
ok(PN.BY['dsp#2'] == PN.BY.dsp and PN.BY['dsp#2'].label == 'dsp', 'PN.BY base-aware')
ok(PN.BY['nope#2'] == nil and PN.BY.nope == nil, 'PN.BY unknown')
ok(PN.base('inst#3') == 'inst', 'PN.base')
local m = PN.DEFAULT()
PN.show(m, 'dsp#2')
ok(PN.visible(m, 'dsp#2'), 'show dsp#2 in the tree')
local lay = PN.layout(m, 800, 600, { rh = 14, cw = 8, pad = 4, tab_h = 16, hint_h = 15, sep = 1, grip = 3, avail = function() return true end })
ok(lay.by_panel['dsp#2'] ~= nil and lay.by_panel['dsp#2'].content.w > 0, 'dsp#2 laid out')
ok(PN.parse_name('dsp#2') == 'dsp#2', 'parse_name keeps the number')

print(('test_buffers: %d checks, %d failed'):format(n, fail))
os.exit(fail == 0 and 0 or 1)
