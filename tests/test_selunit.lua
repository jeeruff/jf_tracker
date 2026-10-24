-- test_selunit.lua — Opt+V: концы единиц выделения (24 окт)
local DIR = (arg and arg[0] or ''):match('(.*)/tests/') or '.'
_G.reaper = setmetatable({}, { __index = function() return function() return false end end })
local M = dofile(DIR .. '/jf_tracker_model.lua')
local n, bad = 0, 0
local function ok(c, what) n = n + 1; if not c then bad = bad + 1; print('FAIL ' .. what) end end
ok(M.sel_unit_end(25, 24, 1, 96, 384) == 30, 'LPB 24, row 25: the sub-beat (6 rows) ends at 30')
ok(M.sel_unit_end(24, 24, 1, 96, 384) == 30, 'a row on the sub-beat start: its own sub-beat')
ok(M.sel_unit_end(25, 24, 2, 96, 384) == 48, 'the beat ends at 48')
ok(M.sel_unit_end(25, 24, 3, 96, 384) == 96, 'the bar end as given')
ok(M.sel_unit_end(25, 24, 4, 96, 384) == 384, 'the pattern end as given')
ok(M.sel_unit_end(5, 4, 1, 16, 64) == 6, 'LPB 4: a sub-beat is one row')
ok(#M.SEL_UNITS == 4, 'four levels')
print(('test_selunit: %d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
