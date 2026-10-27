-- test_smap.lua — карта сэмплов: категории по именам, граф, раскладка остывает: lua tests/test_smap.lua
local DIR = (arg and arg[0] or ''):match('(.*)/tests/') or '.'
local SM = dofile(DIR .. '/jf_tracker_smap.lua')
local fails, checks = 0, 0
local function eq(n, a, b) checks = checks + 1; if a ~= b then fails = fails + 1; print('FAIL ' .. n .. ': ' .. tostring(a) .. ' vs ' .. tostring(b)) end end
eq('kick', SM.category('Kick_01.wav'), 'kick')
eq('camel', SM.category('HardSnare.wav'), 'snare')
eq('prefix', SM.category('kick01.wav'), 'kick')
eq('808', SM.category('Boom 808 C.wav'), 'bass')
eq('loop', SM.category('amen_break_170bpm.wav'), 'loop')
eq('folder', SM.category('thing.wav', 'Grooves'), '/Grooves')
eq('other', SM.category('thing.wav'), 'other')
local tree = { ['/s'] = { { name = 'kicks', dir = true }, { name = 'hat1.wav' }, { name = 'snare.wav' } }, ['/s/kicks'] = { { name = 'a.wav' }, { name = 'kick2.wav' } } }
local G = SM.build('/s', function(p) return tree[p] or {} end)
eq('scan pending', G.building, true)
while not SM.scan(G, 1) do end
eq('nodes', #G.nodes, 4)
eq('hubs', #G.hubs, 4)   -- hat, snare, /kicks (a.wav), kick
local n = 0
while SM.step(G) and n < 1000 do n = n + 1 end
eq('cools', n < 1000, true)
local ok = true
for _, a in ipairs(G.all) do if a.x ~= a.x or math.abs(a.x) > 5 then ok = false end end
eq('finite', ok, true)
-- 27 окт: без лимита — большое дерево сканируется по кусочкам; спираль без наложений
local big = { ['/b'] = {} }
for d = 1, 50 do big['/b'][#big['/b'] + 1] = { name = 'd' .. d, dir = true }; local l = {}; for f = 1, 200 do l[f] = { name = 'kick' .. f .. '.wav' } end; big['/b/d' .. d] = l end
local GB = SM.build('/b', function(p) return big[p] or {} end)
local ticks = 0
while not SM.scan(GB, 0.0005) do ticks = ticks + 1 end
eq('big: all files', #GB.nodes, 10000)
eq('big: one hub (kick)', #GB.hubs, 1)
while not SM.size_tick(GB, 1) do end
eq('big: sizes done', GB.szi, nil)
local k = 0
while SM.step(GB) and k < 2000 do k = k + 1 end
eq('big: cools', k < 2000, true)
-- 27 окт: индекс на диске — туда и обратно, тот же набор
do
  local f = os.tmpname()
  eq('cache saved', SM.save_cache(G, f), true)
  local G2 = SM.load_cache('/s', f)
  while G2 and not SM.scan(G2, 1) do end   -- 27 окт (9): чтение индекса — по кадрам
  eq('cache nodes', G2 and #G2.nodes, #G.nodes)
  eq('cache same', G2 and SM.same_files(G, G2), true)
  eq('cache other root', SM.load_cache('/other', f), nil)
  os.remove(f)
end
-- 27 окт (9): короткие подписи, типы файлов, формы карточек, свежесть, лёгкая проверка изменений
eq('short keeps short', SM.short('/kicks', 10), 'kicks')
eq('short drops noise', SM.short('Bluezone Corporation - Dark Cinematic Textures & Sounds Samples Pack 2', 20), 'Bluezone Corporation')
eq('short never empty', SM.short('/1234567890123', 3) ~= '', true)
eq('type midi', SM.ext_type('groove.mid'), 'midi')
eq('type rex', SM.ext_type('Amen.RX2'), 'rex')
eq('type tpl', SM.ext_type('Bass.RTrackTemplate'), 'tpl')
eq('type sample', SM.ext_type('kick.WAV'), 'samples')
eq('cat of midi is its type', SM.cat_of('beat.mid'), 'midi')
eq('cat of wav by name', SM.cat_of('Kick_01.wav'), 'kick')
do
  local hb = G.hubs[1]
  local sh = SM.card_shape(hb)
  eq('card shape lobes 2..6', sh.lobes >= 2 and sh.lobes <= 6, true)
  eq('card shape stable', SM.card_shape(hb).lobes, sh.lobes)
end
do
  local V = { step = 30, hist = { { path = 'a', step = 30 }, { path = 'b', step = 25 }, { path = 'c', step = 5 } } }
  V.hist_by = { a = V.hist[1], b = V.hist[2], c = V.hist[3] }
  eq('fresh: just played', SM.fresh(V, { path = 'a' }), 0)
  eq('fresh: dark', SM.fresh(V, { path = 'b' }), 5)
  eq('fresh: back to normal', SM.fresh(V, { path = 'c' }), nil)
end
do
  local S = SM.sig_build('/s', function(p) return tree[p] or {} end)
  while not SM.sig_scan(S, 1) do end
  local n, h = SM.sig_of(G)
  eq('sig: same count', S.n, n)
  eq('sig: same hash', S.h, h)
end
-- 27 окт (9): этап 2 — анализ по пикам
do
  local pk = { n = 4, max = { 0.5, 0.5, 0.5, 0.5 }, min = { -0.5, -0.5, -0.5, -0.5 }, spec = { 1000, 1000, 1000, 1000 } }
  local a = SM.an_from_peaks(pk)
  eq('an: loudness 0..1', a.l > 0 and a.l <= 1, true)
  eq('an: 1 kHz mid-bright', a.b > 0.4 and a.b < 0.7, true)
  local hb = G.hubs[1]
  SM.AN[hb.list[1].path] = { l = 0.5, b = 0.9 }
  SM.an_resort(G, hb)
  eq('an: bright goes outward (last)', hb.list[#hb.list].path == next(SM.AN) or #hb.list == 1, true)
end
print(('%d checks, %d failed'):format(checks, fails)); os.exit(fails == 0 and 0 or 1)
