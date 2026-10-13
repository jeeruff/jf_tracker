-- test_sustain.lua — луп удержания: хвост ноты (plan), метка, БПФ, поиск точек на синтетике.
-- Запуск: lua tests/test_sustain.lua
local DIR = (arg and arg[0] or ''):match('(.*)/tests/') or '.'
local S = dofile(DIR .. '/jf_tracker_sustain.lua')
local fails, checks = 0, 0
local function ok(name, cond, info)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL ' .. name .. (info and (': ' .. info) or '')) end
end
local function near(name, got, want, eps) ok(name, got ~= nil and math.abs(got - want) <= (eps or 1e-9), ('got %s, want %s'):format(tostring(got), tostring(want))) end

-- 1. хвост: нота с начала сэмпла, rate 1 — хвост с ls, встык
local lp = { ls = 0.5, le = 1.0 }
local p = S.plan({ pos = 10, len = 3, offs = 0, rate = 1 }, lp)
near('plan: tail starts where the head reaches ls', p.pos, 10.5)
near('plan: tail to the note end', p.len, 2.5)
near('plan: tail offset 0 in the section', p.offs, 0)
-- 2. rate 2: до ls вдвое быстрее; offs инструмента 0.1
p = S.plan({ pos = 0, len = 2, offs = 0.1, rate = 2 }, lp)
near('plan rate 2: (0.5 - 0.1) / 2', p.pos, 0.2)
-- 3. нота кончается до лупа — хвоста нет
ok('plan: a short note has no tail', S.plan({ pos = 0, len = 0.4, offs = 0, rate = 1 }, lp) == nil)
-- 4. правая часть реза начинается внутри лупа (offs 0.7) и после его конца (offs 1.3 → фаза 0.3)
p = S.plan({ pos = 5, len = 1, offs = 0.7, rate = 1 }, lp)
near('plan: note inside the loop - tail from the note start', p.pos, 5)
near('plan: phase in the loop', p.offs, 0.2)
p = S.plan({ pos = 5, len = 1, offs = 1.3, rate = 1 }, lp)
near('plan: past the loop end - phase wraps', p.offs, 0.3, 1e-9)
-- 5. метка
local t = S.parse(S.tag({ on = true, ls = 0.25, le = 0.75, xf = 0.01 }))
ok('tag round trip', t and t.on and math.abs(t.ls - 0.25) < 1e-9 and math.abs(t.le - 0.75) < 1e-9 and math.abs(t.xf - 0.01) < 1e-9)
t = S.parse(S.tag({ on = false, ls = 0.25, le = 0.75, xf = 0 }))
ok('tag off keeps the points', t and not t.on and math.abs(t.le - 0.75) < 1e-9)
ok('tag: garbage', S.parse('') == nil and S.parse('1 0.5 0.2 0') == nil)

-- 6. БПФ: синус на бине 8 из 64
local re, im = {}, {}
for i = 1, 64 do re[i] = math.sin(2 * math.pi * 8 * (i - 1) / 64); im[i] = 0 end
S._fft(re, im, 64)
local mb, mv = 0, 0
for k = 1, 32 do local m = re[k] ^ 2 + im[k] ^ 2; if m > mv then mv, mb = m, k - 1 end end
ok('fft: the peak at bin 8', mb == 8, 'bin ' .. mb)

-- 7. поиск на синтетике: пэд 220 Гц + 330 Гц, атака 50 мс, спад в конце
local sr = 22050
local function pad(sec, f)
  local x = {}
  local n = math.floor(sec * sr)
  for i = 1, n do
    local tt = (i - 1) / sr
    local env = math.min(1, tt / 0.05) * (tt > sec - 0.3 and math.max(0, (sec - tt) / 0.3) or 1)
    x[i] = env * (0.6 * math.sin(2 * math.pi * f * tt) + 0.3 * math.sin(2 * math.pi * f * 1.5 * tt + 0.3))
  end
  return x
