-- tests/test_beatbox.lua — класс по звуку (kNN отпечатков) и :beatbox (удары огибающей, три класса относительно)
local DIR = debug.getinfo(1, 'S').source:match('^@(.*)/tests/') or '.'
reaper = reaper or {}
local SM = dofile(DIR .. '/jf_tracker_smap.lua')
local fails, n = 0, 0
local function ok(c, msg) n = n + 1; if not c then fails = fails + 1; print('FAIL ' .. msg) end end

-- удары: три всплеска с затуханием, 5 мс столбец
local env = {}
for i = 1, 300 do env[i] = 0.01 end
for _, at in ipairs({ 20, 120, 200 }) do for k = 0, 30 do env[at + k] = math.max(env[at + k], 0.9 * 0.85 ^ k) end end
local on = SM.onsets(env, 0.005)
ok(#on == 3 and on[1] == 20 and on[2] == 120 and on[3] == 200, 'three onsets ' .. table.concat(on, ' '))
-- быстрая дробь ближе gap — один удар
local e2 = {}
for i = 1, 100 do e2[i] = 0.01 end
e2[10], e2[14] = 0.9, 0.9
ok(#SM.onsets(e2, 0.005) == 1, 'hits closer than gap merge')
ok(#SM.onsets({ 0, 0, 0 }, 0.005) == 0, 'silence - no onsets')
local e3 = { 0.9, 0.7, 0.5, 0.3, 0.1, 0.05, 0.02 }
ok(#SM.onsets(e3, 0.005) == 1 and SM.onsets(e3, 0.005)[1] == 1, 'a hit at the very start of the file')

-- классы битбокса: тёмный тональный → 1, средний → 2, яркий шумный → 3
local F = { { b = 0.2, nz = 0.2, bt = 0.6 }, { b = 0.55, nz = 0.6, bt = 0.1 }, { b = 0.85, nz = 0.9, bt = 0 }, { b = 0.22, nz = 0.25, bt = 0.5 }, { b = 0.8, nz = 0.85, bt = 0 } }
local cls = SM.bb_classify(F)
ok(cls[1] == 1 and cls[4] == 1 and cls[2] == 2 and cls[3] == 3 and cls[5] == 3, 'beatbox classes ' .. table.concat(cls, ' '))
ok(#SM.bb_classify({}) == 0, 'no hits')
local one = SM.bb_classify({ { b = 0.2, nz = 0.1, bt = 0.5 } })
ok(one[1] == 1, 'a single dark hit is a kick')

-- класс по звуку: размеченные отпечатки kick (тёмные, мягкие) и hat (яркие, резкие)
SM.AN = {}
local nodes = {}
for i = 1, 10 do
  local pk, ph = '/k' .. i .. '.wav', '/h' .. i .. '.wav'
  SM.AN[pk] = { l = 0.6, b = 0.2 + i * 0.005, at = 0.4, dc = 0.6, nz = 0.2, bt = 0.6 }
  SM.AN[ph] = { l = 0.4, b = 0.85 - i * 0.005, at = 0.05, dc = 0.2, nz = 0.9, bt = 0 }
  nodes[#nodes + 1] = { path = pk, cat = 'kick' }; nodes[#nodes + 1] = { path = ph, cat = 'hat' }
end
nodes[#nodes + 1] = { path = '/x.wav', cat = 'other' }
SM.AN['/x.wav'] = { l = 0.5, b = 0.83, at = 0.06, dc = 0.22, nz = 0.88, bt = 0 }
local lab = SM.lab_build(nodes)
ok(#lab == 20, 'only named drum files are labelled')
local c, p = SM.guess_cat(SM.AN['/x.wav'], lab)
ok(c == 'hat' and p > 0.9, 'unnamed bright file sounds like hat ' .. tostring(c))
ok(SM.guess_cat({ l = 0.6, b = 0.21, at = 0.4, dc = 0.6, nz = 0.2, bt = 0.6 }, lab) == 'kick', 'dark one is kick')
ok(SM.guess_cat(SM.AN['/x.wav'], { lab[1] }) == nil, 'too few labelled - no guess')

print(('test_beatbox: %d/%d ok'):format(n - fails, n))
os.exit(fails == 0 and 0 or 1)
