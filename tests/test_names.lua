-- test_names.lua — подсказки имён: правила SWS, слияние, префиксы строк
package.path = package.path
reaper = { GetResourcePath = function() return '/nonexistent' end }
local DIR = debug.getinfo(1, 'S').source:match('^@(.*)/tests/') or '.'
local N = dofile(DIR .. '/jf_tracker_names.lua')
local n, bad = 0, 0
local function ok(c, m) n = n + 1; if not c then bad = bad + 1; print('FAIL ' .. m) end end
local tmp = os.tmpname()
local f = io.open(tmp, 'w')
f:write('[SWS]\nAutoColor 1=0 kick 1 "a.png" "" ""\nAutoColor 2=0 "bass guitar" 2 "" "" ""\nAutoColor 3=0 (children) -5 "" "" ""\nAutoColor 4=1 verse 3 "" "" ""\nAutoColorCount=4\n')
f:close()
local s = N.sws(tmp); os.remove(tmp)
ok(#s == 2, 'two type-0 rules, got ' .. #s)
ok(s[1] == 'kick' and s[2] == 'bass guitar', 'quoted names')
local l = N.list('track')
local seen, dup = {}, false
for _, x in ipairs(l) do if seen[x:lower()] then dup = true end; seen[x:lower()] = true end
ok(not dup, 'no duplicates')
ok(seen.texture and seen.bell and seen.perc and seen.bassguitar and seen.amp, 'defaults present')
ok(N.list('region')[1] == 'intro', 'region list')
local p, k = N.target('iprop name foo'); ok(p == 'iprop name ' and k == 'item', 'iprop name prefix')
p, k = N.target('tname '); ok(k == 'track', 'tname')
p, k = N.target('name x'); ok(k == 'region', 'region name')
ok(N.target('lpb 4') == nil, 'other commands ignored')
print(('%d checks, %d failed'):format(n, bad))
