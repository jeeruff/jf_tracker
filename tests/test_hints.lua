-- test_hints.lua — метки и выбор подсказок: lua tests/test_hints.lua
local DIR = (arg and arg[0] or ''):match('(.*)/tests/') or '.'
local H = dofile(DIR .. '/jf_tracker_hints.lua')
local fails, checks = 0, 0
local function eq(n, a, b) checks = checks + 1; if a ~= b then fails = fails + 1; print('FAIL ' .. n .. ': ' .. tostring(a) .. ' vs ' .. tostring(b)) end end
H.reset()
for i = 1, 30 do H.add('event', 0, i * 20, 10, 10, i) end
eq('start', H.start(), true)
eq('labels aa', H.targets[1].label, 'aa'); eq('labels as', H.targets[2].label, 'as'); eq('13th = sa', H.targets[13].label, 'sa')
eq('frozen during typing', (function() H.add('x', 0, 0, 1, 1); return #H.targets end)(), 30)
eq('first letter pending', H.key(('s'):byte()), 'pending')
local t = H.key(('a'):byte()); eq('sa → target 13', type(t) == 'table' and t.data, 13); eq('inactive after pick', H.active, false)
H.reset(); for i = 1, 3 do H.add('mx', 0, 0, 1, 1, i) end; H.start()
eq('esc cancels', H.key(27), 'cancel'); eq('inactive', H.active, false)
H.start(); H.key(('q'):byte()); H.key(('q'):byte()); eq('bad label resets typed', H.typed, '')
-- регрессия 5 окт: кадр после f (reset) не стирает метки
H.stop(); H.reset(); H.add('mx', 0, 0, 1, 1, 'k'); H.start(); H.reset()
eq('targets survive reset while active', #H.targets, 1)
H.key(('a'):byte()); local hit = H.key(('a'):byte())
eq('label still works', type(hit) == 'table' and hit.data, 'k')
-- метки не налезают друг на друга
H.stop(); H.reset(); H.lw, H.lh = 16, 12
H.add('btn', 0, 0, 4, 12, 'R'); H.add('btn', 6, 0, 4, 12, 'I'); H.add('btn', 40, 0, 4, 12, 'M')
H.start()
eq('overlapped target gets no label', H.targets[2].label, nil)
eq('next free target gets the second label', H.targets[3].label, 'as')
H.stop(); H.reset(); eq('no targets', H.start(), false)
print(('%d checks, %d failed'):format(checks, fails)); os.exit(fails == 0 and 0 or 1)
