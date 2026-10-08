-- test_chord.lua — анализатор и гармонайзер аккордов (jf_tracker_chord.lua)
local DIR = debug.getinfo(1, 'S').source:sub(2):match('(.*)/tests/') or '.'
local CH = dofile(DIR .. '/jf_tracker_chord.lua')
local n, bad = 0, 0
local function eq(a, b, m) n = n + 1; if a ~= b then bad = bad + 1; print('FAIL ' .. m .. ': ' .. tostring(a) .. ' ~= ' .. tostring(b)) end end
-- A#3 C#4 F-4 (скрин пользователя) = A# минор
eq(CH.name({ 58, 61, 65 }), 'A#m', 'A# minor triad')
eq(CH.name({ 56, 60, 63, 65 }), 'G#6', 'G# C D# F: root in the bass wins (not Fm7/G#)')
eq(CH.name({ 60, 64, 67 }), 'C', 'C major')
eq(CH.name({ 64, 67, 72 }), 'C/E', 'first inversion')
eq(CH.name({ 60, 64, 67, 70 }), 'C7', 'dominant 7')
eq(CH.name({ 62, 65, 69, 72 }), 'Dm7', 'Dm7')
eq(CH.name({ 60, 64, 70 }), 'C7', 'C7 without the fifth')
eq(CH.name({ 60 }), 'C', 'single note')
eq(CH.name({ 60, 61 }), 'C?', 'unknown cluster')
eq(CH.name({ 60, 72, 67, 64 }), 'C', 'doubled root')
local v = CH.voicing('Cm7', 4); eq(table.concat(v, ','), '60,63,67,70', 'Cm7 voicing')
v = CH.voicing('F#maj7/A#', 3); eq(table.concat(v, ','), '46,54,58,61,65', 'slash bass under the root')
eq(CH.parse('Bbm').root, 10, 'flat root')
eq(CH.parse('Xyz'), nil, 'nonsense')
eq(CH.parse('Csus').suffix, 'sus4', 'sus alias')
eq(CH.name(CH.voicing('Ebmaj7', 4)), 'D#maj7', 'round trip (sharps)')
-- линия аккордов
do
  local tl = CH.timeline({ { 0, 2, 60 }, { 0, 2, 64 }, { 0, 2, 67 }, { 2, 4, 57 }, { 2, 4, 60 }, { 2, 4, 64 }, { 5, 6, 62 } })
  eq(#tl, 5, 'timeline: C, Am, silence, D, silence')
  eq(tl[1].pos, 0, 'C at 0'); eq(tl[1].mask, (1 << 0) | (1 << 4) | (1 << 7), 'C mask'); eq(tl[1].root, 0, 'C root')
  eq(tl[2].pos, 2, 'Am at 2'); eq(tl[2].root, 9, 'Am root = A')
  eq(tl[3].mask, 0, 'silence mask 0'); eq(tl[3].root, -1, 'silence root -1')
  eq(tl[4].root, 2, 'single D: root D')
  eq(#CH.timeline({}), 0, 'empty')
end
print(('%d checks, %d failed'):format(n, bad))
if bad > 0 then os.exit(1) end
