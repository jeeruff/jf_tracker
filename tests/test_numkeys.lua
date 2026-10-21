-- test_numkeys.lua — число перед клавишей в панелях: lua tests/test_numkeys.lua
local DIR = (arg and arg[0] or ''):match('(.*)/tests/') or '.'
gfx = gfx or {}
local RF = dofile(DIR .. '/jf_tracker_reform.lua')
local HU = dofile(DIR .. '/jf_tracker_humanizer.lua')
local RD = dofile(DIR .. '/jf_tracker_renderer.lua')
local fails, checks = 0, 0
local function eq(n, a, b) checks = checks + 1; if a ~= b then fails = fails + 1; print('FAIL ' .. n .. ': ' .. tostring(a) .. ' vs ' .. tostring(b)) end end
local function keys(f, st, s) local r; for ch in s:gmatch('.') do r = f(st, ch == '\r' and 13 or ch:byte(), false) end; return r end

-- reform: строка scale (1), Enter с числом — значение, не keep
local p = {}; for _, r in ipairs(RF.ROWS) do p[r.k] = r.def end
RF.sel = 1
eq('2 Enter sets, not keep', keys(RF.key, p, '2\r'), 'changed'); eq('scale = 2', p.scale, 2)
eq('Enter alone keeps', keys(RF.key, p, '\r'), 'keep')
keys(RF.key, p, '025\r'); eq('025 -> 0.25', p.scale, 0.25)
p.scale = 2; keys(RF.key, p, '0'); eq('lone 0 resets', p.scale, 1); RF.num, RF.snap = nil, nil
p.scale = 2; keys(RF.key, p, '05\r'); eq('0 then digits: reset undone, 0.5', p.scale, 0.5)
RF.sel = 1; keys(RF.key, p, '3j'); eq('3 j -> row 4', RF.sel, 4)
RF.sel = 3; p.shift = 0; keys(RF.key, p, '4l'); eq('4 l on shift: +4', p.shift, 4)
keys(RF.key, p, '-7\r'); eq('-7 Enter', p.shift, -7)
keys(RF.key, p, '9' .. string.char(27)); eq('Esc cancels the number', RF.num, nil); eq('value kept', p.shift, -7)
RF.sel = 4; keys(RF.key, p, '1\r'); eq('toggle by number', p.redist, true)

-- humanizer: строка time (2)
local s = HU.defaults(); HU.sel = 2
eq('hum 23 Enter', keys(HU.key, s, '23\r'), 'changed'); eq('time = 23', s.v.time, 23)
eq('hum Enter applies', keys(HU.key, s, '\r'), 'apply')
s.v.vel = 30; keys(HU.key, s, '07\r'); eq('hum 0 then digits keeps others', s.v.vel, 30)

-- bouncer: строка tail (2)
local q = RD.defaults(); RD.sel = 2
eq('rd 3 Enter', keys(RD.key, q, '3\r'), 'changed'); eq('tail = 3', q.tail, 3)
eq('rd Enter renders', keys(RD.key, q, '\r'), 'render')
print(('%d checks, %d failed'):format(checks, fails)); os.exit(fails == 0 and 0 or 1)
