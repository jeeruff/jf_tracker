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
-- test_mixsnaps.lua (22 окт): панель снапшотов микшера (как окно SWS) и XY микшера рисуются без ошибок
-- на разной высоте; строки и кнопки попадают в hover
reaper.time_precise = function() return 1 end
local state = { fontscale = 1, folds = {}, fxcols = 1, envs = true, hscroll = 1, wave = 'spec', hints = true, dsp = true, top = true }
D.set_font(state)
local L = D.layout({ cols = { { guid = 'A', name = 'A', lanes = { { idx = 0, subs = { {} }, items = {} } }, envs = {}, depth = 0 } } }, state, 0)
local TOG = { { 'PAN', 'pan' }, { 'VOL', 'volume' }, { 'MUTE', 'mute' }, { 'FX', 'fx chain' }, { 'SOLO', 'solo' }, { 'SEND', 'sends' }, { 'VIS', 'vis' }, { 'TOGSEL', 'selection' } }
local OPT = { { 'APPLYLOAD', 'filter on recall' }, { 'SELONLY', 'save sel' }, { 'SELONLYRECALL', 'recall sel' }, { 'SHOWONLYSEL', 'show sel' } }
-- 30 окт: вкладки xy нет — XY под списком, когда под ним есть место
do local tab = 'list'
  for _, hh in ipairs({ 8 * L.rh, 30 * L.rh, 45 * L.rh }) do
    L.mix_pane = { x = 0, y = 100, w = 260, h = hh }; L.mix_y, L.mix_h = 100, hh
    L.cols = { { x = 260 } }
    local info = { msn_tog = TOG, msn_opt = OPT, mixsnaps = { tab = tab, rows = { { slot = 1, name = 'Verse', date = '22.10.26', time = '21:40:00' }, { slot = 3, name = 'Drop', date = '', time = '' } },
      cur = 3, tog = { PAN = true, VOL = true }, opt = {}, mode = 'custom', xy = { has = { true, true }, x = 0.3, y = 0.6 } } }
    local found = {}
    for yy = 100, 100 + hh, 3 do
      for xx = 4, 250, 6 do
        gfx.mouse_x, gfx.mouse_y = xx, yy
        local hover = {}
        local ok, err = pcall(D.draw_mixsnaps, L, info, hover)
        if not ok then eq(ok, true, tab .. ' h ' .. hh .. ': ' .. tostring(err)); goto done end
        if hover.mixsnap then found[hover.mixsnap.what] = true end
      end
    end
    ::done::
    eq(found.tab, nil, tab .. ' ' .. hh .. ': no tabs')
    do
      eq(found.row, true, 'list ' .. hh .. ': a row in hover'); eq(found.new, true, 'list ' .. hh .. ': new button')
      if hh > 20 * L.rh then eq(found.tog, true, 'tall: filter checkboxes inline'); eq(found.mode, true, 'tall: modes inline')
      else eq(found.filtermenu, true, 'low: filter button instead') end
      if hh > 20 * L.rh then eq(found.xyc, true, hh .. ': XY corners under the list'); eq(found.xypad, true, hh .. ': XY pad under the list')
      else eq(found.xypad, nil, 'low: no room - no XY') end
    end
  end
end
print(('test_mixsnaps: %d checks, %d failed'):format(n, bad)); os.exit(bad == 0 and 0 or 1)
