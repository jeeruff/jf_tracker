-- test_piano_strip.lua — пианинка слоя пианино (4 окт): место в раскладке и клавиши
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
local snap = { cols = { { guid = 'A', name = 'A', lanes = { { idx = 0, subs = { {} }, items = {} } }, envs = {}, depth = 0 } } }
local state = { fontscale = 1, folds = {}, fxcols = 1, envs = false, hscroll = 1, wave = 'off' }
D.set_font(state)
local L0 = D.layout(snap, state, 0)
-- 5 окт: полоса транспорта есть всегда, клавиатура в ней — по m
eq(L0.piano_h > 0, true, 'transport strip always reserved')
state.piano_strip = true
local L1 = D.layout(snap, state, 0)
eq(L1.piano_h, L0.piano_h, 'keyboard on / off does not move the layout')
-- 15 окт: режим — строкой в полосе (две строки под крупное слово), статус — всегда внизу окна
eq(L1.status_h, L1.rh + 4, 'status bar always at the window bottom')
local L3 = D.layout(snap, { fontscale = 1, folds = {}, fxcols = 1, envs = false, hscroll = 1, wave = 'off' }, 0)
eq(L3.piano_h, L0.piano_h, 'no option moves the strip')
local r = D.piano_strip(L1, 0, 0, 800, L1.piano_h, { octave = 4, held = { [0] = true }, last = 2 })
eq(r.white, 10, '10 white keys'); eq(r.black, 7, '7 black keys'); eq(r.letters, 17, 'all letters')
local r2 = D.piano_strip(L1, 0, 0, 120, L1.piano_h, { octave = 4, held = {} })
eq(r2.letters, 0, 'narrow: no letters (no overlap)')
print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
