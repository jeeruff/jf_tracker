-- test_reform.lua — reform: lua tests/test_reform.lua
local DIR = (arg and arg[0] or ''):match('(.*)/tests/') or '.'
local RF = dofile(DIR .. '/jf_tracker_reform.lua')
local fails, checks = 0, 0
local function eq(n, a, b) checks = checks + 1; if math.abs((a or -999) - (b or -999)) > 1e-6 then fails = fails + 1; print('FAIL ' .. n .. ': ' .. tostring(a) .. ' vs ' .. tostring(b)) end end
local ev = { { row = 0, v = 100 }, { row = 2, v = 50 }, { row = 3, v = 200 }, { row = 8, v = 0 } }
local p = RF.defaults()
local o = RF.compute(ev, 0, 15, p)
eq('identity row', o[2].row, 2); eq('identity v', o[3].v, 200)
p.scale = 2; o = RF.compute(ev, 0, 15, p); eq('scale x2', o[4].row, 16); eq('scale keeps first', o[1].row, 0)
p.scale = 1; p.shift = 3; o = RF.compute(ev, 0, 15, p); eq('shift', o[1].row, 3)
p.shift = 0; p.redist = true; o = RF.compute(ev, 0, 15, p); eq('redist 2', o[2].row, 8 / 3); eq('redist last', o[4].row, 8)
p.redist = false; p.anchor = true; p.redist = true; o = RF.compute(ev, 0, 15, p); eq('redist over selection', o[4].row, 15)
p = RF.defaults(); p.curve = 1; o = RF.compute(ev, 0, 15, p); eq('curve keeps ends', o[4].row, 8); eq('curve slows the start', o[2].row, 8 * (2 / 8) ^ 4)
p = RF.defaults(); p.vals = true; p.lo = 0; p.hi = 100; o = RF.compute(ev, 0, 15, p); eq('remap max', o[3].v, 100); eq('remap min', o[4].v, 0); eq('remap mid', o[1].v, 50)
p.even = true; o = RF.compute(ev, 0, 15, p); eq('even first', o[1].v, 0); eq('even last', o[4].v, 100); eq('even 2', o[2].v, 33)
RF.sel = 1; p = RF.defaults(); RF.key(p, ('l'):byte()); eq('key scale', p.scale, 1.05)
RF.sel = 4; RF.key(p, ('l'):byte()); eq('toggle redist', p.redist and 1 or 0, 1)
RF.sel = 7; RF.key(p, ('l'):byte()); eq('lo +8 turns values on', p.lo, 8); eq('vals on', p.vals and 1 or 0, 1)
print(('%d checks, %d failed'):format(checks, fails)); os.exit(fails == 0 and 0 or 1)
