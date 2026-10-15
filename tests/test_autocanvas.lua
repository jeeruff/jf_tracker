-- test_autocanvas.lua — холст автоматизации (15 окт): клавиши → op, формы по сетке, полоса LFO, раскладка
local DIR = debug.getinfo(1, 'S').source:match('^@(.*)/tests/') or '.'
gfx = { mouse_x = -1, mouse_y = -1, a = 1 }
setmetatable(gfx, { __index = function() return function() end end })
local LG = dofile(DIR .. '/jf_tracker_lfogen.lua')
local ACV = dofile(DIR .. '/jf_tracker_autocanvas.lua')
local U = { GREEN = { 0, 1, 0 }, AMBER = { 1, 0.6, 0 }, CYAN = { 0, 1, 1 }, BG = { 0, 0, 0 }, LINE = { 0.3, 0.3, 0.3 }, GREY = { 0.5, 0.5, 0.5 }, TEXT = { 1, 1, 1 },
  set = function() end, text = function() end, measure = function(s) return #tostring(s) * 7 end,
  mix = function(a) return a end, tint = function(a) return a end }
ACV.init(U, { fit = function(s) return s end }, LG)
local n, bad = 0, 0
local function eq(name, got, want) n = n + 1; if got ~= want then bad = bad + 1; print(('FAIL %s: got %s want %s'):format(name, tostring(got), tostring(want))) end end
local function near(name, got, want, tol) n = n + 1; if math.abs(got - want) > (tol or 1e-6) then bad = bad + 1; print(('FAIL %s: got %s want %s'):format(name, tostring(got), tostring(want))) end end

