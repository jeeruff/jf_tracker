-- test_theory.lua — лады, ступени, прогрессии, голосоведение, хрома, гармонизация: lua tests/test_theory.lua
local DIR = (arg and arg[0] or ''):match('(.*)/tests/') or '.'
local CH = dofile(DIR .. '/jf_tracker_chord.lua')
local TH = dofile(DIR .. '/jf_tracker_theory.lua')
TH.init(CH)
local fails, checks = 0, 0
local function eq(n, a, b) checks = checks + 1; if a ~= b then fails = fails + 1; print('FAIL ' .. n .. ': ' .. tostring(a) .. ' vs ' .. tostring(b)) end end
eq('C major pcs', table.concat(TH.pcs(0, 'major'), ','), '0,2,4,5,7,9,11')
eq('A minor pcs', table.concat(TH.pcs(9, 'minor'), ','), '9,11,0,2,4,5,7')
eq('snap C# to C major', TH.snap(61, 0, 'major'), 60)
eq('step C +2 = E', TH.step(60, 2, 0, 'major'), 64)
eq('step B +1 = C up', TH.step(71, 1, 0, 'major'), 72)
eq('step C -1 = B down', TH.step(60, -1, 0, 'major'), 59)
local r, id = TH.detect({ 57, 60, 64, 57, 62, 65, 69, 57 })
eq('detect A minor root', r, 9); eq('detect A minor mode', id, 'minor')
eq('degree V7 in C', (TH.degree_chord(0, 'major', 5, true)), 'G7')
eq('degree ii in C', (TH.degree_chord(0, 'major', 2)), 'Dm')
eq('roman vi in C', TH.roman('vi', 0, 'major'), 'Am')
eq('roman V7 in A minor (major V)', TH.roman('V7', 9, 'minor'), 'E7')
local st, tot = TH.parse_prog('Am 2 | F 2 | G7 1')
eq('prog count', #st, 3); eq('prog total', tot, 5); eq('prog at', st[3].at, 4)
st = TH.parse_prog('I V vi IV', 0, 'major')
eq('roman prog', st[3].sym, 'Am'); eq('roman prog IV', st[4].sym, 'F')
local v = TH.voice_lead('F', { 60, 64, 67 })
eq('voice lead C->F keeps C', v[1], 60)
local ch = {}
for i = 1, 12 do ch[i] = 0 end
ch[10], ch[1], ch[5] = 0.3, 0.3, 0.3   -- A C E
eq('chroma best Am', (TH.best_chord(ch)), 'Am')
local seg = TH.segments({ 'C', 'C', 'G', 'C', 'C', 'F', 'F', 'F' }, 1, 2)
eq('segments absorb short', #seg, 2); eq('segments first', seg[1].lab, 'C')
local h = TH.harmonize({ { pitch = 64, w = 2 }, { pitch = 67, w = 1 }, { pitch = 72, w = 1 } }, 0, 'major')
eq('harmonize E G C -> C', h[1].sym, 'C')
eq('second voice third above E = G', TH.second_voice(64, 3, 0, 'major'), 67)
eq('in scale', TH.in_scale(66, 0, 'major'), false)
-- 26 окт: YIN — высота синуса, пилы, тишина
local function synth(f, n, sr, kind)
  local t = {}
  for i = 1, n do
    local ph = (i - 1) * f / sr
    t[i] = kind == 'saw' and (2 * (ph - math.floor(ph)) - 1) * 0.5 or 0.5 * math.sin(2 * math.pi * ph)
  end
  return t
end
local sr = TH.PITCH_SR
local f0 = TH.yin(synth(220, 2048, sr), 2048, sr)
eq('yin sine 220', f0 and math.floor(f0 + 0.5), 220)
local r = TH.sample_root(synth(220, 2048, sr), 2048)
eq('sample root A3', r and r.pitch, 57)
local r2 = TH.sample_root(synth(98, 2048, sr, 'saw'), 2048)
eq('sample root saw G2', r2 and r2.pitch, 43)
local z = {}; for i = 1, 2048 do z[i] = 0 end
eq('silence', TH.yin(z, 2048, sr), nil)
local r3 = TH.sample_root(synth(261.63 * 2 ^ (14 / 1200), 2048, sr), 2048)
eq('cents +14 near C4', r3 and (r3.pitch == 60 and math.abs(r3.cents - 14) <= 2), true)
print(('%d checks, %d failed'):format(checks, fails)); os.exit(fails == 0 and 0 or 1)
