-- test_options_tabs.lua — вкладки, all, fzf и строки-действия окна опций (5 окт)
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
eq('tabs from sections + all', table.concat(O.tabs, ','), 'theme,look,all')
eq('first tab shows its rows only', #O.items, 2)
O.sel = 2; O.key(13); eq('Enter on an action runs it', fired, true)
O.key(9); eq('Tab -> next tab', O.tab, 'look'); eq('opt_tab remembered', tabbed, 'look'); eq('look rows', #O.items, 2)
O.key(13); eq('toggle on its tab', a, true)
O.set_tab('all'); eq('all: every row with separators', #O.items, #items)
O.key(('/'):byte()); for ch in ('hint'):gmatch('.') do O.key(ch:byte()) end
eq('fzf: one match', #O.items, 1); eq('fzf: the hints row', O.items[1].key, 'hints')
O.key(27); eq('Esc clears the search', O.query, ''); eq('back to the tab', #O.items, #items)
O.open(items, 'look'); eq('open on a remembered tab', O.tab, 'look')
O.open(items, 'gone'); eq('unknown tab -> the first', O.tab, 'theme')
print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
