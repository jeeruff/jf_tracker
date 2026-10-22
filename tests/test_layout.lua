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
local function col(guid, nsub, envs)
  local subs = {}; for i = 1, nsub do subs[i] = {} end
  return { guid = guid, name = guid, lanes = { { idx = 0, subs = subs, items = {} } }, envs = envs or {}, depth = 0 }
end
local snap = { cols = { col('A', 1), col('B', 4, { { name = 'Volume' } }), col('C', 1) } }
for _, sc in ipairs({ 1, 2, 4 }) do
  local state = { fontscale = sc, folds = {}, fxcols = 1, envs = true, hscroll = 1, wave = 'spec', hints = true, dsp = true, top = true }
  D.set_font(state)
  local ok, L = pcall(D.layout, snap, state, 0)
  eq(ok, true, 'layout x' .. sc .. ' ' .. tostring(not ok and L or ''))
  if ok then
    eq(#L.flat, 1 + 4 + 1 + 1, 'flat entries x' .. sc)
    eq(L.flat[3].narrow, true, 'chord sub narrow x' .. sc)
    eq(L.flat[3].w < L.flat[2].w, true, 'narrow sub thinner x' .. sc)
  end
  state.folds = { B = true }
  local ok2, L2 = pcall(D.layout, snap, state, 0)
  eq(ok2, true, 'compact layout x' .. sc .. ' ' .. tostring(not ok2 and L2 or ''))
  if ok2 then
    eq(L2.flat[2].compact, true, 'compact sub x' .. sc)
    local envf; for _, f in ipairs(L2.flat) do if f.env then envf = f end end
    eq(envf ~= nil and envf.w <= L2.env_cw, true, 'compact env narrow x' .. sc)   -- 21 окт: у края окна (x4) — обрезана, но не шире узкой
    eq(L2.env_cw < L2.env_w, true, 'compact env thinner x' .. sc)
  end
  state.folds = { B = 'mini' }
  local ok3, L3 = pcall(D.layout, snap, state, 0)
  eq(ok3 and L3.flat[2].folded, true, 'mini fold x' .. sc)
end
-- 11 окт: wave only — аудио-подколонка полосой волны, MIDI рядом как была; зум трека расширяет
do
  local ca = col('AU', 2); ca.lanes[1].audio_sub = { true }
  local s2 = { cols = { ca, col('M', 1) } }
  local state = { fontscale = 2, folds = {}, fxcols = 1, envs = false, hscroll = 1, wave = 'off', waveonly = true }
  D.set_font(state)
  local ok, L = pcall(D.layout, s2, state, 0)
  eq(ok, true, 'wave only layout ' .. tostring(not ok and L or ''))
  if ok then
    eq(L.flat[1].G and L.flat[1].G.wave_only, true, 'audio sub is a wave strip')
    eq(L.flat[2].G and L.flat[2].G.wave_only or nil, nil, 'second (MIDI) sub stays')
    eq(L.flat[1].w < L.flat[3].w, true, 'wave strip narrower than a normal column')
    local w0 = L.flat[1].w
    state.wlevel = { AU = 4 }
    local ok2, L2 = pcall(D.layout, s2, state, 0)
    eq(ok2 and L2.flat[1].w > w0, true, 'track zoom widens the strip')
  end
  state.textonly = true
  local ok3, L3 = pcall(D.layout, s2, state, 0)
  eq(ok3 and (L3.flat[1].G and L3.flat[1].G.wave_only or nil), nil, 'text only wins')
end
-- PT-mode (3 окт): ровно 4 канала, без огибающих и свёрток, x4 разрешён
do
  local cols6 = {}
  for k = 1, 6 do cols6[k] = col('T' .. k, 1, { { name = 'Volume' } }) end
  local state = { fontscale = 4, folds = { T2 = 'mini' }, fxcols = 1, envs = true, hscroll = 1, wave = 'off', ptmode = true }
  D.set_font(state)
  gfx.w = 4000
  local ok, L = pcall(D.layout, { cols = cols6 }, state, 0)
  eq(ok, true, 'pt layout ' .. tostring(not ok and L or ''))
  if ok then
    eq(#L.cols, 4, 'pt: 4 channels shown')
    eq(L.pt_n, 4, 'pt: counted 4'); eq(L.pt_avail, 6, 'pt: 6 available')
    local envs = 0; for _, f in ipairs(L.flat) do if f.env then envs = envs + 1 end end
    eq(envs, 0, 'pt: no envelope columns')
    eq(L.cols[2].folded, false, 'pt: folds ignored')
  end
  gfx.w = 1600
end
-- 22 окт: zz в DSP — микшер над DSP на всё окно: трекер спрятан, микшер в своём листе (не поверх трекера)
do
  D.panes = dofile(DIR .. '/jf_tracker_panes.lua')
  local m = D.panes.DEFAULT()
  D.panes.zoom_multi(m, { 'mixer', 'dsp' }, { 0.3, 0.7 })
  local c = { guid = 'A', name = 'A', lanes = { { idx = 0, subs = { {} }, items = {} } }, envs = {}, depth = 0 }
  local state = { fontscale = 1, folds = {}, fxcols = 1, envs = true, hscroll = 1, wave = 'spec', hints = true, dsp = true, top = true,
    panes_ui = true, panes = m, mixer = true }
  D.set_font(state)
  local ok, L = pcall(D.layout, { cols = { c } }, state, 0)
  eq(ok, true, 'zoomv layout ' .. tostring(not ok and L or ''))
  if ok then
    eq(L.pn_hidden_tracker, true, 'zoomv: tracker hidden')
    eq(L.body_h, 0, 'zoomv: no tracker rows under the mixer')
    eq(L.pn and L.pn.by_panel.dsp ~= nil, true, 'zoomv: dsp cell')
  end
  D.panes = nil
end
print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
