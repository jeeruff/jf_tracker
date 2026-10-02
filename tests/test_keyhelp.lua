-- тесты контекстной справки и Vim-клавиш матрицы (стабы, без REAPER)
local DIR = debug.getinfo(1, 'S').source:match('^@(.*)/tests/') or '.'
local n, bad = 0, 0
local function eq(a, b, what) n = n + 1; if a ~= b then bad = bad + 1; print(('FAIL %s: %s ~= %s'):format(what, tostring(a), tostring(b))) end end
local KH = dofile(DIR .. '/jf_tracker_keyhelp.lua')
eq(KH.token(13), 'Enter', 'token enter'); eq(KH.token(4), '^D', 'token ^D'); eq(KH.token(100), 'd', 'token d')
eq(KH.token(1685026670), 'Down', 'token down')
-- dd ищется раньше d; одиночный d тоже подсвечивает
local i_dd = KH.match('matrix', 'd', 'd')
eq(KH.PAGES.matrix.e[i_dd].k, 'dd', 'match dd')
eq(KH.PAGES.matrix.e[KH.match('matrix', 'D')].k, 'D ^D', 'match D')
eq(KH.PAGES.matrix.e[KH.match('matrix', '^D')].k, 'D ^D', 'match ^D')
eq(KH.match('matrix', '~'), nil, 'no match')
KH.press('matrix', ('o'):byte(), 10.0)
eq(KH.flash and KH.PAGES.matrix.e[KH.flash.i].k, 'o O', 'flash o')
KH.press('matrix', ('y'):byte(), 10.2); KH.press('matrix', ('y'):byte(), 10.3)
eq(KH.PAGES.matrix.e[KH.flash.i].k, 'yy Y', 'flash yy')
-- поиск: все страницы, текущая первой
KH.page = 'matrix'; KH.query = 'dup'
local rows = KH.rows()
eq(rows[1] and rows[1].page, 'matrix', 'search current page first')
KH.query = 'zzzzqq'; eq(#KH.rows(), 0, 'search nothing')
KH.query = ''
eq(KH.key(('a'):byte()), true, 'type'); eq(KH.query, 'a', 'query a')
eq(KH.key(8), true, 'bs'); eq(KH.query, '', 'query empty')
eq(KH.key(27), 'leave', 'esc leaves')
KH.page = 'tracker'; KH.key(1919379572); eq(KH.page, 'insert', 'right = next page')
for _, pg in ipairs(KH.ORDER) do eq(KH.PAGES[pg] ~= nil, true, 'page ' .. pg) end

-- матрица: клавиши → вызовы ctx
_G.gfx = { mouse_x = 0, mouse_y = 0 }
local calls = {}
local function rec(name) return function(...) local a = { ... }; calls[#calls + 1] = name .. (a[1] ~= nil and (':' .. tostring(a[1])) or '') .. (a[2] ~= nil and (':' .. tostring(a[2])) or '') end end
local ctx = setmetatable({ mods = function() return {} end, msg = function() end, scroll_to = function() end, region_cursor = function() end,
  edit = { undo = rec('undo'), redo = rec('redo') } }, { __index = function(t, k) local f = rec(k); rawset(t, k, f); return f end })
local MX = dofile(DIR .. '/jf_tracker_matrix.lua')
MX.init({}, ctx)
local regs = { { pos = 0, rgnend = 2, r0 = 0, r1 = 16, name = 'a', idx = 1 }, { pos = 2, rgnend = 4, r0 = 16, r1 = 32, name = 'b', idx = 2 } }
local snap = { cols = { {}, {} } }
local function keys(str) calls = {}; for ch in str:gmatch('.') do MX.key(ch:byte(), regs, snap) end; return table.concat(calls, ' ') end
eq(keys('dd'), 'slot_delete', 'dd')
eq(keys('yy'), 'slot_yank', 'yy')
eq(keys('Y'), 'slot_yank', 'Y')
eq(keys('o'), 'slot_new:empty:false', 'o')
eq(keys('O'), 'slot_new:empty:true', 'O')
eq(keys('p'), 'slot_new:put:false', 'p')
eq(keys('P'), 'slot_new:put:true', 'P')
eq(keys('D'), 'slot_new:dup', 'D')
calls = {}; MX.key(4, regs, snap); eq(table.concat(calls, ' '), 'slot_new:dup', '^D')
eq(keys('cw'), 'mx_name_prompt', 'cw')
eq(keys('cc'), 'mx_name_prompt', 'cc')
eq(keys('n'), 'mx_name_prompt', 'n')
eq(keys(']'), 'slot_len_step:bar:1', ']')
eq(keys('['), 'slot_len_step:bar:-1', '[')
eq(keys('}'), 'slot_len_step:step:1', '}')
eq(keys('x'), 'mx_block:cut', 'x')
MX.cur = { ri = 2, ci = 1 }; keys('gg'); eq(MX.cur.ri, 1, 'gg')
keys('G'); eq(MX.cur.ri, 2, 'G')
eq(keys('vy'), 'mx_block:copy', 'v y = block copy'); MX.anchor = nil
print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
