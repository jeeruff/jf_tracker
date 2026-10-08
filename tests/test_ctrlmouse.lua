-- test_ctrlmouse.lua — мышь с Ctrl: выделение, диапазон, относительный шаг, XY
local DIR = debug.getinfo(1, 'S').source:sub(2):match('(.*)/tests/') or '.'
local CM = dofile(DIR .. '/jf_tracker_ctrlmouse.lua')
local n, bad = 0, 0
local function eq(a, b, m) n = n + 1; if a ~= b then bad = bad + 1; print('FAIL ' .. m .. ': ' .. tostring(a) .. ' ~= ' .. tostring(b)) end end
local function near(a, b, m) n = n + 1; if math.abs(a - b) > 1e-9 then bad = bad + 1; print('FAIL ' .. m .. ': ' .. tostring(a) .. ' ~= ' .. tostring(b)) end end

local vals = {}
local io = { get = function(t) return vals[CM.key(t)] end, set = function(t, v) vals[CM.key(t)] = v end }
local A = { kind = 'fx', tid = 'T', fx = 0, p = 1 }
local B = { kind = 'fx', tid = 'T', fx = 0, p = 4 }
local V = { kind = 'trk', tid = 'T', what = 'vol' }
vals[CM.key(A)], vals[CM.key(B)], vals[CM.key(V)] = 0.5, 0.5, 0

-- без выделения: цель под мышью, вверх — больше
CM.press(A, V, 100, 100)
CM.move(100, 90, false, io)
near(vals[CM.key(A)], 0.54, 'hover: 10 px up')
CM.move(100, 190, true, io)
near(vals[CM.key(A)], 0.5, 'shift: fine 100 px down')
CM.release()
-- нет hover — фокус клавиатуры (фейдер, дБ)
CM.press(nil, V, 0, 0); CM.move(0, -8, false, io); CM.release()
near(vals[CM.key(V)], 2, 'focus fader: +2 dB')
-- пределы
CM.press(A, nil, 0, 0); CM.move(0, -1000, false, io); CM.release()
eq(vals[CM.key(A)], 1, 'clamped at 1')

-- выделение
eq(CM.toggle(A), true, 'cmd-click adds'); eq(CM.toggle(A), false, 'again removes'); eq(CM.count(), 0, 'empty')
CM.toggle(A)
local list = {}
for i = 0, 6 do list[#list + 1] = { p = i, name = 'p' .. i } end
eq(CM.range(B, list), 3, 'shift-click: p2 p3 p4 added (p1 had)')
eq(CM.count(), 4, 'four selected')
CM.clear()

-- XY: ровно два выделенных
vals[CM.key(A)], vals[CM.key(B)] = 0.5, 0.5
CM.toggle(A); CM.toggle(B)
local L = CM.press(nil, nil, 0, 0)
eq(L.xy, true, 'two selected = xy')
CM.move(10, 0, false, io)
near(vals[CM.key(A)], 0.54, 'x -> first'); near(vals[CM.key(B)], 0.5, 'second untouched by x')
CM.move(10, -5, false, io)
near(vals[CM.key(B)], 0.52, 'y -> second')
CM.release(); CM.clear()
-- без целей — ничего
eq(CM.press(nil, nil, 0, 0), nil, 'no target')
eq(CM.move(5, 5, false, io), nil, 'no latch, no move')

-- жест «треки»: 10 треков на 1000 px
local g = CM.gesture_step(nil, 250, 500, 10, 1000)
eq(g.ti, 3, 'zone 3'); eq(g.mode, 'pick', 'starts picking')
CM.gesture_step(g, 460, 501, 10, 1000)
eq(g.ti, 5, 'sideways -> track 5')
CM.gesture_step(g, 461, 498, 10, 1000); CM.gesture_step(g, 461, 495, 10, 1000)
eq(g.mode, 'fader', 'vertical locks the fader'); eq(g.dy, 6, 'first fader step = accumulated')
CM.gesture_step(g, 470, 490, 10, 1000)
eq(g.ti, 5, 'small drift sideways keeps the track'); eq(g.mode, 'fader', 'still fader'); eq(g.dy, 5, 'up 5')
CM.gesture_step(g, 490, 490, 10, 1000)
eq(g.mode, 'pick', 'clearly sideways unlocks'); eq(g.ti, 5, 'zone of 490')
CM.gesture_step(g, 5000, 490, 10, 1000)
eq(g.ti, 10, 'clamped to the last track')
print(('%d checks, %d failed'):format(n, bad))
if bad > 0 then os.exit(1) end
