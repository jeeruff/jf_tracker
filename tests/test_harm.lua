-- test_harm.lua — ступени лада и автоопределение (jf_tracker_harm.lua)
local DIR = debug.getinfo(1, 'S').source:sub(2):match('(.*)/tests/') or '.'
local CH = dofile(DIR .. '/jf_tracker_chord.lua')
local HM = dofile(DIR .. '/jf_tracker_harm.lua')
HM.init({}, CH)
local n, bad = 0, 0
local function eq(a, b, m) n = n + 1; if a ~= b then bad = bad + 1; print('FAIL ' .. m .. ': ' .. tostring(a) .. ' ~= ' .. tostring(b)) end end
HM.root, HM.minor = 0, false
eq(HM.degree(1), 'C', 'I in C'); eq(HM.degree(2), 'Dm', 'ii'); eq(HM.degree(7), 'Bdim', 'vii°'); eq(HM.degree(5, true), 'G7', 'V7')
HM.root, HM.minor = 10, true                 -- A# minor (пад пользователя)
eq(HM.degree(1), 'A#m', 'i in A# minor'); eq(HM.degree(6), 'F#', 'VI'); eq(HM.degree(2, true), 'Cm7b5', 'ii°7')
local r, m = HM.detect({ 58, 61, 65, 58, 61, 65, 56, 60, 63, 65 })
eq(CH.NAMES[r + 1] .. (m and 'm' or ''), 'A#m', 'detect A# minor from A#m + G#6')
eq(HM.key(('3'):byte()).write, HM.degree(3), 'key 3 writes iii')
eq(HM.key(('#'):byte()).write, HM.degree(3, true), 'shift-3 writes the seventh')
eq(HM.key(27), 'leave', 'Esc leaves')
print(('%d checks, %d failed'):format(n, bad))
if bad > 0 then os.exit(1) end
