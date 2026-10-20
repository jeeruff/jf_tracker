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
eq(KH.PAGES.matrix.e[KH.match('matrix', 'p', 'y')].k, 'yp', 'match yp')
eq(KH.match('matrix', '~'), nil, 'no match')
KH.press('matrix', ('o'):byte(), 10.0)
eq(KH.flash and KH.PAGES.matrix.e[KH.flash.i].k, 'o O', 'flash o')
KH.press('matrix', ('y'):byte(), 10.2); KH.press('matrix', ('y'):byte(), 10.3)
eq(KH.PAGES.matrix.e[KH.flash.i].k, 'yy', 'flash yy')
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
eq(keys('Y'), '', 'Y is gone (yy yanks)')
eq(keys('o'), 'slot_new:empty:false', 'o')
eq(keys('O'), 'slot_new:empty:true', 'O')
eq(keys('p'), 'slot_new:put:false', 'p')
eq(keys('P'), 'slot_new:put:true', 'P')
eq(keys('yp'), 'slot_new:clone', 'yp duplicates')
MX.cur = { ri = 1, ci = 1 }; eq(keys('D'), 'mx_block:cut', '10 окт: D on a cell cuts it')
MX.cur = { ri = 1, ci = -1 }; eq(keys('D'), 'slot_delete', 'D on the slot number deletes the slot')
calls = {}; MX.key(8, regs, snap); eq(table.concat(calls, ' '), 'slot_delete', 'Backspace on the slot number deletes the slot (not the tracker)')
MX.cur = { ri = 1, ci = 1 }
do local gr = { regs[1], { gap = true, pos = 2, rgnend = 3 }, { gap = true, pos = 3, rgnend = 4 }, regs[2] }
  MX.key(('w'):byte(), gr, snap); eq(MX.cur.ri, 4, 'w skips the free bars to the next slot')
  MX.key(('b'):byte(), gr, snap); eq(MX.cur.ri, 1, 'b back to the previous slot')
  MX.key(('e'):byte(), gr, snap); eq(MX.cur.ri, 3, 'e - the last bar before the next slot') end
MX.cur = { ri = 1, ci = 1 }
eq(keys('n'), 'mx_name_prompt', 'n renames')
eq(keys('n'), 'mx_name_prompt', 'n')
eq(keys(']'), 'slot_len_step:bar:1', ']')
eq(keys('['), 'slot_len_step:bar:-1', '[')
eq(keys('}'), 'slot_len_step:step:1', '}')
eq(keys('x'), 'mx_block:cut', 'x')
MX.cur = { ri = 2, ci = 1 }; keys('gg'); eq(MX.cur.ri, 1, 'gg')
keys('G'); eq(MX.cur.ri, 2, 'G')
eq(keys('vy'), 'mx_block:copy', 'v y = block copy'); MX.anchor = nil
-- браузер эффектов (2 окт)
local FB = dofile(DIR .. '/jf_tracker_fxbrowser.lua')
eq(FB.short('VST3: Pro-Q 3 (FabFilter)'), 'Pro-Q 3 (FabFilter)', 'fx short name')
FB.list = { { label = 'VST: ReaEQ (Cockos)', data = 'ReaEQ' }, { label = 'JS: jf_tracker_scope', data = 'js1' },
  { label = 'VST3: Pro-Q 3 (FabFilter)', data = 'pq' }, { label = 'AU: AUDelay (Apple)', data = 'aud' } }
