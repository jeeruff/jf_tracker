-- test_bipolar.lua (22 окт): параметр «ноль посередине» — ромбик в DSP
reaper = setmetatable({}, { __index = function() return function() return nil end end })
local DIR = debug.getinfo(1, 'S').source:match('^@(.*)/tests/') or '.'
package.path = DIR .. '/?.lua;' .. package.path
local ok, M = pcall(dofile, DIR .. '/jf_tracker_model.lua')
local n, bad = 0, 0
local function eq(a, b, w) n = n + 1; if a ~= b then bad = bad + 1; print(('FAIL %s: %s ~= %s'):format(w, tostring(a), tostring(b))) end end
eq(ok, true, 'model loads ' .. tostring(not ok and M or ''))
local B = M.bipolar_of
eq(B('pitch', '-24.00', '+24.00'), true, 'pitch -24..+24')
eq(B('detune', '-100.0', '100.0'), true, 'detune -100..100')
eq(B('volume', '-inf', '+12.0'), false, 'volume dB -inf..+12 - no')
eq(B('gain', '-150.0', '12.0'), false, 'gain -150..12 - no (not symmetric)')
eq(B('cutoff', '20', '20000'), false, 'cutoff - no')
eq(B('pan', '0.00', '1.00'), true, 'pan by name (RS5K 0..1)')
eq(B('Osc 1 Pan', nil, nil), true, 'name ends with pan')
eq(B('Balance', nil, nil), true, 'balance by name')
eq(B('panic', nil, nil), false, 'panic is not pan')
eq(B('pan L', nil, nil), true, 'pan L')
eq(B('bend', '0.0', '12.0'), false, 'bend range 0..12 - no')
print(('%d checks, %d failed'):format(n, bad)); os.exit(bad == 0 and 0 or 1)
