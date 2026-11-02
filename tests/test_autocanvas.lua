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
ACV.key(('}'):byte(), st); eq('} = grid', ACV.row, 5)
ACV.key(('h'):byte(), st); ACV.key(('{'):byte(), st); eq('{', ACV.row, 0)
eq('L is not the canvas key', ACV.key(('L'):byte(), st), false)
ACV.key(('G'):byte(), st); eq('G', ACV.row, 31); ACV.key(('g'):byte(), st); eq('g', ACV.row, 0)
ACV.key(('['):byte(), st); eq('[ finer', ACV.grid, 2); ACV.key((']'):byte(), st); ACV.key((']'):byte(), st); eq('] coarser', ACV.grid, 8)
eq('grid label 1/8', ACV.grid_label(2, 4), '1/8'); eq('grid label rows', ACV.grid_label(3, 4), '3 rows'); eq('grid label bar', ACV.grid_label(16, 4), '1/1')
-- zp — проект / отрезок
ACV.key(('z'):byte(), st); ACV.key(('p'):byte(), st); eq('zp on', ACV.proj, true); ACV.key(('z'):byte(), st); ACV.key(('p'):byte(), st); eq('zp off', ACV.proj, false)
ACV.key(('z'):byte(), st); eq('z then other key not mine', ACV.key(('Q'):byte(), st), false)
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
a, b = ACV.range(st, true); eq('v range snapped a', a, 6); eq('v range snapped b (whole cells)', b, 14)
ACV.row = 11; a, b = ACV.range(st, true); eq('v range snapped up', b, 14)
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
local _, _, v1 = ACV.lfo_band(mod, 0.125, 0.5, 2)   -- 2 удара/с, speed 1 = цикл на долю (0.5 с): четверть цикла в 0.125 с
near('temposync quarter cycle', v1, 0.7)
mod.v['lfo.speed'] = 2; _, _, v1 = ACV.lfo_band(mod, 0.0625, 0.5, 2); near('temposync 2 per beat', v1, 0.7)
local alo, ahi = ACV.mod_band({ kind = 'acs', mod = { v = { ['acs.strength'] = 0.3 } } }, 0, 0.5); near('acs band lo', alo, 0.5); near('acs band hi', ahi, 0.8)
-- раскладка: легенда сбоку при ширине, строкой при узости; поле не выходит за w / h
local L = { cw = 7, rh = 14, pad = 4 }
local lay = ACV.layout(L, 600, 200, 3); eq('wide: side legend', lay.side, true); eq('wide: fits', lay.gx + lay.gw <= 600 and lay.gx >= lay.lw, true)   -- 31 окт: список слева; eq('wide: height', lay.gy + lay.gh <= 200, true)
lay = ACV.layout(L, 300, 200, 3); eq('narrow: top legend', lay.side, false); eq('narrow: full width', lay.gw, 300)
-- draw без reaper: не падает, hover по легенде
local curves = { { name = 'vol', rgb = U.GREEN, eval = function(t) return 0.5 end, points = {} }, { name = 'pan', rgb = U.CYAN, eval = function(t) return t end, points = {} } }
local span = { r0 = 0, r1 = 16, t0 = 0, t1 = 2, lpb = 4, sc = 1, label = 'bar 1', row_of = function(t) return t * 8 end }
ACV.cur = 1
local hv = ACV.draw(L, 0, 0, 600, 200, curves, span, true)
eq('draw ok', hv, nil)
gfx.mouse_x, gfx.mouse_y = 500, lay.gy + 20
lay = ACV.layout(L, 600, 200, 2)
-- 31 окт: на 600 px панель инструментов переносится строками — легенда ниже; ищем строку второй кривой
local got
for yy = lay.gy, 200, 2 do
  gfx.mouse_x, gfx.mouse_y = L.pad + 8, yy   -- 31 окт: список слева
  hv = ACV.draw(L, 0, 0, 600, 200, curves, span, true)
  if hv and hv.legend == 2 then got = 2; break end
