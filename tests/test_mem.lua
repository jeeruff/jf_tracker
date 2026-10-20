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
print(('%d checks, %d failed'):format(checks, fails)); os.exit(fails == 0 and 0 or 1)
