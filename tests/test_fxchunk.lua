-- test_fxchunk.lua — вырезать / вставить эффект через chunk трека: lua tests/test_fxchunk.lua
reaper = setmetatable({}, { __index = function() return function() return 0 end end })
local E = dofile('jf_tracker_edit.lua')
local n, bad = 0, 0
local function eq(name, got, want) n = n + 1; if got ~= want then bad = bad + 1; print(('FAIL %s: got %s, want %s'):format(name, tostring(got), tostring(want))) end end
local chunk = table.concat({
  '<TRACK', 'NAME a', '<FXCHAIN', 'SHOW 0', 'LASTSEL 0', 'DOCKED 0',
  'BYPASS 0 0 0', '<VST "VST: ReaEQ (Cockos)" reaeq.vst.dylib 0 "" 1', 'AAAA', '>', 'FXID {A}', 'WAK 0 0',
  'BYPASS 0 0 0', '<CONTAINER Container ""', 'BYPASS 0 0 0', '<JS inner ""', '>', 'FXID {C}', '>', 'FXID {B}', 'WAK 0 0',
  '>', '<ITEM', 'POSITION 0', '>', '>' }, '\n')
local seg1 = E.chunk_fx_get(chunk, 1)
eq('first fx text', seg1 and seg1:match('ReaEQ') ~= nil, true)
eq('first fx has its FXID', seg1 and seg1:match('FXID {A}') ~= nil, true)
eq('first fx stops before the second', seg1 and seg1:match('CONTAINER') == nil, true)
local seg2 = E.chunk_fx_get(chunk, 2)
eq('container with its child', seg2 and seg2:match('<JS inner') ~= nil and seg2:match('FXID {B}') ~= nil, true)
eq('no third', E.chunk_fx_get(chunk, 3), nil)
local g = 0
local out = E.chunk_fx_put(chunk, 1, seg2, function() g = g + 1; return '{N' .. g .. '}' end)
local lines = {}; for l in out:gmatch('[^\n]+') do lines[#lines + 1] = l end
local ch = E.chain_entries(lines)
eq('paste adds an entry', #ch.entries, 3)
eq('pasted first, new guid', E.chunk_fx_get(out, 1):match('FXID {N1}') ~= nil, true)
local bare = '<TRACK\nNAME b\n<ITEM\nPOSITION 0\n>\n>'
local out2 = E.chunk_fx_put(bare, 1, seg1)
local l2 = {}; for l in out2:gmatch('[^\n]+') do l2[#l2 + 1] = l end
eq('no chain: one created', E.chain_entries(l2) and #E.chain_entries(l2).entries, 1)
eq('chain before the item', out2:find('<FXCHAIN', 1, true) < out2:find('<ITEM', 1, true), true)
print(('test_fxchunk: %d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
