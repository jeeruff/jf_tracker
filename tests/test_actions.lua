-- tests/test_actions.lua — панель actions: группы, фильтр, избранное и недавние (16 окт)
local DIR = debug.getinfo(1, 'S').source:match('^@(.*)/tests/') or '.'
local A = dofile(DIR .. '/jf_tracker_actions.lua')
local n, bad = 0, 0
local function eq(name, got, want)
  n = n + 1
  if got ~= want then bad = bad + 1; print(('FAIL %s: got %s want %s'):format(name, tostring(got), tostring(want))) end
end

eq('group: Script', A.group_of('Script: jf_tracker.lua'), 'script')
eq('group: Item', A.group_of('Item: Split items at cursor'), 'item')
eq('group: SWS/S&M', A.group_of('SWS/S&M: Open notes'), 'sws/s&m')
eq('group: no prefix', A.group_of('Transport: Play'), 'transport')
eq('group: plain', A.group_of('Undo'), 'other')
eq('group: digits are not a group', A.group_of('Track 1: something'), 'other')

local list = {
  { label = 'Item: Split items at edit cursor', key = '40757' },
  { label = 'Script: jf_tracker.lua', key = '_RSabc' },
  { label = 'Transport: Play/stop', key = '40044' },
  { label = 'Item: Select all items', key = '40182' },
  { label = 'Undo', key = '40029' },
}
local g = A.groups(list)
eq('groups: item first (2)', g[1].name, 'item'); eq('groups: item n', g[1].n, 2)
eq('groups: other last', g[#g].name, 'other')

local f = A.filter(list, 'split', 'all')
eq('filter: split -> 1', #f, 1); eq('filter: split item', f[1].key, '40757')
f = A.filter(list, 'ply', 'all')
eq('filter: letters in order', f[1] and f[1].key, '40044')
f = A.filter(list, 'item sel', 'all')
eq('filter: two words', f[1] and f[1].key, '40182')
f = A.filter(list, 'it', 'all')
eq('filter: word start ranks first', f[1].label:match('^Item') ~= nil, true)
f = A.filter(list, '', 'item')
eq('filter: group only', #f, 2)
local fav = A.set_decode('_RSabc,40029')
f = A.filter(list, '', 'favourites', fav)
eq('filter: favourites', #f, 2)
local rec = A.recent_push(A.recent_push({}, '40044'), '40029')
eq('recent: newest first', rec[1], '40029')
f = A.filter(list, '', 'recent', nil, rec)
eq('filter: recent order', f[1].key, '40029'); eq('filter: recent n', #f, 2)
eq('recent: no duplicates', #A.recent_push(rec, '40044'), 2)
eq('key: named', A.key_of(5, 'RSabc'), '_RSabc'); eq('key: number', A.key_of(40044, ''), '40044')
eq('set: roundtrip', A.set_encode(A.set_decode('b,a')), 'a,b')
print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
