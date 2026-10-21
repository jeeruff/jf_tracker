-- test_szone.lua — место зоны сессии: lua tests/test_szone.lua
local DIR = (arg and arg[0] or ''):match('(.*)/tests/') or '.'
local SZ = dofile(DIR .. '/jf_tracker_szone.lua')
local fails, checks = 0, 0
local function eq(n, a, b) checks = checks + 1; if a ~= b then fails = fails + 1; print('FAIL ' .. n .. ': ' .. tostring(a) .. ' vs ' .. tostring(b)) end end

eq('empty project', SZ.after({}), 0)
local song = { end_pos = 166, regions = { { pos = 0, rgnend = 5.33, name = 'A1' }, { pos = 166.6, rgnend = 170.6, name = 'C2' } },
  items = { { pos = 0, len = 1 }, { pos = 180, len = 2, tagged = true } } }
eq('after the library regions', SZ.after(song), 170.6)
eq('tagged items do not count', SZ.after({ end_pos = 10, items = { { pos = 20, len = 5, tagged = true } } }), 10)
eq('long recording counts', SZ.after({ end_pos = 10, items = { { pos = 8, len = 30 } } }), 38)
eq('zone inside the song', SZ.in_song({ pos = 5.7, rgnend = 10.7 }, song), 'before =END')
eq('zone over a library region', SZ.in_song({ pos = 168, rgnend = 172 }, song), 'over C2')
eq('zone over its own clips only', SZ.in_song({ pos = 178, rgnend = 186 }, song), nil)
eq('zone over song items', SZ.in_song({ pos = 200, rgnend = 210 }, { end_pos = 100, items = { { pos = 205, len = 1 } } }), 'over song items')
print(('%d checks, %d failed'):format(checks, fails)); os.exit(fails == 0 and 0 or 1)
