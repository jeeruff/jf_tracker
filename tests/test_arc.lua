-- test_arc.lua — arc в трекере (15 окт): дельты из сумм, память параметров, слоты, шаг
local DIR = debug.getinfo(1, 'S').source:match('^@(.*)/tests/') or '.'
local A = dofile(DIR .. '/jf_tracker_arc.lua')
local n, bad = 0, 0
local function eq(name, got, want) n = n + 1; if got ~= want then bad = bad + 1; print(('FAIL %s: got %s want %s'):format(name, tostring(got), tostring(want))) end end

-- первое чтение — без дельт, дальше разница
local d = A.deltas('10,0,-5,3')
eq('first read: no delta', d[1], 0)
d = A.deltas('14,0,-9,3')
eq('delta ring 1', d[1], 4); eq('delta ring 3', d[3], -4); eq('delta ring 4', d[4], 0)
d = A.deltas('garbage')
eq('bad string: zeros', d[1], 0)

-- память
eq('encode', A.encode({ 3, 7 }), '3,7,-1,-1')
local m = A.decode('3,7,-1,-1')
eq('decode', m and m[2], 7)
eq('decode short: nil', A.decode('1,2'), nil)

local params = { { i = 0, name = 'a' }, { i = 1, name = 'b' }, { i = 2, name = 'c' }, { i = 5, name = 'f' }, { i = 6, name = 'g' } }
local s = A.slots(params, 2, nil)
eq('slots from selected', s[1].name, 'b'); eq('slots 4th', s[4].name, 'g')
s = A.slots(params, 5, nil)
eq('slots near the end start earlier', s[1].name, 'b')
s = A.slots(params, 1, { 5, -1, 0, 9 })
eq('memory: ring 1 = param 5', s[1].name, 'f'); eq('memory: empty ring', s[2], nil)
eq('memory: ring 3 = param 0', s[3].name, 'a'); eq('memory: missing param', s[4], nil)

-- шаг и уровни
eq('step clamps', A.step(0.99, 100), 1)
eq('step fine', A.step(0.5, 4, true), 0.5 + 4 / 1024)
eq('rings', A.rings({ 0.5, nil, 1 }), '0.500,-1,1.000,-1')

print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