FB.query = ''; eq(#FB.results(), 4, 'fx all')
for ch in ('eq'):gmatch('.') do FB.key(ch:byte()) end
eq(FB.results()[1] and FB.results()[1].it.data, 'ReaEQ', 'fx eq: ReaEQ first (word start)')
FB.key(27); eq(FB.query, '', 'fx esc clears'); eq(FB.key(27), 'leave', 'fx esc leaves')
for ch in ('del !apple'):gmatch('.') do FB.key(ch:byte()) end
eq(#FB.results(), 0, 'fx negation')
FB.query = ''; FB.cur = 1; FB.key(1685026670); eq(FB.cur, 2, 'fx down'); eq(FB.key(13), 'add', 'fx enter adds')
-- DSP-грамматика (2 окт)
local DK = dofile(DIR .. '/jf_tracker_dspkeys.lua')
local dcalls = {}
local dctx = setmetatable({ msg = function() end }, { __index = function(t, k) local f = function(...) local a = { ... }; dcalls[#dcalls + 1] = k .. ':' .. table.concat((function() local o = {}; for i = 1, #a do o[i] = tostring(a[i]) end; return o end)(), ':') end; rawset(t, k, f); return f end })
DK.init(dctx)
local function dk(str, sel) dcalls = {}; for ch in str:gmatch('.') do DK.key(ch:byte(), sel, 4, 8, {}) end; return table.concat(dcalls, ' ') end
local sel = { fx = 2, param = 1 }
eq(dk('dd', sel), 'dsp_delete:2:2', 'dsp dd')
eq(DK.pending_hint(), nil, 'dsp hint cleared')
DK.key(('d'):byte(), sel, 4, 8, {}); eq((DK.pending_hint() or ''):match('^d: d delete fx') ~= nil, true, 'dsp d hint'); DK.key(27, sel, 4, 8, {})
eq(dk('dc', sel), 'dsp_unpack:2', 'dsp dc')
eq(dk('yy', sel), 'dsp_yank:2', 'dsp yy')
eq(dk('p', sel), 'dsp_paste:2:true', 'dsp p')
eq(dk('cc', sel), 'dsp_pack:2:2', 'dsp cc')
eq(dk('aa', sel), 'dsp_automate:2:1', 'dsp aa')
eq(dk('ap', sel), 'dsp_pick_param:2', 'dsp ap')
eq(dk('ad', sel), 'dsp_unautomate:2:1', 'dsp ad')
eq(dk('ai', sel), 'dsp_autoitem:2:1', 'dsp ai')
eq(dk('vlc', sel), 'dsp_pack:2:3', 'dsp v l c = pack range'); eq(sel.fx, 3, 'dsp l moved')
eq(dk('vhd', sel), 'dsp_delete:2:3', 'dsp v h d = delete range')
eq(DK.key(27, sel, 4, 8, {}), 'leave', 'dsp esc leaves')
-- 21 окт: модификаторы в записях справки
local m, r = KH.mods_of('Ctrl+Shift+H'); eq(m.ctrl and m.shift and r, 'H', 'mods Ctrl+Shift+H')
m, r = KH.mods_of('^A'); eq(m.ctrl and r, 'A', 'mods ^A'); m = KH.mods_of('^'); eq(m, nil, 'mods ^ alone - a motion')
m, r = KH.mods_of('⌘⇧h'); eq(m.cmd and m.shift and r, 'h', 'mods cmd shift glyphs')
m = KH.mods_of('M'); eq(m and m.shift, true, 'capital = Shift'); eq(KH.mods_of('dd'), nil, 'plain')
m, r = KH.mods_of('Cmd+'); eq(m.cmd and r, '+', 'Cmd+ = Cmd and +')
KH.PAGES.__t = { title = 't', e = { { k = 'Ctrl+h j k l', d = 'move' }, { k = 'Opt+F1 F2', d = 'tr' }, { k = 'Esc Opt+Tab', d = 'back' }, { k = 'M', d = 'mute' }, { k = 'Ctrl+Shift+H L', d = 'pat' } } }
local l = KH.mod_entries({ '__t' }, { ctrl = true }); eq(#l, 1, 'ctrl: one'); eq(l[1].key, 'Ctrl+h j k l', 'ctrl inherits to j k l')
l = KH.mod_entries({ '__t' }, { opt = true }); eq(#l, 2, 'opt: two'); eq(l[2].key, 'Opt+Tab', 'Esc not taken')
l = KH.mod_entries({ '__t' }, { shift = true }); eq(#l, 1, 'shift: capital'); eq(l[1].text, 'mute', 'shift: M')
l = KH.mod_entries({ '__t' }, { ctrl = true, shift = true }); eq(l[1] and l[1].key, 'Ctrl+Shift+H L', 'ctrl+shift: L inherits')
KH.PAGES.__t = nil
eq(KH.mods_name({ cmd = true, shift = true }), 'Shift+Cmd', 'name order')
print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
