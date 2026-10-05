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