end
eq('legend hover', got, 2)
-- 30 окт: инструменты мыши — клавиши, точка холста → строка / значение, мазок по строкам и клеткам
ACV.tool, ACV.snap, ACV.grid = 'cur', true, 4
ACV.key(('i'):byte(), { r0 = 0, r1 = 64 }, {}); eq('i - draw (31 окт)', ACV.tool, 'draw')
ACV.key(('i'):byte(), { r0 = 0, r1 = 64 }, {}); eq('i again - cur', ACV.tool, 'cur')
ACV.key(('d'):byte(), { r0 = 0, r1 = 64 }, {}); local dw = ACV.key(('w'):byte(), { r0 = 0, r1 = 64 }, {}); eq('dw - delete', type(dw) == 'table' and dw.op, 'del')
ACV.key(('d'):byte(), { r0 = 0, r1 = 64 }, {}); ACV.key(('3'):byte(), { r0 = 0, r1 = 64 }, {}); local d3 = ACV.key(('w'):byte(), { r0 = 0, r1 = 64 }, {}); eq('d3w - three forward', d3 and d3.n == 3 and d3.dir, 1)
ACV.key(('d'):byte(), { r0 = 0, r1 = 64 }, {}); local db = ACV.key(('b'):byte(), { r0 = 0, r1 = 64 }, {}); eq('db - backward', db and db.dir, -1)
ACV.key(('d'):byte(), { r0 = 0, r1 = 64 }, {}); local dd = ACV.key(('d'):byte(), { r0 = 0, r1 = 64 }, {}); eq('dd - delete', type(dd) == 'table' and dd.op, 'del')
ACV.key(('y'):byte(), { r0 = 0, r1 = 64 }, {}); local yy = ACV.key(('y'):byte(), { r0 = 0, r1 = 64 }, {}); eq('yy - copy', type(yy) == 'table' and yy.op, 'yank')
local pp = ACV.key(('p'):byte(), { r0 = 0, r1 = 64 }, {}); eq('p - paste', type(pp) == 'table' and pp.op, 'paste')
ACV.key(('D'):byte(), { r0 = 0, r1 = 64 }, {}); eq('D - line', ACV.tool, 'line')
ACV.key(('E'):byte(), { r0 = 0, r1 = 64 }, {}); eq('E - erase', ACV.tool, 'erase')
ACV.key(('S'):byte(), { r0 = 0, r1 = 64 }, {}); eq('S - snap off', ACV.snap, false)
local geo = { gx = 100, gy = 10, gw = 160, gh = 104, r0 = 16, nr = 16 }
local r, v = ACV.at(geo, 100 + 75, 10 + 2)
eq('x -> row without snap', r, 23); eq('top -> 1', math.abs(v - 1) < 1e-6, true)
ACV.snap = true
r = ACV.at(geo, 100 + 75, 60); eq('snap -> grid cell start', r, 20)
local rows = ACV.span_rows(16, 0, 28, 1, {})
eq('stroke by cells: 16 20 24 28', rows[16] == 0 and rows[20] and rows[24] and rows[28] == 1 and rows[17] == nil, true)
ACV.snap = false
rows = ACV.span_rows(30, 1, 27, 0, {})
eq('backwards stroke by rows', rows[27] == 0 and rows[30] == 1 and rows[28] ~= nil, true)
rows = ACV.span_rows(2, 0, 4, 0, {}, true)
eq('erase marks false', rows[2] == false and rows[3] == false and rows[4] == false, true)
-- сетка мельче строки: подпись, [ ], точка между строками
eq('grid 0.5 at lpb 4 = 1/32', ACV.grid_label(0.5, 4), '1/32')
ACV.grid = 1; ACV.key(('['):byte(), { r0 = 0, r1 = 64, lpb = 4 }, {}); eq('[ below a row - 0.5', ACV.grid, 0.5)
ACV.key(('['):byte(), { r0 = 0, r1 = 64, lpb = 4 }, {}); ACV.key(('['):byte(), { r0 = 0, r1 = 64, lpb = 4 }, {}); ACV.key(('['):byte(), { r0 = 0, r1 = 64, lpb = 4 }, {})
eq('[ stops at 1/8 row', ACV.grid, 0.125)
ACV.grid, ACV.snap = 0.5, true
r = ACV.at(geo, 100 + 75, 60); eq('snap 0.5 -> half rows', r, 23.5)
rows = ACV.span_rows(16, 0, 17, 1, {}); eq('stroke by half rows: 16 16.5 17', rows[16] == 0 and rows[16.5] and rows[17] == 1, true)
-- 30 окт: shape — формы по клеткам (Ableton): exp медленно внизу, log быстро; отрезок от начала протяжки
ACV.grid, ACV.snap = 4, true
ACV.key(('c'):byte(), { r0 = 0, r1 = 64 }, {}); eq('c - shape tool', ACV.tool, 'shape')
ACV.shape = 'exp'
local sr, sa, sb = ACV.shape_stroke(8, 0, 1)
eq('shape span from the drag start, whole cells', sa == 0 and sb == 12, true)
eq('exp: low at a quarter of the cell', sr[1] < 0.15 and sr[0] == 0, true)
ACV.shape = 'log'
sr = ACV.shape_stroke(0, 0, 1)
eq('log: high at a quarter of the cell', sr[1] > 0.5, true)
ACV.shape = 'ramp-'
sr = ACV.shape_stroke(0, 4, 0.5)
eq('saw- starts at the height', sr[0] == 0.5 and sr[4] == 0.5, true)
ACV.grid = 4
ACV.tool, ACV.snap = 'cur', true
-- 31 окт: трансформация выделения, humanize, замена строк, цикл формы
do
  local pts = { { row = 0, v = 0.2 }, { row = 4, v = 0.6 }, { row = 8, v = 1.0 } }
  local box = ACV.box_of(pts, 0, 8)
  near('box lo', box.lo, 0.2); near('box hi', box.hi, 1.0)
  local mv = ACV.xform(pts, box, 'move', 2, -0.1)
  near('move row', mv[2].row, 6); near('move v', mv[2].v, 0.5)
  local rr = ACV.xform(pts, box, 'r', 8, 0)
  near('stretch right x2', rr[3].row, 16); near('stretch keeps the left', rr[1].row, 0)
  local ll = ACV.xform(pts, box, 'l', 4, 0)
  near('stretch left keeps the right', ll[3].row, 8); near('stretch left half', ll[1].row, 4)
  local tt = ACV.xform(pts, box, 't', 0, -0.4)
  near('top down: low stays', tt[1].v, 0.2); near('top down: top', tt[3].v, 0.6); near('top down: middle', tt[2].v, 0.4)
  local tl = ACV.xform(pts, box, 'tl', 0, -0.4)
  near('tilt top-left: the right end stays', tl[3].v, 1.0)
  local hm = ACV.humanize(pts, 0.1, 3)
  eq('humanize keeps the count', #hm, 3); eq('humanize moves values', hm[2].v ~= 0.6 and math.abs(hm[2].v - 0.6) <= 0.1 + 1e-9, true)
  local map, a2, b2 = ACV.replace_rows(pts, mv, box, true)
  eq('ml: old row cleared', map[0], false); near('ml: new row', map[6], 0.5); near('range end', b2, 10 + 1 / 64)
  eq('T - sel tool', ACV.key(('T'):byte(), st) and ACV.tool, 'sel'); ACV.tool = 'cur'
  ACV.cycle, ACV.shape, ACV.snap = 8, 'sin', false
  local sr2 = ACV.shape_stroke(0, 15, 1)
  local nrow = 0; for _ in pairs(sr2) do nrow = nrow + 1 end
  eq('shape cycle 8 rows: 2 cycles x 8 points', nrow, 16); ACV.cycle = 4
end
-- 2 ноя: неровная сетка — паттерны / секции / весь отрезок
do
  ACV.marks = { { row = 16, kind = 'pat' }, { row = 40, kind = 'sec' }, { row = 52, kind = 'pat' } }
  ACV.sr0, ACV.sr1, ACV.snap = 0, 64, true
  ACV.gmode = 'pat'
  local a, b = ACV.cell_at(20); eq('pat cell of row 20', a .. '-' .. b, '16-40')
  eq('pat cellw at 45', ACV.cellw(45), 12)
  local r = ACV.at({ gx = 0, gy = 0, gw = 64, gh = 100, r0 = 0, nr = 64 }, 30.5, 50); eq('at snaps to the pattern start', r, 16)
  local sr = ACV.span_rows(0, 0, 63, 1, {}); local k = 0; for _ in pairs(sr) do k = k + 1 end; eq('stroke: a point per pattern', k, 4)
  ACV.gmode = 'sec'; a, b = ACV.cell_at(20); eq('sec cell of row 20', a .. '-' .. b, '0-40')
  ACV.gmode = 'all'; a, b = ACV.cell_at(50); eq('all: one cell', a .. '-' .. b, '0-64')
  ACV.row = 20; ACV.gmode = 'pat'; ACV.key(string.byte('}'), { r0 = 0, r1 = 64 }); eq('} to the next pattern', ACV.row, 40)
  ACV.key(string.byte('{'), { r0 = 0, r1 = 64 }); eq('{ back to the cell start', ACV.row, 16)
  ACV.gmode, ACV.marks = nil, nil
end
print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
