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
eq(#FP.abbr('Gain for minimum velocity', 10) <= 10, true, 'never longer than asked')
eq(FP.abbr('Highpass', 4), 'hp', 'highpass -> hp')
eq(FP.abbr('Feedback', 4), 'fb', 'feedback -> fb')
print(('test_fxparse: %d checks, %d failed'):format(n, bad)); os.exit(bad == 0 and 0 or 1)
