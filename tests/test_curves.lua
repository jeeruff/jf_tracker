-- test_curves.lua — кривые огибающей (jf_tracker_curves.lua)
local CV = dofile('jf_tracker_curves.lua')
local n, bad = 0, 0
local function ok(c, what) n = n + 1; if not c then bad = bad + 1; print('FAIL ' .. what) end end
local function near(a, b) return math.abs(a - b) < 1e-6 end

local flat = { 0.5, 0.5, 0.5, 0.5, 0.5 }
local up = CV.apply('up', flat)
ok(near(up[1], 0) and near(up[5], 0.5) and near(up[3], 0.25), 'flat line: ramp 0 .. the fader value')
local lo0 = CV.apply('up', { 0, 0, 0 })
ok(near(lo0[1], 0) and near(lo0[3], 1), 'flat at 0: ramp 0 .. 1')
local r = CV.apply('down', { 0.2, 0.8, 0.4 })
ok(near(r[1], 0.8) and near(r[3], 0.2), 'ramp down in the range of the values')
ok(near(CV.apply('invert', { 0.25 })[1], 0.75), 'invert')
local rv = CV.apply('rev', { 0.1, 0.2, 0.3 })
ok(near(rv[1], 0.3) and near(rv[3], 0.1), 'reverse')
local m = CV.apply('more', { 0.4, 0.6 })
ok(near(m[1], 0.35) and near(m[2], 0.65), 'more stretches from the mean')
ok(near(CV.apply('flat', { 0.2, 0.4 })[2], 0.3), 'flat = mean')
local e = CV.apply('exp', { 0, 1, 1, 1, 1 })
ok(e[3] < 0.25, 'exp slow at first')
local g = CV.apply('log', { 0, 1, 1, 1, 1 })
ok(g[3] > 0.75, 'log fast at first')
local s = CV.apply('sine', { 0, 1, 0, 1, 0 })
ok(near(s[1], 0) and near(s[3], 1) and near(s[5], 0), 'sine one period')
local rr1, rr2 = CV.apply('random', { 0, 1, 0, 1 }, 7), CV.apply('random', { 0, 1, 0, 1 }, 7)
ok(rr1[2] == rr2[2], 'random is repeatable for a seed')
for _, v in ipairs(CV.apply('uplift', { 1, 0.99 })) do ok(v <= 1, 'clamped at 1') end
local keys = {}
for _, c in ipairs(CV.LIST) do ok(not keys[c.key:upper()] and c.key:upper() ~= 'H', 'unique key ' .. c.key); keys[c.key:upper()] = true end
print(('test_curves: %d checks, %d failed'):format(n, bad))
