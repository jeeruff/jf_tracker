-- test_macros.lua — вкладка macros: lua tests/test_macros.lua
local MR = dofile('jf_tracker_macros.lua')
local n, bad = 0, 0
local function eq(name, got, want) n = n + 1; if got ~= want then bad = bad + 1; print(('FAIL %s: got %s, want %s'):format(name, tostring(got), tostring(want))) end end
local keys = { 100, 100, 106, 13, 60, 27 }
local s = MR.encode(keys)
eq('encode', s, 'ddj<13><60><27>')
local back = MR.decode(s)
eq('decode len', #back, 6); eq('decode enter', back[4], 13); eq('decode <', back[5], 60)
local list = MR.parse('# c\nmy fill\t:scramble\nbad line\nhop\tjjj<13>\n')
eq('parse count', #list, 2); eq('parse name', list[1].name, 'my fill'); eq('parse body', list[2].body, 'jjj<13>')
eq('serialize round trip', #MR.parse(MR.serialize(list)), 2)
local rows = MR.rows({ ['@a'] = { 100, 100 }, ['@b'] = {}, ['"'] = { 1 } }, list)
local rec = 0; for _, r in ipairs(rows) do if r.kind == 'rec' then rec = rec + 1 end end
eq('only non-empty letter registers', rec, 1)
MR.sel = 1
local r = MR.key(13, rows)
eq('Enter plays the first macro', type(r) == 'table' and r.kind, 'play')
eq('first selectable is @a', r.row.name, 'a')
eq('s saves recorded', MR.key(('s'):byte(), rows).kind, 'save')
MR.key(('j'):byte(), rows); MR.key(('j'):byte(), rows)
eq('d on saved deletes', MR.key(('d'):byte(), rows).kind, 'delete')
eq('unknown key passes', MR.key(('z'):byte(), rows), nil)
print(('test_macros: %d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
