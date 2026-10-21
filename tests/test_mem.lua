-- test_mem.lua — :mem, перепись памяти Lua: lua tests/test_mem.lua
local DIR = (arg and arg[0] or ''):match('(.*)/tests/') or '.'
local MEM = dofile(DIR .. '/jf_tracker_mem.lua')
local fails, checks = 0, 0
local function eq(n, a, b) checks = checks + 1; if a ~= b then fails = fails + 1; print('FAIL ' .. n .. ': ' .. tostring(a) .. ' vs ' .. tostring(b)) end end
local big = { s = ('x'):rep(100000) }
local shared = { 1, 2, 3 }
local small = { shared = shared, n = 'abc' }
local function f() return big end
local list = MEM.census({ { 'small', small }, { 'fn', f }, { 'again', shared } })
eq('biggest first', list[1].name, 'fn')
eq('found via upvalue', list[1].big, 100000)
eq('shared counted once', list[3].tables, 0)
eq('small has its tables', list[2].tables, 2)
eq('fmt MB', MEM.fmt(3 * 1048576), '3.0MB')
eq('report', MEM.report(list, 1):match('^fn ') ~= nil, true)
-- 21 окт: memprof — отчёт по строкам, по убыванию
local rep = MEM.prof_report({ ['@/a/x.lua'] = { [10] = 100, [20] = 300 }, ['@/b/y.lua'] = { [5] = 50 } }, 2)
eq('memprof total KB/s', rep:match('^memprof (%d+)'), '225')
eq('memprof top line first', rep:match(': (%S+)'), 'x.lua:20')
print(('%d checks, %d failed'):format(checks, fails)); os.exit(fails == 0 and 0 or 1)
