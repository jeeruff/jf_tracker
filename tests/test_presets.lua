-- test_presets.lua — 16 окт: блоки чанка, цепочка FX шаблона на трек, шаблон без items
local DIR = debug.getinfo(1, 'S').source:match('^@(.*)/tests/') or '.'
local P = dofile(DIR .. '/jf_tracker_presets.lua')
local n, bad = 0, 0
local function eq(name, got, want) n = n + 1; if got ~= want then bad = bad + 1; print(('FAIL %s: got %s want %s'):format(name, tostring(got), tostring(want))) end end

local trk = table.concat({ '<TRACK {A}', '  NAME "drums"', '  <FXCHAIN', '    <VST "old"', '      abc', '    >', '  >', '  <ITEM', '    POSITION 0', '    <SOURCE WAVE', '      FILE "x.wav"', '    >', '  >', '>' }, '\n')
local tpl = table.concat({ '<TRACK {B}', '  NAME "bass preset"', '  <FXCHAIN', '    <VST "Surge XT"', '      zzz', '    >', '    <JS "eq"', '    >', '  >', '>', '<TRACK {C}', '  <FXCHAIN', '  >', '>' }, '\n')
local L = {}; for l in (trk .. '\n'):gmatch('([^\n]*)\n') do L[#L + 1] = l end
local a, b = P.find_block(L, 'FXCHAIN', 1)
eq('fxchain start', a, 3); eq('fxchain end', b, 7)
local ia, ib = P.find_block(L, 'ITEM', 1)
eq('item block', ia, 8); eq('item end', ib, 13)
eq('nested source not at depth 1', (P.find_block(L, 'SOURCE', 1)), nil)
eq('first track only', P.first_track(tpl):find('{C}', 1, true), nil)
local out = P.apply_fxchain(trk, tpl)
eq('new fx in', out:find('Surge XT', 1, true) ~= nil, true)
eq('old fx gone', out:find('"old"', 1, true), nil)
eq('items kept', out:find('x.wav', 1, true) ~= nil, true)
eq('name kept', out:find('NAME "drums"', 1, true) ~= nil, true)
local nofx = '<TRACK {D}\n  NAME "t"\n>'
local o2 = P.apply_fxchain(nofx, tpl)
eq('fxchain added to a track without one', o2 and o2:find('Surge XT', 1, true) ~= nil, true)
eq('ends with >', o2 and o2:sub(-1), '>')
local _, err = P.apply_fxchain(trk, '<TRACK\n>')
eq('template without fx', err, 'the template has no fx')
local t3 = P.template_of(trk)
eq('template drops items', t3:find('x.wav', 1, true), nil)
eq('template keeps fx', t3:find('"old"', 1, true) ~= nil, true)
eq('file name', P.file_name('fat / bass'), 'fat _ bass.RTrackTemplate')

print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
