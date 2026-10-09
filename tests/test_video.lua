-- test_video.lua — вкладка video (jf_tracker_video.lua): клавиши и щелчки
local DIR = debug.getinfo(1, 'S').source:sub(2):match('(.*)/tests/') or '.'
local VD = dofile(DIR .. '/jf_tracker_video.lua')
local n, bad = 0, 0
local function eq(a, b, m) n = n + 1; if a ~= b then bad = bad + 1; print('FAIL ' .. m .. ': ' .. tostring(a) .. ' ~= ' .. tostring(b)) end end
local data = { items = { {}, {}, {} }, vp = { params = { { v = 0.5 }, { v = 0.99 } } } }
eq(VD.key(('j'):byte(), data), true, 'j eats'); eq(VD.sel, 2, 'j down')
VD.key(('j'):byte(), data); VD.key(('j'):byte(), data); eq(VD.sel, 3, 'j stops at the end')
eq(VD.key(13, data).kind, 'item', 'Enter jumps'); eq(VD.key(13, data).i, 3, 'to the selected')
eq(VD.key(('w'):byte(), data).kind, 'win', 'w window')
eq(VD.key(('p'):byte(), data), true, 'p with a processor: nothing')
eq(VD.key(('p'):byte(), { items = {} }).kind, 'addvp', 'p adds a processor')
eq(VD.key(('>'):byte(), data).kind, 'next', '> next preset')
VD.key(('J'):byte(), data); eq(VD.psel, 2, 'J param')
local a = VD.key(('L'):byte(), data); eq(a.v, 1, 'L clamps at 1')
a = VD.key(('H'):byte(), data); eq(math.abs(a.v - 0.98) < 1e-9, true, 'H steps down')
eq(VD.key(27, data).kind, 'leave', 'Esc leaves'); eq(VD.key(('x'):byte(), data), nil, 'x not ours')
eq(VD.click({ kind = 'item', i = 1 }).i, 1, 'click item'); eq(VD.sel, 1, 'click selects')
eq(VD.click({ kind = 'param', i = 1, v = 0.3 }).v, 0.3, 'click param value')
print(('test_video: %d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
