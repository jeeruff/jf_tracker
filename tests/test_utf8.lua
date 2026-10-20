-- test_utf8.lua — набор кириллицы: lua tests/test_utf8.lua
local DIR = (arg and arg[0] or ''):match('(.*)/tests/') or '.'
local TX = dofile(DIR .. '/jf_tracker_utf8.lua')
local fails, checks = 0, 0
local function eq(n, a, b) checks = checks + 1; if a ~= b then fails = fails + 1; print('FAIL ' .. n .. ': ' .. tostring(a) .. ' vs ' .. tostring(b)) end end
eq('ascii', TX.char(97), 'a'); eq('ctrl', TX.char(13), nil)
eq('cyr', TX.char(0x75000000 + 0x44B), 'ы'); eq('arrow code', TX.char(1919379572), nil)
eq('bs cyr', TX.bs('кит'), 'ки'); eq('bs ascii', TX.bs('ab'), 'a'); eq('bs empty', TX.bs(''), '')
print(('%d checks, %d failed'):format(checks, fails)); os.exit(fails == 0 and 0 or 1)
