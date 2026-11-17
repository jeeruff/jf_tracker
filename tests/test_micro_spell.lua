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
local fails = 0
local function eq(a, b) if a ~= b then fails = fails + 1; print('FAIL', a, b) end end
eq(D.micro_spell('C-4', nil), 'C-4'); eq(D.micro_spell('C-4', 1), 'C^4'); eq(D.micro_spell('C-4', 3), 'C+4'); eq(D.micro_spell('D-4', -3), 'Dd4')
eq(D.micro_spell('C#4', 3), 'Dd4'); eq(D.micro_spell('C#4', -3), 'C+4'); eq(D.micro_spell('C#4', -2), 'C:4'); eq(D.micro_spell('C#4', 1), 'C˙4')
eq(D.micro_spell('A#3', 3), 'Bd3'); eq(D.micro_spell('E-4', -2), 'Ew4')
D.HM = { root = 5, minor = false }; eq(D.micro_spell('C#4', 0), 'Db4'); eq(D.micro_spell('C#4', nil), 'Db4')
print(fails == 0 and 'micro spell ok' or 'micro spell FAILED'); os.exit(fails == 0 and 0 or 1)
