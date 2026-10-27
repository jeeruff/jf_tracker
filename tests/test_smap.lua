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
print(('%d checks, %d failed'):format(checks, fails)); os.exit(fails == 0 and 0 or 1)
