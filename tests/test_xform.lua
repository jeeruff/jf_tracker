-- test_xform.lua — модификаторы времени и громкости (15 окт)
local DIR = debug.getinfo(1, 'S').source:match('^@(.*)/tests/') or '.'
local XF = dofile(DIR .. '/jf_tracker_xform.lua')
local n, bad = 0, 0
local function eq(name, got, want) n = n + 1; if got ~= want then bad = bad + 1; print(('FAIL %s: got %s want %s'):format(name, tostring(got), tostring(want))) end end
local function near(name, got, want, tol) n = n + 1; if math.abs(got - want) > (tol or 1e-6) then bad = bad + 1; print(('FAIL %s: got %s want %s'):format(name, tostring(got), tostring(want))) end end
local function rows(out) local t = {}; for i, e in ipairs(out) do t[i] = ('%g'):format(e.row) end; return table.concat(t, ' ') end
local ev = { { row = 0, v = 1 }, { row = 4, v = 0.8 }, { row = 8, v = 0.6 }, { row = 12, v = 0.4 } }

eq('stretch x2', rows(XF.stretch(ev, 0, 16, 2)), '0 8 16 24')
eq('stretch /2', rows(XF.stretch(ev, 0, 16, 0.5)), '0 2 4 6')
eq('reverse', rows(XF.reverse(ev, 0, 16)), '15 11 7 3')
eq('rotate 4', rows(XF.rotate(ev, 0, 16, 4)), '4 8 12 0')
eq('rotate -4', rows(XF.rotate(ev, 0, 16, -4)), '12 0 4 8')
local sh = XF.shuffle(ev, 0, 16, 3)
local seen = {}; for _, e in ipairs(sh) do seen[e.row] = true end
eq('shuffle keeps the set', seen[0] and seen[4] and seen[8] and seen[12], true)
eq('shuffle is repeatable', rows(XF.shuffle(ev, 0, 16, 3)), rows(sh))
eq('shuffle changes with seed', rows(XF.shuffle(ev, 0, 16, 4)) ~= rows(sh) or rows(XF.shuffle(ev, 0, 16, 5)) ~= rows(sh), true)
local g = XF.gravity(ev, 0, 16, 2)
near('gravity: first stays', g[1].row, 0); near('gravity: x^2', g[2].row, 16 * 0.25 ^ 2); near('gravity: last', g[4].row, 16 * 0.75 ^ 2)
eq('gravity keeps order', g[2].row < g[3].row and g[3].row < g[4].row, true)
local b = XF.bounce(ev, 0, 16, 0.5)
near('bounce: first', b[1].row, 0); near('bounce: last keeps place', b[4].row, 12)
near('bounce: intervals halve', (b[3].row - b[2].row) / (b[2].row - b[1].row), 0.5)
local f = XF.fib(ev, 0, 32)
eq('fib rows', rows(f), '0 1 2 3')
local f6 = XF.fib({ { row = 0 }, { row = 1 }, { row = 2 }, { row = 3 }, { row = 4 }, { row = 5 } }, 0, 32)
eq('fib 6', rows(f6), '0 1 2 3 5 8')
local f6s = XF.fib({ { row = 0 }, { row = 1 }, { row = 2 }, { row = 3 }, { row = 4 }, { row = 5 } }, 0, 6)
eq('fib scaled into the span', f6s[6].row <= 5, true)
eq('tuplet 3 over 12', rows(XF.tuplet(ev, 0, 12, 3)), '0 4 8 12')
near('tuplet 4 over 6: fractional', XF.tuplet(ev, 0, 6, 4)[2].row, 1.5)
local gl = XF.golden(ev, 0, 16)
near('golden first', gl[1].v, 1); near('golden second', gl[2].v, 1 / XF.PHI); near('golden third', gl[3].v, 1 / XF.PHI ^ 2)
near('vel x0.5', XF.vel(ev, 0, 16, 0.5)[1].v, 0.5); near('vel clamps', XF.vel(ev, 0, 16, 3)[1].v, 1)
eq('parse alias', XF.parse('rev'), 'reverse')
local nm, arg = XF.parse('grav 1.5'); eq('parse op', nm, 'gravity'); near('parse arg', arg, 1.5)
eq('parse unknown', XF.parse('fly'), nil)
eq('apply', rows(XF.apply('rotate', ev, 0, 16, 8)), '8 12 0 4')
eq('input untouched', ev[1].row, 0)
print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
