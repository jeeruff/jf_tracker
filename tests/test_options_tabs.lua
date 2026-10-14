-- test_options_tabs.lua — одна страница, fzf и строки-действия окна опций (5 окт)
local DIR = debug.getinfo(1, 'S').source:match('^@(.*)/tests/') or '.'
gfx = { mouse_x = 0, mouse_y = 0, mouse_cap = 0 }
local O = dofile(DIR .. '/jf_tracker_options.lua')
local tabbed
O.init({}, { mods = function() return {} end, opt_tab = function(t) tabbed = t end })
local n, bad = 0, 0
local function eq(name, got, want) n = n + 1; if got ~= want then bad = bad + 1; print(('FAIL %s: got %s want %s'):format(name, tostring(got), tostring(want))) end end
local fired, a = false, false
local items = {
  { sep = true, title = 'theme' },
  { key = 'theme', label = 'theme', kind = 'cycle', values = { 'reaper', 'mono' }, get = function() return 'reaper' end, set = function() end },
  { label = 'make a theme', kind = 'action', value = 'template', fn = function() fired = true end },
  { sep = true, title = 'look' },
  { key = 'hints', label = 'module hints', desc = 'a line of key hints', kind = 'toggle', get = function() return a end, set = function(v) a = v end },
  { key = 'wave', label = 'wave mode', kind = 'cycle', values = { 'off', 'back' }, get = function() return 'off' end, set = function() end },
}
O.open(items)
-- одна страница (5 окт): вкладок нет, все строки с заголовками разделов
eq('no tabs', #O.tabs, 0); eq('one page: every row with separators', #O.items, #items)
O.sel = 3; O.key(13); eq('Enter on an action runs it', fired, true)
O.key(9); eq('Tab does not switch pages', #O.items, #items)
O.sel = 5; O.key(13); eq('toggle', a, true)
O.key(('/'):byte()); for ch in ('hint'):gmatch('.') do O.key(ch:byte()) end
eq('fzf: one match', #O.items, 1); eq('fzf: the hints row', O.items[1].key, 'hints')
O.key(27); eq('Esc clears the search', O.query, ''); eq('back to the whole page', #O.items, #items)
O.open(items, 'look'); eq('a remembered tab is ignored', #O.items, #items)
-- две вкладки (5 окт): options и hotkeys — по group заголовков
do
  local g = {
    { sep = true, title = 'look' }, { key = 'a', label = 'a', kind = 'toggle', get = function() return false end, set = function() end },
    { sep = true, title = 'hotkeys', group = 'hotkeys' }, { label = 'dd', kind = 'action', desc = 'delete' }, { label = 'yy', kind = 'action', desc = 'yank' },
    { sep = true, title = 'profiles', group = 'options' }, { label = 'save', kind = 'action' },
  }
  O.open(g)
  eq('tabs options, hotkeys', table.concat(O.tabs, ','), 'options,hotkeys')
  eq('options tab: look + profiles', #O.items, 4)
  O.key(9); eq('Tab -> hotkeys', O.tab, 'hotkeys'); eq('hotkeys rows', #O.items, 3)
  O.open(g, 'hotkeys'); eq('open on hotkeys', O.tab, 'hotkeys')
end
-- 14 окт: блок (темы и шрифты) — строками в общем списке, клавиши ему, j / k за край — в список;
-- поиск — по всем вкладкам
do
  local got, edge = {}, nil
  local blk = { kind = 'block', label = 'themes', height = function() return 5 * 20 end,
    key = function(c) got[#got + 1] = c; return edge end }
  local g = {
    { sep = true, title = 'look' }, { key = 'a', label = 'alpha', kind = 'toggle', get = function() return false end, set = function() end },
    { sep = true, title = 'theme', group = 'options' }, blk,
    { sep = true, title = 'audio', group = 'options' }, { key = 'b', label = 'buffer', kind = 'toggle', get = function() return false end, set = function() end },
    { sep = true, title = 'hotkeys', group = 'hotkeys' }, { label = 'dd', kind = 'action', desc = 'delete alpha' },
  }
  O.rh = 20
  O.open(g)
  eq('block: tabs options, hotkeys', table.concat(O.tabs, ','), 'options,hotkeys')
  eq('block: 5 rows + 5 rows', #O.items, 5 + 5)
  O.sel = 2; O.key(('j'):byte()); eq('j enters the block', O.items[O.sel].blockrow, true)
  O.key(('l'):byte()); eq('keys go to the block', got[#got], ('l'):byte())
  edge = 'down'; O.key(('j'):byte()); eq('j past the block -> next option', O.items[O.sel].key, 'b')
  edge = nil
  O.key(('/'):byte()); for ch in ('alpha'):gmatch('.') do O.key(ch:byte()) end
  eq('search over all tabs', #O.items, 2)
  O.key(27)
end
-- компактная панель (5 окт): число цифрами, Enter, границы, Esc
local vol = 0
O.open_panel({ { label = 'volume', kind = 'num', min = -60, max = 12, step = 0.5, get = function() return vol end, set = function(v) vol = v end } }, 'item x', { x = 10, y = 10 })
eq('panel: compact', O.compact ~= nil, true)
for ch in ('-6'):gmatch('.') do O.key(ch:byte()) end
eq('panel: digits buffered', O.numbuf, '-6'); O.key(13); eq('panel: Enter sets', vol, -6)
for ch in ('99'):gmatch('.') do O.key(ch:byte()) end; O.key(13); eq('panel: clamped to max', vol, 12)
O.key(('3'):byte()); O.key(27); eq('panel: Esc drops the number', O.numbuf, nil); eq('panel: value kept', vol, 12)
O.key(('h'):byte()); eq('panel: h steps down', vol, 11.5)
O.key(('/'):byte()); eq('panel: no search in the panel', O.typing, false)
print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
