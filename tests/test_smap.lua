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
eq('nodes', #G.nodes, 4)
eq('hubs', #G.hubs, 4)   -- hat, snare, /kicks (a.wav), kick
local n = 0
while SM.step(G) and n < 1000 do n = n + 1 end
eq('cools', n < 1000, true)
local ok = true
for _, a in ipairs(G.all) do if a.x ~= a.x or math.abs(a.x) > 5 then ok = false end end
eq('finite', ok, true)
print(('%d checks, %d failed'):format(checks, fails)); os.exit(fails == 0 and 0 or 1)
