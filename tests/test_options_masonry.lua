-- test_options_masonry.lua — опции рамками в колонки (15 окт): всё на одном экране, рамки не
-- пересекаются и не выходят за окно, каждая строка на месте; не влезает / поиск / хоткеи — список
local DIR = debug.getinfo(1, 'S').source:match('^@(.*)/tests/') or '.'
_G.gfx = { mouse_x = -1, mouse_y = -1, mouse_cap = 0, rect = function() end }
local U = { measure = function(s) return #s * 8 end, set = function() end, text = function() end, tint = function(c) return c end,
  BG = {}, TEXT = {}, AMBER = {}, LINE = {}, GREY = {}, CYAN = {}, DIM = {}, PANEL = {}, RED = {} }
local O = dofile(DIR .. '/jf_tracker_options.lua')
O.init(U, { fit = function(s) return s end, mods = function() return {} end })
local n, bad = 0, 0
local function eq(name, got, want) n = n + 1; if got ~= want then bad = bad + 1; print(('FAIL %s: got %s want %s'):format(name, tostring(got), tostring(want))) end end

-- разделы как в настоящем окне: 6, 21, 21, 19, 11, 14 строк
local items = {}
for s, cnt in ipairs({ 6, 21, 21, 19, 11, 14 }) do
  if s > 1 then items[#items + 1] = { sep = true, title = '', gap = true } end
  items[#items + 1] = { sep = true, title = 'sect' .. s }
  for k = 1, cnt do items[#items + 1] = { key = 's' .. s .. k, label = 'opt ' .. s .. '.' .. k, kind = 'toggle', get = function() return false end, set = function() end } end
end
O.open(items)
local L = { rh = 16, pad = 4, cw = 8 }
O.draw(L, 2400, 1200)   -- 18 окт: окно опций в 1.5 раза меньше трекера
eq('wide window: frames in columns', O.masonry_on, true)
local plan = O.masonry_plan(L, 0, 0, 2000, 50 * 16)
eq('plan exists', plan ~= nil, true)
eq('several columns', plan and plan.ncols > 1, true)
-- каждая не-sep строка — одно место
local want, got = 0, 0
for _, it in ipairs(O.items) do if not it.sep then want = want + 1 end end
got = #plan.place
eq('every option placed', got, want)
-- рамки: внутри окна и без пересечений
local inside, overlap = true, false
for a, f in ipairs(plan.frames) do
  if f.x < 0 or f.x + f.w > 2000 or f.y < 0 or f.y + f.h > 50 * 16 then inside = false end
  for b, g in ipairs(plan.frames) do
    if a < b and f.x < g.x + g.w and g.x < f.x + f.w and f.y < g.y + g.h and g.y < f.y + f.h then overlap = true end
  end
end
eq('frames inside', inside, true)
eq('frames do not overlap', overlap, false)
-- строки внутри своей рамки
local rows_in = true
for _, pl in ipairs(plan.place) do
  local ok = false
  for _, f in ipairs(plan.frames) do if pl.i >= f.i0 and pl.i <= f.i1 and pl.x >= f.x and pl.x + pl.w <= f.x + f.w and pl.y >= f.y and pl.y + 16 <= f.y + f.h then ok = true end end
  if not ok then rows_in = false end
end
eq('rows inside their frame', rows_in, true)
-- порядок чтения: разделы по колонкам слева направо, внутри — сверху вниз
local order_ok = true
for k = 2, #plan.frames do
  local p, c = plan.frames[k - 1], plan.frames[k]
  if not (c.x > p.x or (c.x == p.x and c.y > p.y)) then order_ok = false end
end
eq('reading order kept', order_ok, true)
-- колонки ровные: высота — наименьшая, при которой влезает
local plan2 = O.masonry_plan(L, 0, 0, 2000, 200 * 16)
eq('tall window still balances (same columns)', plan2 and plan2.ncols, plan.ncols)
-- 31 окт: раздел, что влезает в колонку, — одной рамкой (было: колонки ровнялись по высоте и резали разделы
-- модулей на рамки по 2 строки с той же подписью)
local plan3 = O.masonry_plan(L, 0, 0, 2000, 32 * 16)
eq('plan for a middle window', plan3 ~= nil, true)
if plan3 then
  local seen = {}
  for _, f in ipairs(plan3.frames) do if f.title ~= '' then seen[f.title] = (seen[f.title] or 0) + 1 end end
  local whole = true
  for _, c in pairs(seen) do if c > 1 then whole = false end end
  eq('sections that fit stay in one frame', whole, true)
  eq('middle window: every option placed', #plan3.place, want)
end
-- узкое окно / мало высоты — список со скроллом
local small = O.masonry_plan(L, 0, 0, 500, 10 * 16)   -- 20 окт: не влезло — колонки с прокруткой, не список
eq('too small: plan scrolls', small ~= nil and (small.over or 0) > 0, true)
O.typing, O.query = false, 'opt'; O.rebuild()
eq('search: list', O.masonry_plan(L, 0, 0, 2000, 800), nil)
O.query = ''; O.rebuild()
O.items[#O.items + 1] = { label = 'j', kind = 'action', hk = true, desc = 'down' }
eq('hotkeys: list', O.masonry_plan(L, 0, 0, 2000, 800), nil)
print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
