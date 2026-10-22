-- test_layout.lua — D.layout на заглушке gfx (2 окт: ловит ошибки раскладки,
-- которые раньше видно было только по падению живого трекера)
local DIR = debug.getinfo(1, 'S').source:match('^@(.*)/tests/') or '.'
gfx = { w = 1600, h = 900, texth = 8, x = 0, y = 0, a = 1, mode = 0, dest = -1, mouse_x = 0, mouse_y = 0, mouse_cap = 0,
  measurestr = function(s) return #tostring(s) * 8, 8 end, setfont = function() end, set = function() end, rect = function() end,
  line = function() end, drawstr = function() end, blit = function() end, setimgdim = function() end, getpixel = function() return 0, 0, 0 end,
  setpixel = function() end }
reaper = setmetatable({}, { __index = function() return function() return nil end end })
local n, bad = 0, 0
local function eq(a, b, what) n = n + 1; if a ~= b then bad = bad + 1; print(('FAIL %s: %s ~= %s'):format(what, tostring(a), tostring(b))) end end
local C = { 0.5, 0.5, 0.5 }
local U = setmetatable({ readable = function(c) return c end, mix = function(a) return a end, theme = function(_, d) return d end,
  tint = function(c) return c end, TEXT = C, BG = C, GREY = C, CYAN = C, AMBER = C, RED = C, GREEN = C, DIM = C, LINE = C, PANEL = C },
  { __index = function() return C end })
local D = dofile(DIR .. '/jf_tracker_draw.lua')
D.init(U, nil, nil)
-- test_cursor_col.lua (22 окт): имя колонки под курсором у клавиатуры — по виду колонки, не по номеру поля
local F = D.cursor_field_name
eq(F({ col = {} }, { field = 1 }), 'note', 'note field')
eq(F({ col = {} }, { field = 2 }), 'vol', 'vol field')
eq(F({ col = {} }, { field = 3 }), 'delay', 'delay field')
eq(F({ col = {} }, { field = 4 }), 'fx 1', 'first fx field')
eq(F({ col = {} }, { field = 1, sub = 'inst' }), 'inst', 'instrument sub')
eq(F({ col = {}, ml = { kind = 'pb', name = 'PB' } }, { field = 1 }), 'PB', 'pitch bend lane is not note')
eq(F({ col = {}, ml = { kind = 'cc', name = 'CC74' } }, { field = 1 }), 'CC74', 'cc lane')
eq(F({ col = {}, ml = { kind = 'cmd', name = 'cmd' } }, { field = 1 }), 'cmd', 'master cmd')
eq(F({ col = {}, ml = { kind = 'chd', name = 'chord' } }, { field = 1 }), 'chord', 'master chord')
eq(F({ col = {}, env = { name = 'Volume' } }, { field = 1 }), 'Volume', 'envelope')
eq(F({ col = {}, folded = true }, { field = 1 }), 'folded', 'folded track')
-- живая раскладка: у трека с PB-лейном последняя колонка трека — лейн, курсор на нём — «PB»
do
  local c = { guid = 'M', name = 'M', lanes = { { idx = 0, subs = { {} }, items = {} } }, envs = {}, depth = 0,
              mlanes = { { kind = 'pb', name = 'PB', ev = {}, rows = {} } } }
  local state = { fontscale = 1, folds = {}, fxcols = 1, envs = true, hscroll = 1, wave = 'spec', hints = true, dsp = true, top = true, midilanes = true }
  D.set_font(state)
  local ok, L = pcall(D.layout, { cols = { c } }, state, 0)
  eq(ok, true, 'layout ok ' .. tostring(not ok and L or ''))
  if ok then
    local found
    for fi, f in ipairs(L.flat) do if f.ml then found = F(f, { field = 1, fi = fi }) end end
    eq(found, 'PB', 'pb lane in the layout names PB')
  end
end
print(('%d checks, %d failed'):format(n, bad)); os.exit(bad == 0 and 0 or 1)
