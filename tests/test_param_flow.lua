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
-- test_param_flow.lua (22 окт): поток параметров DSP — столбики кнопок 5..8 положений, перенос колонок, секции
local R = D.param_rows
eq(R({ kind = 'steps', nsteps = 4 }, 10), 1, '4 steps - one row (squares)')
eq(R({ kind = 'steps', nsteps = 5 }, 10), 5, '5 steps - a column of 5 buttons')
eq(R({ kind = 'steps', nsteps = 8 }, 10), 8, '8 steps - 8 buttons')
eq(R({ kind = 'steps', nsteps = 9 }, 10), 1, '9 steps - one row (dropdown)')
eq(R({ kind = 'steps', nsteps = 7 }, 6), 1, '7 steps in a 6-row block - one row (does not fit)')
eq(R({ kind = 'slider' }, 10), 1, 'slider - one row')
local P = { { kind = 'slider' }, { kind = 'slider' }, { kind = 'steps', nsteps = 6 }, { kind = 'slider' } }
local sp, nc = D.param_flow(P, nil, 8, 0)
eq(sp[3][2], 2, 'tall param starts on row 2')
eq(sp[3][3], 6, '…and takes 6 rows')
eq(sp[4][1] .. ':' .. sp[4][2], '1:0', 'next param goes to column 2 (2 + 6 = 8 rows full)')
eq(nc, 2, 'two columns')
local sp2 = D.param_flow({ { kind = 'slider' }, { kind = 'slider' }, { kind = 'slider' }, { kind = 'steps', nsteps = 6 } }, nil, 8, 0)
eq(sp2[4][1] .. ':' .. sp2[4][2], '1:0', 'tall param that does not fit the rest of a column moves to the next')
-- секции: заголовок — своя строка, секция целиком в новую колонку
local H = { [1] = 'OSC', [3] = 'FILTER' }
local sp3, nc3 = D.param_flow({ { kind = 'slider' }, { kind = 'slider' }, { kind = 'steps', nsteps = 5 }, { kind = 'slider' } }, H, 6, 0)
eq(sp3.heads[1][1] .. ':' .. sp3.heads[1][2], '0:0', 'first head at the top')
eq(sp3[1][2], 1, 'param under its head')
eq(sp3.heads[3][1] .. ':' .. sp3.heads[3][2], '1:0', 'FILTER (head + 5 + 1 rows) starts a new column')
eq(sp3[3][1] .. ':' .. sp3[3][2], '1:1', 'its tall param under the head')
eq(nc3, 3, 'sections: FILTER fills column 2 (head + 5), the last slider - column 3')
-- без высоких параметров поток совпадает с прежним (по строке)
local flat = {}; for k = 1, 10 do flat[k] = { kind = 'slider' } end
local sp4, nc4 = D.param_flow(flat, nil, 4, 1)
eq(sp4[5][1] .. ':' .. sp4[5][2], '2:0', 'plain params: 4 per column, from column col0')
eq(nc4, 3, 'plain: 3 columns for 10 params')
print(('%d checks, %d failed'):format(n, bad)); os.exit(bad == 0 and 0 or 1)
