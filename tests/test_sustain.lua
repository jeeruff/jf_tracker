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

print(('%d checks, %d failed'):format(checks, fails))
os.exit(fails == 0 and 0 or 1)
