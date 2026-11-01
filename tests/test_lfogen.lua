-- test_lfogen.lua — генератор LFO без REAPER: lua tests/test_lfogen.lua
package.path = './?.lua;' .. package.path
gfx = { mouse_x = 0, mouse_y = 0 }
local LG = dofile('jf_tracker_lfogen.lua')
local n, bad = 0, 0
local function eq(name, got, want)
  n = n + 1
  if got ~= want then bad = bad + 1; print(('FAIL %s: got %s, want %s'):format(name, tostring(got), tostring(want))) end
end
local function near(name, got, want) eq(name, math.abs((got or 1e9) - want) < 1e-6, true) end

-- формы
near('sin 0', LG.wave('sin', 0), 0); near('sin 1/4', LG.wave('sin', 0.25), 1)
near('tri 1/4', LG.wave('tri', 0.25), 1); near('tri 3/4', LG.wave('tri', 0.75), -1)
near('saw+ 0', LG.wave('saw+', 0), -1); near('saw- 0', LG.wave('saw-', 0), 1)
eq('sqr halves', LG.wave('sqr', 0.2) == 1 and LG.wave('sqr', 0.7) == -1, true)

-- sin: res точек на период, первая в r0, значения в 0..1
LG.shape, LG.period, LG.depth, LG.center, LG.phase, LG.res = 'sin', 16, 1, 0.5, 0, 16
local p = LG.points(0, 32)
eq('sin count 2 periods', #p, 32)
near('sin first row', p[1].row, 0); near('sin first value', p[1].v, 0.5)
near('sin peak at row 4', p[5].v, 1)
local inside = true
for _, q in ipairs(p) do if q.v < 0 or q.v > 1 or q.row < 0 or q.row >= 32 then inside = false end end
eq('sin points inside span and range', inside, true)
-- глубина и центр
LG.depth, LG.center = 0.4, 0.3
p = LG.points(0, 16)
near('depth: peak = center + depth/2', p[5].v, 0.5); near('depth: trough', p[13].v, 0.1)
-- клип за пределами 0..1
LG.depth, LG.center = 1, 0.9
p = LG.points(0, 16)
eq('clipped to 1', p[5].v, 1)

-- sqr: 2 точки на период, ступенькой
LG.shape, LG.depth, LG.center = 'sqr', 1, 0.5
p = LG.points(0, 32)
eq('sqr count', #p, 4); eq('sqr shape square', p[1].shape, 1); near('sqr high', p[1].v, 1); near('sqr low at half', p[2].row, 8)
-- saw: начало + ступень перед концом
LG.shape = 'saw+'
p = LG.points(0, 16)
eq('saw count', #p, 2); near('saw starts low', p[1].v, 0); eq('saw end point is square', p[2].shape, 1)
-- фаза сдвигает начало периода; первая точка всё равно в r0
LG.shape, LG.phase = 'sqr', 0.25
p = LG.points(0, 16)
near('phase: first point at r0', p[1].row, 0); near('phase: next edge at 4', p[2].row, 4)
LG.phase = 0
-- спан не с нуля
LG.shape = 'sin'
p = LG.points(10, 20)
near('offset span starts at r0', p[1].row, 10)
eq('offset span ends before r1', p[#p].row < 20, true)
-- rnd повторяем при том же seed
LG.shape = 'rnd'
local a = LG.points(0, 16); local b = LG.points(0, 16)
eq('rnd repeatable', a[3].v, b[3].v); eq('rnd 4 steps', #a, 4)

-- поля (1 — type, 2 — shape, 3 — period, 8 — make AI)
LG.shape = 'sin'; LG.adjust(3, 1); eq('shape cycles', LG.shape, 'tri')
LG.period = 16; LG.adjust(4, -100); eq('period clamps', LG.period, 1)
LG.sel = 9; eq('Enter on button -> ai', LG.key(13), 'ai')
LG.period = 16

-- тип: podkat меняет набор полей
LG.adjust(1, 1); eq('type podkat', LG.type, 'podkat')
local has = {}; for _, f in ipairs(LG.FIELDS) do has[f.key] = true end
eq('podkat has lead', has.lead, true); eq('podkat has no shape', has.shape, nil); eq('events: no sens', has.sens, nil)
LG.hits = 'transients'; LG.FIELDS = LG.fields(); has = {}; for _, f in ipairs(LG.FIELDS) do has[f.key] = true end
eq('transients: sens shown', has.sens, true)
-- подкат: duck вниз от center; к хиту достигает center - depth; потом возврат
LG.lead, LG.hold, LG.release, LG.curve, LG.depth, LG.center, LG.dir = 4, 1, 2, 0, 0.5, 1, 'duck'
local pk = LG.podkat_points({ 8 }, 0, 16)
-- значение кривой в строке: линейно между точками (как огибающая с формой lin)
local function at(pts, row)
  for i = 1, #pts do
    local a, b = pts[i], pts[i + 1]
    if not b or row < b.row - 1e-9 then
      if not b or a.shape == 1 or row <= a.row then return { v = a.v } end
      return { v = a.v + (b.v - a.v) * (row - a.row) / (b.row - a.row) }
    end
  end
  return pts[#pts]
end
near('podkat rest before lead', at(pk, 3).v, 1)
near('podkat bottom at hit', at(pk, 8).v, 0.5)
eq('podkat recovers after release', at(pk, 15).v > 0.95, true)
eq('podkat thinned (rdp)', #pk < 16 / 0.125, true)
-- линейная кривая: середина lead — полпути
pk = LG.podkat_points({ 8 }, 0, 16)
near('podkat linear mid-lead', at(pk, 6).v, 0.75)
-- swell вверх
LG.dir, LG.center = 'swell', 0
pk = LG.podkat_points({ 8 }, 0, 16)
near('swell peak at hit', at(pk, 8).v, 0.5)
-- follow: источник — ступенька 0 → 1 на строке 4, без сглаживания
LG.type = 'follow'; LG.FIELDS = LG.fields()
LG.attack, LG.frel, LG.shift, LG.invert, LG.depth, LG.center = 0, 0, 0, false, 1, 0.5
local src = function(r) return r >= 4 and 1 or 0 end
local fp = LG.follow_points(src, 0, 8)
near('follow low before', at(fp, 2).v, 0); near('follow high after', at(fp, 6).v, 1)
LG.invert = true; fp = LG.follow_points(src, 0, 8)
near('follow invert', at(fp, 6).v, 0)
LG.invert = false; LG.shift = 2; fp = LG.follow_points(src, 0, 8)
near('follow shift = lookahead', at(fp, 2.5).v, 1)
LG.shift = 0
-- Enter на источнике follow env — выбор огибающей
LG.fsrc = 'env'; for i, f in ipairs(LG.FIELDS) do if f.key == 'src' then LG.sel = i end end
eq('Enter on env source -> pick', LG.key(13), 'pick')
LG.type = 'lfo'; LG.FIELDS = LG.fields()
eq('g -> ai', LG.key(('g'):byte()), 'ai'); eq('p -> points', LG.key(('p'):byte()), 'points')
eq('Esc leaves', LG.key(27), 'leave'); eq('L is a fine step (not leave)', LG.key(('L'):byte()), true)

print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
