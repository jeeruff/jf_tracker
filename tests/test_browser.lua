-- test_browser.lua — поиск браузера на стабах (без REAPER): lua tests/test_browser.lua
package.path = '/Users/jeeruff/Library/Application Support/REAPER/Scripts/jf_tracker/?.lua;' .. package.path
local tree = { ['/r'] = { dirs = { 'Drums', 'Bass' }, files = { 'loop.wav' } },
  ['/r/Drums'] = { dirs = { 'Kicks' }, files = { 'snare 01.wav', 'hat_open.wav' } },
  ['/r/Drums/Kicks'] = { dirs = {}, files = { 'kick_808.wav', 'Kick Hard.aif' } },
  ['/r/Bass'] = { dirs = {}, files = { 'sub_bass.wav' } } }
reaper = {
  EnumerateSubdirectories = function(p, i) local t = tree[p]; return t and t.dirs[i + 1] end,
  EnumerateFiles = function(p, i) local t = tree[p]; return t and t.files[i + 1] end,
  GetResourcePath = function() return '/tmp' end,
}
local B = dofile('/Users/jeeruff/Library/Application Support/REAPER/Scripts/jf_tracker/jf_tracker_browser.lua')
B.init({}, '/r')
B.path = '/r'; B.mode = 'files'; B.refresh()
local n, bad = 0, 0
local function eq(name, got, want) n = n + 1; if got ~= want then bad = bad + 1; print(('FAIL %s: got %s want %s'):format(name, tostring(got), tostring(want))) end end
local function names() local t = {}; for _, e in ipairs(B.entries) do t[#t + 1] = e.name end; return table.concat(t, ',') end
eq('listing', names(), 'Bass,Drums,loop.wav')
B.start_find(); for c in ('kick'):gmatch('.') do B.key(c:byte()) end
eq('recursive kick first', B.entries[1] and B.entries[1].name:match('[^/]+$'):lower():find('kick') ~= nil, true)
eq('kick count (folder + 2 files)', #B.entries, 3)
B.key(27); eq('esc restores listing', names(), 'Bass,Drums,loop.wav')
B.start_find(); for c in ("'hat"):gmatch('.') do B.key(c:byte()) end
eq('exact term', names(), 'Drums/hat_open.wav')
B.key(27); B.start_find(); for c in ('wav !kick'):gmatch('.') do B.key(c:byte()) end
eq('negation drops kicks', names():find('kick') == nil, true)
B.key(27)
-- контекст: из подпапки Drums ищем — только внутри неё
B.path = '/r/Drums'; B.refresh(); B.start_find(); for c in ('bass'):gmatch('.') do B.key(c:byte()) end
eq('folder scope: no bass in Drums', #B.entries, 0)
B.key(27); B.start_find(); for c in ('^kick'):gmatch('.') do B.key(c:byte()) end
eq('^ prefix on basename (folder Kicks + 2 files)', #B.entries, 3)
B.key(13); eq('Enter keeps results', #B.entries, 3); eq('typing stopped', B.filtering, false)
print(('%d checks, %d failed'):format(n, bad))