local st = { r0 = 0, r1 = 32, lpb = 4, ncurves = 3, kind = 'env' }
-- движение и сетка
ACV.row, ACV.grid, ACV.cur = 0, 4, 1
ACV.key(('l'):byte(), st); eq('l', ACV.row, 1)
ACV.key(('L'):byte(), st); eq('L = grid', ACV.row, 5)
ACV.key(('h'):byte(), st); ACV.key(('H'):byte(), st); eq('H', ACV.row, 0)
ACV.key(('G'):byte(), st); eq('G', ACV.row, 31); ACV.key(('g'):byte(), st); eq('g', ACV.row, 0)
ACV.key(('['):byte(), st); eq('[ finer', ACV.grid, 2); ACV.key((']'):byte(), st); ACV.key((']'):byte(), st); eq('] coarser', ACV.grid, 8)
eq('grid label 1/8', ACV.grid_label(2, 4), '1/8'); eq('grid label rows', ACV.grid_label(3, 4), '3 rows'); eq('grid label bar', ACV.grid_label(16, 4), '1/1')
-- Tab по кривым
ACV.key(9, st); eq('Tab', ACV.cur, 2); ACV.key(9, st, { shift = true }); eq('S-Tab', ACV.cur, 1); ACV.key(9, st, { shift = true }); eq('S-Tab wraps', ACV.cur, 3)
-- ops
local r = ACV.key(('k'):byte(), st); eq('k nudge', r.op, 'nudge'); near('k +1/16', r.d, 1 / 16)
r = ACV.key(('J'):byte(), st); near('J -1/128', r.d, -1 / 128)
r = ACV.key(('7'):byte(), st); eq('7 level', r.op, 'level'); near('level 0.7', r.v, 0.7)
r = ACV.key(('x'):byte(), st); eq('x del', r.op, 'del')
r = ACV.key(('s'):byte(), st); eq('s fill', r.op, 'fill'); eq('s sin', r.shape, 'sin')
r = ACV.key(('R'):byte(), st); eq('R ramp-', r.shape, 'ramp-')
r = ACV.key(('w'):byte(), st); eq('w point', r.op, 'point'); eq('w +1', r.d, 1)
r = ACV.key(('m'):byte(), st); eq('m mod lfo', r.what, 'lfo')
eq('unknown key', ACV.key(('Z'):byte(), st), false)
-- якорь и диапазон
ACV.row, ACV.grid = 6, 4
local a, b = ACV.range(st); eq('cell range a', a, 4); eq('cell range b', b, 8)
ACV.key(('v'):byte(), st); eq('v anchor', ACV.anchor, 6)
ACV.row = 13; a, b = ACV.range(st); eq('v range a', a, 6); eq('v range b', b, 14)
eq('Esc clears anchor', ACV.key(27, st), true); eq('anchor gone', ACV.anchor, nil)
eq('Esc leaves', ACV.key(27, st).op, 'leave')
-- LFO-кривая: те же клавиши правят LFO
local stl = { r0 = 0, r1 = 32, lpb = 4, ncurves = 2, kind = 'lfo' }
r = ACV.key(('t'):byte(), stl); eq('lfo shape', r.key, 'lfo.shape'); eq('lfo tri', r.val, 4)
r = ACV.key(('['):byte(), stl); eq('lfo speed', r.key, 'lfo.speed'); eq('lfo half', r.mul, 0.5)
r = ACV.key(('k'):byte(), stl); eq('lfo strength', r.key, 'lfo.strength')
r = ACV.key(('w'):byte(), stl); eq('lfo phase', r.key, 'lfo.phase')
eq('lfo: digits not mine', ACV.key(('5'):byte(), stl), false)
-- формы: точки в [r0, r1), 0..1, первая в r0
for _, sh in ipairs({ 'flat', 'ramp+', 'ramp-', 'sin', 'tri', 'sqr', 'rnd' }) do
  for _, g in ipairs({ 1, 4, 16 }) do
    local pts = ACV.shape_points(sh, 8, 24, g, 0.8, 3)
    eq(sh .. ' g' .. g .. ' has points', #pts > 0, true)
    eq(sh .. ' g' .. g .. ' first at r0', pts[1].row, 8)
    local okr = true
    for _, p in ipairs(pts) do if p.row < 8 or p.row >= 24 or p.v < 0 or p.v > 0.8 + 1e-9 then okr = false end end
    eq(sh .. ' g' .. g .. ' in range', okr, true)
  end
end
eq('flat: one point per cell', #ACV.shape_points('flat', 0, 16, 4, 1), 4)
eq('sin: 8 per cell', #ACV.shape_points('sin', 0, 16, 4, 1), 32)
eq('sqr: square shape', ACV.shape_points('sqr', 0, 4, 4, 1)[1].shape, 1)
near('sin starts low', ACV.shape_points('sin', 0, 4, 4, 1)[1].v, 0)
local n1, n2 = ACV.shape_points('rnd', 0, 16, 4, 1, 1), ACV.shape_points('rnd', 0, 16, 4, 1, 2)
eq('rnd: seed changes', n1[1].v ~= n2[1].v, true)
eq('rnd: same seed same', ACV.shape_points('rnd', 0, 16, 4, 1, 1)[1].v, n1[1].v)
-- полоса LFO: sin 1 Гц, вокруг базы 0.5 силой 0.4
local mod = { v = { ['lfo.shape'] = 0, ['lfo.speed'] = 1, ['lfo.strength'] = 0.4, ['lfo.dir'] = 0, ['lfo.phase'] = 0 } }
local lo, hi, v = ACV.lfo_band(mod, 0, 0.5); near('band lo', lo, 0.3); near('band hi', hi, 0.7); near('sin at 0', v, 0.5)
lo, hi, v = ACV.lfo_band(mod, 0.25, 0.5); near('sin at 1/4', v, 0.7)
mod.v['lfo.dir'] = 1; lo, hi = ACV.lfo_band(mod, 0, 0.5); near('dir up lo', lo, 0.5); near('dir up hi', hi, 0.9)
mod.v['lfo.dir'] = -1; lo, hi = ACV.lfo_band(mod, 0, 0.9); near('dir down lo', lo, 0.5); near('dir down hi', hi, 0.9)
mod.v['lfo.temposync'] = 1; mod.v['lfo.speed'] = 1; mod.v['lfo.dir'] = 0
local _, _, v1 = ACV.lfo_band(mod, 0.125, 0.5, 2)   -- 2 удара/с, цикл = 1 доля (0.5 с): четверть цикла в 0.125 с
near('temposync quarter cycle', v1, 0.7)
-- раскладка: легенда сбоку при ширине, строкой при узости; поле не выходит за w / h
local L = { cw = 7, rh = 14, pad = 4 }
local lay = ACV.layout(L, 600, 200, 3); eq('wide: side legend', lay.side, true); eq('wide: fits', lay.gx + lay.gw + lay.lw + L.pad <= 600, true); eq('wide: height', lay.gy + lay.gh <= 200, true)
lay = ACV.layout(L, 300, 200, 3); eq('narrow: top legend', lay.side, false); eq('narrow: full width', lay.gw, 300)
-- draw без reaper: не падает, hover по легенде
local curves = { { name = 'vol', rgb = U.GREEN, eval = function(t) return 0.5 end, points = {} }, { name = 'pan', rgb = U.CYAN, eval = function(t) return t end, points = {} } }
local span = { r0 = 0, r1 = 16, t0 = 0, t1 = 2, lpb = 4, sc = 1, label = 'bar 1', row_of = function(t) return t * 8 end }
ACV.cur = 1
local hv = ACV.draw(L, 0, 0, 600, 200, curves, span, true)
eq('draw ok', hv, nil)
gfx.mouse_x, gfx.mouse_y = 500, lay.gy + 20
lay = ACV.layout(L, 600, 200, 2)
gfx.mouse_x, gfx.mouse_y = lay.gx + lay.gw + L.pad + 2, lay.gy + 14 + 2
hv = ACV.draw(L, 0, 0, 600, 200, curves, span, true)
eq('legend hover', hv and hv.legend, 2)
print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