end
local x = pad(2.0, 220)
local r, why = S.find(x, sr, 1, #x)
ok('find: found on a pad', r ~= nil, why)
if r then
  local L = (r.le - r.ls) / sr
  ok('find: after the attack', r.ls / sr > 0.05, ('ls %.3f'):format(r.ls / sr))
  ok('find: before the release', r.le / sr < 1.7, ('le %.3f'):format(r.le / sr))
  ok('find: a long loop (> 0.5 s)', L > 0.5, ('%.3f s'):format(L))
  ok('find: the seam matches (> 0.98)', r.match > 0.98, ('%.3f'):format(r.match))
  -- шов без скачка: отсчёт перед le близок к отсчёту перед ls
  ok('find: no jump at the seam', math.abs(x[r.le - 1] - x[r.ls - 1]) < 0.05, ('%.4f vs %.4f'):format(x[r.le - 1], x[r.ls - 1]))
  ok('find: ls on a rising zero cross', x[r.ls - 1] < 0 and x[r.ls] >= 0)
end
-- 8. 808: синус 55 Гц с экспоненциальным спадом — луп всё равно находится
local k8 = {}
for i = 1, math.floor(1.5 * sr) do local tt = (i - 1) / sr; k8[i] = math.exp(-tt * 2.5) * math.sin(2 * math.pi * 55 * tt) end
r, why = S.find(k8, sr, 1, #k8)
ok('find: an 808 gets a loop', r ~= nil, why)
if r then ok('find 808: the seam matches (> 0.9)', r.match > 0.9, ('%.3f'):format(r.match)) end
-- 9. тишина и короткий
ok('find: silence', S.find((function() local z = {}; for i = 1, sr do z[i] = 0 end; return z end)(), sr, 1, sr) == nil)
ok('find: too short', S.find(pad(0.1, 220), sr) == nil)

-- 10. запечённый луп (13 окт): 808 со спадом и уходом высоты — точки наугад, шов всё равно непрерывен
do
  local x = {}
  local ph = 0
  for i = 1, math.floor(1.0 * sr) do
    local tt = (i - 1) / sr
    ph = ph + 2 * math.pi * (60 + 40 * math.exp(-tt * 6)) / sr      -- высота плывёт вниз
    x[i] = math.exp(-tt * 3) * math.sin(ph)
  end
  local ls, le, X = math.floor(0.31 * sr), math.floor(0.57 * sr), math.floor(0.03 * sr)
  -- без запекания: скачок на шве (x[le] → x[ls+1]) против обычного шага соседей
  local step = 0
  for i = ls, le - 2 do step = math.max(step, math.abs(x[i + 1] - x[i])) end
  local o, X2 = S.bake({ x }, ls, le, X)
  o = o[1]
  ok('bake: the loop starts after X frames of pre-roll', X2 == X and #o == le - ls + X, #o .. ' ' .. X2)
  ok('bake: the loop end ends as the frame before ls', math.abs(o[#o] - x[ls]) < 1e-9)
  local jump = math.abs(o[X + 1] - o[#o])
  ok('bake: the wrap jump is like a normal step', jump <= step * 1.01, ('%.4f vs step %.4f'):format(jump, step))
  ok('bake: before the fade the loop is the file', math.abs(o[X + 1] - x[ls + 1]) < 1e-12 and math.abs(o[X + 10] - x[ls + 10]) < 1e-12)
  -- WAV туда-обратно
  local path = os.tmpname() .. '.wav'
  ok('wav write', S.wav_write(path, sr, { o, o }))
  local w = S.wav_read(path)
  ok('wav read back', w and w.sr == sr and #w.ch == 2 and w.n == #o and math.abs(w.ch[2][100] - o[100]) < 1e-6)
  os.remove(path)
  -- метка с файлом
  local t2 = S.parse(S.tag({ on = true, ls = 0.3, le = 0.6, xf = 0.03, boff = 0.03, file = '/a b/c d.wav', bls = 0.3, ble = 0.6 }))
  ok('tag with the baked file', t2 and t2.file == '/a b/c d.wav' and math.abs(t2.boff - 0.03) < 1e-9)
  local t3 = S.parse(S.tag({ on = true, ls = 0.31, le = 0.6, xf = 0.03, boff = 0.03, file = '/a.wav', bls = 0.3, ble = 0.6 }))
  ok('13 окт: the file baked at other points is dropped (click on S)', t3 and t3.file == nil and t3.boff == nil)
  local t4 = S.parse('1 0.300000 0.600000 0.030000 0.030000 /old.wav')
  ok('  an old tag without b= - baked again', t4 and t4.file == nil)
end

-- 11. выравнивание громкости (13 окт): спад 808 — в запечённом лупе уровень ровный, конец ≈ начало
do
  local x = {}
  for i = 1, math.floor(1.2 * sr) do local tt = (i - 1) / sr; x[i] = math.exp(-tt * 3) * math.sin(2 * math.pi * 55 * tt) end
  local ls, le, X = math.floor(0.3 * sr), math.floor(1.0 * sr), math.floor(0.1 * sr)
  local function rms(o, a, n) local e = 0; for i = a, a + n - 1 do e = e + o[i] ^ 2 end; return math.sqrt(e / n) end
  local n = math.floor(0.1 * sr)
  local raw = S.bake({ x }, ls, le, X)[1]
  local o = S.bake({ x }, ls, le, X, sr)[1]
  local r0, r1 = rms(raw, X + 1, n), rms(raw, #raw - X - n, n)
  local f0, f1 = rms(o, X + 1, n), rms(o, #o - X - n, n)
  ok('flatten: raw loop decays', r1 / r0 < 0.25, ('%.3f'):format(r1 / r0))
  ok('flatten: the flattened loop keeps its level', f1 / f0 > 0.9 and f1 / f0 < 1.1, ('%.3f'):format(f1 / f0))
  ok('flatten: the loop start is untouched (joins the head)', math.abs(o[X + 1] - x[ls + 1]) < 0.02 * f0 * 1.5, ('%.4f vs %.4f'):format(o[X + 1], x[ls + 1]))
end

-- 12. фаза кроссфейда (13 окт): точка конца сдвигается к лучшей фазе; метка с кривой и уровнем
do
  local x, ph = {}, 0
  for i = 1, math.floor(1.0 * sr) do ph = ph + 2 * math.pi * 110 / sr; x[i] = math.sin(ph) end
  local ls, X = math.floor(0.3 * sr), math.floor(0.1 * sr)
  local le = ls + math.floor(0.5 * sr) + 37                       -- не кратно периоду
  local nle = S.align({ x }, ls, le, X, sr)
  local per = sr / 110
  local off = ((nle - ls) / per) % 1
  ok('align: the new loop length is a whole number of periods', math.min(off, 1 - off) < 0.03, ('%.3f periods off, moved %d'):format(math.min(off, 1 - off), nle - le))
  ok('align: within 20 ms', math.abs(nle - le) <= 0.02 * sr)
  local _, _, le2 = S.bake({ x }, ls, le, X, sr, { flat = false })
  ok('bake returns the aligned end', le2 == nle)
  local t = S.parse(S.tag({ on = true, ls = 0.3, le = 0.6, xf = 0.2, curve = 's', flat = false, boff = 0.2, file = '/x y.wav', bls = 0.3, ble = 0.6 }))
  ok('tag with curve / level / file', t and t.curve == 's' and t.flat == false and t.file == '/x y.wav' and math.abs(t.boff - 0.2) < 1e-9)
  t = S.parse('1 0.3 0.6 0.01')
  ok('old tag: auto curve, level on', t and t.curve == 'auto' and t.flat == true)
end

print(('%d checks, %d failed'):format(checks, fails))
os.exit(fails == 0 and 0 or 1)
