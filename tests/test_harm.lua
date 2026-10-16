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
-- стан и гитара (9 окт)
local st, acc = CH.staff_step(64); eq(st, 30, 'E4 = bottom line'); eq(acc, nil, 'E natural')
st, acc = CH.staff_step(61); eq(st, 28, 'C#4 on C4 step'); eq(acc, '#', 'C# sharp')
eq(CH.staff_step(77), 38, 'F5 = top line')
local function g(sym) local t = CH.guitar(sym); return t and table.concat(t, ' ') end
eq(g('C'), '-1 3 2 0 1 0', 'open C'); eq(g('Am'), '-1 0 2 2 1 0', 'open Am')
eq(g('F'), '1 3 3 2 1 1', 'F barre'); eq(g('Dm'), '-1 -1 0 2 3 1', 'open Dm')
eq(g('E7'), '0 2 0 1 0 0', 'E7'); eq(g('C/E'):sub(1, 1), '0', 'C/E: E in the bass')
eq(HM.key(('s'):byte()), true, 's toggles staff'); eq(HM.show_staff, false, 'staff off')
-- 16 окт: натуральный строй
eq(HM.ji_step(4), -1, 'major third 5/4 = -1/6'); eq(HM.ji_step(3), 1, 'minor third 6/5 = +1/6'); eq(HM.ji_step(7), 0, 'fifth 3/2 = 0')
eq(HM.ji_step(10), -2, 'harmonic seventh 7/4 = -2/6'); eq(HM.ji_step(10, true), 1, 'minor seventh 9/5 = +1/6')
local jm = HM.ji_micro('C7', { 60, 64, 67, 70 })
eq(jm[60], nil, 'root untouched'); eq(jm[64], -1, 'C7: E lower'); eq(jm[70], -2, 'C7: Bb 7/4'); eq(jm[67], nil, 'C7: G pure')
local jm2 = HM.ji_micro('Am7', { 57, 60, 64, 67 })
eq(jm2[60], 1, 'Am7: C higher (6/5)'); eq(jm2[67], 1, 'Am7: G 9/5')
eq(HM.key(('j'):byte()), true, 'j toggles just'); eq(HM.ji, true, 'just on')
print(('%d checks, %d failed'):format(n, bad))
if bad > 0 then os.exit(1) end
