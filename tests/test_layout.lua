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
    eq(envf ~= nil and envf.w == L2.env_cw, true, 'compact env narrow x' .. sc)
    eq(L2.env_cw < L2.env_w, true, 'compact env thinner x' .. sc)
  end
  state.folds = { B = 'mini' }
  local ok3, L3 = pcall(D.layout, snap, state, 0)
  eq(ok3 and L3.flat[2].folded, true, 'mini fold x' .. sc)
end
print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
