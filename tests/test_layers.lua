-- test_layers.lua — слоёный инструмент (jf_tracker_layers.lua). Запуск: lua tests/test_layers.lua
local DIR = (arg and arg[0] or ''):match('(.*)/tests/') or '.'
local LY = dofile(DIR .. '/jf_tracker_layers.lua')
local fails, checks = 0, 0
local function ok(name, cond, info) checks = checks + 1; if not cond then fails = fails + 1; print('FAIL ' .. name .. (info and (': ' .. tostring(info)) or '')) end end
local G1, G2 = '{AAAA-1}', '{BBBB-2}'
-- метка туда-обратно
local l1 = LY.new(G1); l1.offs, l1.pan, l1.vol, l1.semis = 12.5, -0.5, -6, 7
local l2 = LY.new(G2); l2.ck, l2.cn, l2.mute, l2.phase, l2.rvol = 2, 3, true, true, 3
local t = LY.tag({ l1, l2 })
local back = LY.parse(t)
ok('two layers back', #back == 2, t)
ok('fields back', back[1].guid == G1 and back[1].offs == 12.5 and back[1].pan == -0.5 and back[1].vol == -6 and back[1].semis == 7, t)
ok('cycle / flags back', back[2].ck == 2 and back[2].cn == 3 and back[2].mute and back[2].phase and back[2].rvol == 3, t)
ok('garbage -> empty', #LY.parse('zzz;;|1|2') == 0)
-- план: сдвиг, пан, громкость
local p = LY.plan(back[1], 1, 1, 42)
ok('plan dt ms -> s', p and math.abs(p.dt - 0.0125) < 1e-9)
ok('plan gain -6 dB', p and math.abs(p.gain - 10 ^ (-6 / 20)) < 1e-9)
ok('mute -> nil', LY.plan(back[2], 2, 2, 1) == nil)
-- циклы: 2/3 — играет 2-я, 5-я …
local c = LY.new(G1); c.ck, c.cn = 2, 3
ok('cycle 2/3: note 1 silent', LY.plan(c, 1, 1, 0) == nil)
ok('cycle 2/3: note 2 plays', LY.plan(c, 1, 2, 0) ~= nil)
ok('cycle 2/3: note 5 plays', LY.plan(c, 1, 5, 0) ~= nil)
-- фаза — знак громкости
local ph = LY.new(G1); ph.phase = true
ok('phase flips the gain', LY.plan(ph, 1, 1, 0).gain < 0)
-- рандом детерминирован по seed и в пределах
local r = LY.new(G1); r.rpan, r.rvol = 1, 6
local a1, a2, b1 = LY.plan(r, 1, 1, 7), LY.plan(r, 1, 1, 7), LY.plan(r, 1, 1, 8)
ok('same seed - same roll', a1.pan == a2.pan and a1.gain == a2.gain)
ok('other seed - other roll', a1.pan ~= b1.pan)
local inr = true
for s = 1, 200 do local q = LY.plan(r, 3, 1, s); if q.pan < -1 or q.pan > 1 or q.gain < 10 ^ (-6 / 20) - 1e-9 or q.gain > 10 ^ (6 / 20) + 1e-9 then inr = false end end
ok('random stays in range', inr)
-- align: b — та же синусоида, сдвинутая на 7 кадров
local A, B = {}, {}
for k = 1, 400 do A[k] = math.sin(k / 9) * math.exp(-k / 300) end
for k = 1, 400 do B[k] = A[k - 7] or 0 end
local d = LY.align(A, B, 200, 20)
ok('align finds the shift', d == 7, d)
print(('%d checks, %d failed'):format(checks, fails))
os.exit(fails == 0 and 0 or 1)
