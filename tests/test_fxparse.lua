-- test_fxparse.lua (22 окт): парсер параметров на образцах tests/fixtures/fxdump (RS5K, Surge XT) — единицы,
-- виды (toggle / steps / bipolar / db / freq / time …), лог-шкала, короткий вид значения, сокращения имён
local DIR = debug.getinfo(1, 'S').source:match('^@(.*)/tests/') or '.'
local FP = dofile(DIR .. '/jf_tracker_fxparse.lua')
local FD = dofile(DIR .. '/jf_tracker_fxdump.lua')
local n, bad = 0, 0
local function eq(a, b, w) n = n + 1; if a ~= b then bad = bad + 1; print(('FAIL %s: %s ~= %s'):format(w, tostring(a), tostring(b))) end end
local function load(f) local h = assert(io.open(DIR .. '/tests/fixtures/fxdump/' .. f)); local s = h:read('a'); h:close(); return FD.parse(s) end
local function by(r, name) for _, p in ipairs(r.params) do if p.name == name then return p end end end
local function cls(r, name) local p = by(r, name); return p and FP.classify(p.t, p.toggle) end
-- RS5K
local rs = load('ReaSamplOmatic5000_Cockos.txt')
eq(#rs.params, rs.np, 'rs5k: all parameters parsed')
eq(cls(rs, 'Volume').kind, 'db', 'rs5k volume db')
eq(cls(rs, 'Attack').kind, 'time', 'rs5k attack time')
eq(cls(rs, 'Obey note-offs').kind, 'toggle', 'rs5k 0/1 toggle')
eq(cls(rs, 'Pitch adjust').kind, 'bipolar', 'rs5k pitch adjust bipolar')
eq(cls(rs, 'Pitchbend range').kind, 'semi', 'rs5k semitones')
eq(cls(rs, 'Probability of hitting').kind, 'pct', 'rs5k percent')
eq(cls(rs, 'Decay').log, nil, 'rs5k decay linear')
-- Surge XT
local sg = load('Surge_XT_Surge_Synth_Team.txt')
eq(cls(sg, 'A Filter 1 Cutoff').kind, 'freq', 'surge cutoff freq'); eq(cls(sg, 'A Filter 1 Cutoff').log, true, 'cutoff log')
eq(cls(sg, 'A Amp EG Attack').kind, 'time', 'surge attack time'); eq(cls(sg, 'A Amp EG Attack').log, true, 'attack log')
eq(cls(sg, 'A Pan').kind, 'bipolar', 'surge pan bipolar')
eq(cls(sg, 'A Filter 1 Keytrack').kind, 'bipolar', 'surge keytrack +-100% bipolar')
eq(cls(sg, 'A Filter 1 Resonance').kind, 'pct', 'surge resonance pct (not bipolar)')
eq(cls(sg, 'A Osc 1 Keytrack').kind, 'toggle', 'surge On/Off toggle')
eq(cls(sg, 'FX A1 FX Type').kind, 'steps', 'surge fx type steps')
eq(cls(sg, 'A Keytrack Root Key').kind, 'plain', 'root key constant C4 - plain')
eq(cls(sg, 'A Volume').kind, 'db', 'surge volume db (-inf start)')
-- каждый параметр образцов классифицируется без ошибки
for _, r in ipairs({ rs, sg, load('Surge_XT_Surge_Synth_Team_2-6ch.txt') }) do
  local ok = true
  for _, p in ipairs(r.params) do local okc = pcall(FP.classify, p.t, p.toggle); if not okc then ok = false end end
  eq(ok, true, (r.name or '?') .. ': classify every parameter')
end
-- короткий вид
eq(FP.compact('25087.71 Hz'), '25.1k', 'hz 25k'); eq(FP.compact('3838.59 Hz'), '3.84k', 'hz 3.8k'); eq(FP.compact('587.33 Hz'), '587', 'hz 587')
eq(FP.compact('0.008 Hz'), '0.01', 'hz tiny'); eq(FP.compact('353.6 ms'), '354ms', 'ms'); eq(FP.compact('3.36 s'), '3.36s', 's')
eq(FP.compact('32.00 s'), '32s', '32 s'); eq(FP.compact('-7.47 dB'), '-7.5', 'db'); eq(FP.compact('-inf dB'), '-inf', '-inf')
eq(FP.compact('+3.5 dB'), '+3.5', '+db'); eq(FP.compact('50.00 %'), '50%', 'pct'); eq(FP.compact('3.50 semitones'), '+3.5st', 'semi')
eq(FP.compact('-100.00 % (Left)'), '-100%', 'pan left'); eq(FP.compact('Freq Shift'), 'Freq Shift', 'text stays')
-- сокращения
eq(FP.abbr('Filter 1 Cutoff', 20), 'Filter 1 Cutoff', 'fits - unchanged')
eq(FP.abbr('Filter 1 Resonance', 13), 'Filter 1 reso', 'dictionary: longest word first'); eq(FP.abbr('Filter 1 Resonance', 12), 'flt 1 reso', 'then the next word')
eq(FP.abbr('Gain for minimum velocity', 10), 'gn for min vel', 'dictionary only, no vowel stripping (fit cuts the rest)')
eq(FP.abbr('Highpass', 4), 'hp', 'highpass -> hp')
eq(FP.abbr('Feedback', 4), 'fb', 'feedback -> fb')
-- Serum 2 (2626 параметров): «25% [-21.1 dB]», «-∞», пан «-50 L», октавы, центр «--»
local se = load('Serum_2_Xfer_Records.txt')
eq(#se.params, se.np, 'serum: all parameters parsed')
eq(cls(se, 'Main Vol').kind, 'db', 'serum main vol: dB in brackets')
eq(FP.compact('  0% [-\226\136\158 dB]'), '-inf', 'serum -inf'); eq(FP.compact(' 75% [-2.0 dB]'), '-2', 'serum dB in brackets compact')
eq(cls(se, 'A Pan').kind, 'bipolar', 'serum pan L/R bipolar'); eq(FP.compact('-50 L'), '50L', 'pan L'); eq(FP.compact(' 0'), '0', 'pan centre plain number')
eq(cls(se, 'A Octave').kind, 'bipolar', 'serum octave bipolar'); eq(FP.compact('+2 oct'), '+2oct', 'oct compact')
eq(cls(se, 'A Fine').kind, 'bipolar', 'serum cents bipolar')
eq(cls(se, 'Porta Time').kind, 'time', 'serum porta time'); eq(cls(se, 'Porta Time').log, true, 'porta log')
eq(cls(se, 'Mono Toggle').kind, 'toggle', 'serum toggle')
eq(cls(se, 'A Loop Mode').kind, 'steps', 'serum loop mode steps')
eq(cls(se, 'A Coarse Pitch').kind ~= 'steps', true, 'coarse pitch with -- in the middle - not steps')
eq(cls(se, 'A Hz Offset').kind, 'bipolar', 'serum hz offset bipolar')
local okall = true
for _, p in ipairs(se.params) do if not pcall(FP.classify, p.t, p.toggle) or not pcall(FP.compact, p.t[3]) then okall = false end end
eq(okall, true, 'serum: every parameter classifies and compacts')
local sen = {}; for _, p in ipairs(se.params) do sen[#sen + 1] = p.name end
local nenv = 0; for _ in pairs(FP.adsr_groups(sen)) do nenv = nenv + 1 end
eq(nenv >= 4, true, 'serum: Env 1..4 (A H D S R) found ' .. nenv)
-- огибающие
local G = FP.adsr_groups({ 'cutoff', 'attack', 'decay', 'sustain', 'release', 'f att', 'f dec', 'f sus', 'f rel', 'Env 2 Attack', 'Env 2 Decay', 'Env 2 Sustain', 'Env 2 Release' })
eq(G[2] and G[2].r, 5, 'adsr plain words'); eq(G[6] and G[6].r, 9, 'adsr abbreviated with prefix'); eq(G[10] and G[10].last, 13, 'adsr numbered group')
local G2 = FP.adsr_groups({ 'Amp Attack', 'Filter Decay', 'Amp Sustain', 'Amp Release' })
eq(next(G2), nil, 'different groups - not one envelope')
local G3 = FP.adsr_groups({ '1 A', '1 D', '1 S', '1 R', 'A', 'mix', 'D' })
eq(G3[1] and G3[1].r, 4, 'single letters - full quartet'); eq(G3[5], nil, 'a lone A - not an envelope')
eq(next(FP.adsr_groups({ 'attack', 'decay', 'release' })), nil, 'three of four - no')
-- на образце Surge: огибающие Amp EG / Filter EG находятся (attack, attack shape, decay … — не подряд → без графика)
local sgn = {}; for _, p in ipairs(sg.params) do sgn[#sgn + 1] = p.name end
local cntS = 0; for _ in pairs(FP.adsr_groups(sgn)) do cntS = cntS + 1 end
eq(cntS >= 0, true, 'surge names run without error')
local GH = FP.adsr_groups({ 'Env 1 Attack', 'Env 1 Hold', 'Env 1 Decay', 'Env 1 Sustain', 'Env 1 Release' })
eq(GH[1] and GH[1].h, 2, 'hold between attack and decay'); eq(GH[1] and GH[1].last, 5, 'A H D S R - five rows')
local GS = FP.adsr_groups({ 'attack', 'attack shape', 'decay', 'decay shape', 'sustain', 'release' })
eq(GS[1] and GS[1].role[2], 'x', 'surge: attack shape inside the group'); eq(GS[1] and GS[1].r, 6, 'surge: release last')
local cntSg = 0; for _ in pairs(FP.adsr_groups(sgn)) do cntSg = cntSg + 1 end
eq(cntSg >= 2, true, 'surge sample: Amp EG / Filter EG found ' .. cntSg)
local rsn = {}; for _, p in ipairs(rs.params) do rsn[#rsn + 1] = p.name end
eq(next(FP.adsr_groups(rsn)), nil, 'rs5k: attack / release apart - no envelope')
print(('test_fxparse: %d checks, %d failed'):format(n, bad)); os.exit(bad == 0 and 0 or 1)
