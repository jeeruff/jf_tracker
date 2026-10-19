-- test_humanizer.lua — панель humanizer: lua tests/test_humanizer.lua
local DIR = (arg and arg[0] or ''):match('(.*)/tests/') or '.'
local HU = dofile(DIR .. '/jf_tracker_humanizer.lua')
local fails, checks = 0, 0
local function eq(n, a, b) checks = checks + 1; if a ~= b then fails = fails + 1; print('FAIL ' .. n .. ': ' .. tostring(a) .. ' vs ' .. tostring(b)) end end
local s = HU.defaults()
eq('time default', s.v.time, 10); eq('on default', s.on.vel, true); eq('ins default', s.ins, true)
HU.sel = 2; eq('l', HU.key(s, ('l'):byte()), 'changed'); eq('time 11', s.v.time, 11)
HU.key(s, ('h'):byte()); HU.key(s, ('h'):byte()); eq('time 9', s.v.time, 9)
HU.key(s, ('j'):byte()); eq('row vel', HU.ROWS[HU.sel].k, 'vel')
HU.key(s, (' '):byte()); eq('vel off', s.on.vel, false)
HU.sel = 4; HU.key(s, ('l'):byte(), true); eq('vol fine', s.v.vol, 1.52)
local t = HU.decode(HU.encode(s)); eq('roundtrip time', t.v.time, 9); eq('roundtrip vel off', t.on.vel, false); eq('roundtrip ins', t.ins, true)
s.v.time = 50; HU.sel = 2; HU.key(s, ('l'):byte()); eq('clamp', s.v.time, 50)
HU.key(s, ('0'):byte()); eq('defaults', s.v.time, 10); eq('defaults on', s.on.vel, true)
eq('Enter', HU.key(s, 13), 'apply'); eq('Esc', HU.key(s, 27), 'leave'); eq('i', HU.key(s, ('i'):byte()), 'changed'); eq('ins off', s.ins, false)
HU.set_from_x(s, 2, 0.5); eq('from x', s.v.time, 25)
s.dsp = { { name = 'Surge cutoff', range = 5 } }; HU.sel = #HU.ROWS + 1
HU.key(s, ('l'):byte()); eq('dsp range', s.dsp[1].range, 6); HU.key(s, (' '):byte()); eq('dsp off', s.dsp[1].off, true)
eq('a add', HU.key(s, ('a'):byte()), 'add'); HU.key(s, ('x'):byte()); eq('dsp removed', #s.dsp, 0)
print(('%d checks, %d failed'):format(checks, fails)); os.exit(fails == 0 and 0 or 1)
