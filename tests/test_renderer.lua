-- test_renderer.lua — панель renderer: lua tests/test_renderer.lua
local DIR = (arg and arg[0] or ''):match('(.*)/tests/') or '.'
local RD = dofile(DIR .. '/jf_tracker_renderer.lua')
local fails, checks = 0, 0
local function eq(n, a, b) checks = checks + 1; if a ~= b then fails = fails + 1; print('FAIL ' .. n .. ': ' .. tostring(a) .. ' vs ' .. tostring(b)) end end
local p = RD.defaults()
p.lo, p.hi, p.step, p.layers, p.len, p.tail = 36, 48, 6, 2, 1, 0.5
local pl = RD.plan(p)
eq('count', #pl, 6)                      -- 36 42 48 x 2 слоя
eq('first zone lo', pl[1].lo, 0); eq('first zone hi', pl[1].hi, 39); eq('mid zone lo', pl[3].lo, 40); eq('last zone hi', pl[6].hi, 127)
eq('vel layer 1', pl[1].vhi, 64); eq('vel layer 1 lo', pl[1].vlo, 1); eq('vel layer 2 lo', pl[2].vlo, 65); eq('vel layer 2', pl[2].vel, 127)
eq('time', pl[3].t0, 3); eq('time end', pl[6].t1, 9)
p.hi = 46; pl = RD.plan(p); eq('hi included', pl[#pl].note, 46)
eq('name', RD.nname(60), 'C-4')
local q = RD.decode(RD.encode(p)); eq('roundtrip hi', q.hi, 46); eq('roundtrip mode', q.mode, false)
RD.sel = 1; eq('toggle mode', RD.key(p, (' '):byte()), 'changed'); eq('mode on', p.mode, true)
RD.key(p, ('j'):byte()); eq('next row tail', RD.ROWS[RD.sel].k, 'tail')
RD.key(p, ('j'):byte()); eq('skips mute in sampler', RD.ROWS[RD.sel].k, 'lo')
RD.key(p, ('l'):byte()); eq('note +octave', p.lo, 48)
eq('Enter', RD.key(p, 13), 'render')
print(('%d checks, %d failed'):format(checks, fails)); os.exit(fails == 0 and 0 or 1)
