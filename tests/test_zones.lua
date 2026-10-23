package.path = './?.lua;' .. package.path
local Z = dofile('jf_tracker_zones.lua')
local n, bad = 0, 0
local function eq(a, b, what) n = n + 1; if math.abs(a - b) > 1e-9 then bad = bad + 1; print('FAIL ' .. what .. ': ' .. tostring(a) .. ' ~= ' .. tostring(b)) end end
local z = { lo = 36, hi = 59, flo = 40, fhi = 55 }
eq(Z.gain(35, z), 0, 'below')
eq(Z.gain(60, z), 0, 'above')
eq(Z.gain(36, z), 1 / 5, 'fade in start')
eq(Z.gain(40, z), 1, 'full from flo')
eq(Z.gain(55, z), 1, 'full to fhi')
eq(Z.gain(59, z), 1 / 5, 'fade out end')
eq(Z.gain(0, { lo = 0, hi = 127, flo = 0, fhi = 127 }), 1, 'full range')
local d = Z.drag(z, 'lo', 30); eq(d.lo, 30, 'lo moves'); eq(d.flo, 40, 'flo stays when inside')
d = Z.drag({ lo = 36, hi = 59, flo = 36, fhi = 59 }, 'lo', 30); eq(d.flo, 30, 'flo follows lo without fade')
d = Z.drag(z, 'lo', 70); eq(d.lo, 59, 'lo stops at hi')
d = Z.drag(z, 'move', 100); eq(d.hi, 127, 'move clamps'); eq(d.lo, 104, 'move keeps width')
d = Z.drag(z, 'flo', 10); eq(d.flo, 36, 'flo not below lo')
d = Z.drag({ lo = 1, hi = 127, flo = 1, fhi = 127 }, 'lo', 0, 'vel'); eq(d.lo, 1, 'vel min 1')
eq(Z.label('key', 0) == 'C-1' and 1 or 0, 1, 'C-1 label')
eq(Z.label('key', 60) == 'C4' and 1 or 0, 1, 'C4 label (REAPER: 60 = C4)')
print(('test_zones: %d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
