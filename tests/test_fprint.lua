-- tests/test_fprint.lua — отпечаток звука из пиков (SM.an_fine, SM.fp_dist): хэт резче шейкера, шум шумнее тона
local DIR = debug.getinfo(1, 'S').source:match('^@(.*)/tests/') or '.'
reaper = nil
local SM = dofile(DIR .. '/jf_tracker_smap.lua')
local fails, n = 0, 0
local function ok(c, msg) n = n + 1; if not c then fails = fails + 1; print('FAIL ' .. msg) end end
-- пики: n столбцов, огибающая env(i), частота spec(i)
local function pk(nn, env, freq)
  local p = { n = nn, max = {}, min = {}, spec = {} }
  for i = 1, nn do local a = env(i); p.max[i] = a; p.min[i] = -a; p.spec[i] = freq(i) end
  return p
end
local T = 0.4
-- спектр REAPER: частота в младших 15 битах, тональность (0 шум .. 16383 тон) — в следующих 14
local function sp(f, ton) return f + ton * 32768 end
local hat = SM.an_fine(pk(200, function(i) return i < 2 and 0 or math.exp(-(i - 2) / 6) end, function(i) return sp(6000 + (i * 7919 % 5000), 2000) end), T)
local shaker = SM.an_fine(pk(200, function(i) return math.min(1, i / 25) * math.exp(-math.max(0, i - 25) / 30) end, function(i) return sp(5000 + (i * 7919 % 5000), 2500) end), T)
local tone = SM.an_fine(pk(200, function(i) return i < 2 and 0 or math.exp(-(i - 2) / 80) end, function() return sp(110, 15000) end), T)
ok(hat.at < shaker.at, ('hat attack sharper than shaker: %.2f < %.2f'):format(hat.at, shaker.at))
ok(tone.dc > hat.dc, ('tone decays longer than hat: %.2f > %.2f'):format(tone.dc, hat.dc))
ok(hat.nz > tone.nz, ('hat noisier than a tone: %.2f > %.2f'):format(hat.nz, tone.nz))
local function fp(t, b) return { l = 0.5, b = b, at = t.at, dc = t.dc, nz = t.nz } end
local hat2 = SM.an_fine(pk(200, function(i) return i < 3 and 0 or math.exp(-(i - 3) / 7) end, function(i) return sp(6500 + (i * 104729 % 4000), 2100) end), T)
ok(SM.fp_dist(fp(hat, 0.8), fp(hat2, 0.8)) < SM.fp_dist(fp(hat, 0.8), fp(shaker, 0.8)), 'a hat is nearer to another hat than to a shaker')
ok(SM.fp_dist(fp(hat, 0.8), { l = 0.5, b = 0.8 }) == 9, 'no fingerprint - far away')
-- тон тела: низ тональный (бочка) против высокого шума (хэт)
local kick = SM.an_fine(pk(200, function(i) return i < 2 and 0 or math.exp(-(i - 2) / 40) end, function() return sp(60, 15000) end), T)
ok(kick.bt > 0.8 and hat.bt < 0.05, ('body tone: kick %.2f, hat %.2f'):format(kick.bt, hat.bt))
print(('test_fprint: %d/%d ok'):format(n - fails, n))
os.exit(fails == 0 and 0 or 1)
