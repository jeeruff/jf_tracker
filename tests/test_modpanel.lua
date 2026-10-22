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
-- test_modpanel.lua (22 окт): панель mod · auto блока трека DSP — секции рисуются на всех вкладках без ошибок,
-- кнопки попадают в hover, ползунок отдаёт диапазон
reaper.time_precise = function() return 1 end
local state = { fontscale = 1, folds = {}, fxcols = 1, envs = true, hscroll = 1, wave = 'spec', hints = true, dsp = true, top = true }
D.set_font(state)
local L = D.layout({ cols = { { guid = 'A', name = 'A', lanes = { { idx = 0, subs = { {} }, items = {} } }, envs = {}, depth = 0 } } }, state, 0)
local col = { guid = 'A', name = 'A' }
local rows = { { label = 'cutoff · Surge', env = true, pts = { { 0, 0 }, { 1, 1 } } }, { label = 'reso · Surge', lfo = true, ismod = true, lfoshape = 4, lfostr = 0.5, sel = true } }
local tm = { rows = rows, nauto = 1, nmod = 1, sel = 'reso · Surge', selflags = {}, wauto = true, wmod = true }
local MODSL = { lfo = { { 'lfo.speed', 'rate', 0.0039, 8, 'hz' } }, acs = { { 'acs.attack', 'attack', 0, 1000, '%d ms' } }, lnk = { { 'plink.scale', 'scale', -1, 1, '%+.2f' } } }
for _, tab in ipairs({ 'lfo', 'acs', 'lnk', 'env', 'pm' }) do
  local m = { tab = tab, act = { lfo = true, pm = true }, vals = {}, shape = 0, envpts = { { 0, 0.2 }, { 1, 0.8 } }, npts = 2,
    pk = { pre = 1, hum = 10, key = true }, curve = { pts = { { 0, 0 }, { 0.5, 0.7 }, { 1, 1 } } } }
  local info = { modsel = function() return m end, modtab = function() return tab end, modsl = MODSL, midi_in = function() return 0, 100, 60 end, pm_phase = function() return 0.5 end }
  for _, w in ipairs({ L.cw * 19, L.cw * 8 }) do
    local hover = {}
    local ok, err = pcall(D.mod_section, L, info, col, tm, 0, 0, w, 20 * L.rh, hover)
    eq(ok, true, 'mod section ' .. tab .. ' w ' .. w .. ' ' .. tostring(err or ''))
    ok, err = pcall(D.auto_section, L, info, col, tm, 0, 0, w, 5 * L.rh, hover)
    eq(ok, true, 'auto section ' .. tab .. ' ' .. tostring(err or ''))
  end
end
-- ползунок: мышь на полосе lfo speed — hover с ключом и диапазоном
do
  local info = { modsel = function() return { tab = 'lfo', act = { lfo = true }, vals = { ['lfo.speed'] = 1 }, shape = 0 } end, modtab = function() return 'lfo' end, modsl = MODSL }
  local found
  for yy = 0, 20 * L.rh, 2 do
    gfx.mouse_x, gfx.mouse_y = math.floor(L.cw * 9 + 4), yy
    local hover = {}
    D.mod_section(L, info, col, tm, 0, 0, L.cw * 19, 20 * L.rh, hover)
    if hover.trkmod and hover.trkmod.what == 'sl' then found = hover.trkmod; break end
  end
  if not found then print('cw', L.cw, 'rh', L.rh, 'pad', L.pad) end
  eq(found and found.key, 'lfo.speed', 'slider hover key')
  eq(found and found.hi, 8, 'slider range')
end
print(('test_modpanel: %d checks, %d failed'):format(n, bad)); os.exit(bad == 0 and 0 or 1)
