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
  GetExtState = function(sec, k) return (EXT or {})[k] or '' end,
  SetExtState = function(sec, k, v) EXT = EXT or {}; EXT[k] = v end,
  DeleteExtState = function(sec, k) if EXT then EXT[k] = nil end end,
  RecursiveCreateDirectory = function(p) local par, nm = p:match('^(.*)/([^/]+)$'); tree[p] = { dirs = {}, files = {} }; local t = tree[par]; if t then t.dirs[#t.dirs + 1] = nm end; return 1 end,
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
-- навигация 2 окт: история, закладки, путь, mkdir
B.filter = ''; B.filtering = false; B.mode = 'files'
B.path = '/r'; B.back, B.fwd = {}, {}; B.refresh()
B.cur = 2; B.enter(); eq('enter Drums', B.path, '/r/Drums')
B.up(); eq('up', B.path, '/r')
B.history(-1); eq('back → Drums', B.path, '/r/Drums')
B.history(1); eq('forward → /r', B.path, '/r')
B.up(); eq('up above root allowed', B.path, '/')
B.go('/r/Bass'); B.mark(1); eq('empty mark assigns', B.marks[1], '/r/Bass')
B.go('/r'); B.mark(1); eq('mark jumps', B.path, '/r/Bass')
B.go('/r'); B.key(('!'):byte()); eq('Shift+1 reassigns', B.marks[1], '/r')
B.key(('2'):byte()); eq('2 on empty assigns', B.marks[2], '/r')
local parts = B.path_parts('/r/Drums/Kicks')
eq('path parts', #parts, 4); eq('crumb path', parts[3].path, '/r/Drums')
B.go('/r'); eq('mkdir', B.mkdir('New Kit'), true); eq('mkdir selects', B.entries[B.cur].name, 'New Kit')
B.key(('H'):byte()); eq('H back', B.path ~= '/r', true)
-- *.* и .* (2 окт)
tree['/r'].files[#tree['/r'].files + 1] = 'notes.txt'
tree['/r'].files[#tree['/r'].files + 1] = '.hidden.wav'
B.go('/r'); B.all_files = false; B.hidden = false; B.refresh()
local has = function(nm) for _, e in ipairs(B.entries) do if e.name == nm then return e end end end
eq('txt hidden by default', has('notes.txt'), nil); eq('dot file hidden', has('.hidden.wav'), nil)
B.click('allfiles'); eq('*.* shows txt', has('notes.txt') ~= nil, true); eq('txt is other', has('notes.txt').other, true)
B.click('hidden'); eq('.* shows dot file', has('.hidden.wav') ~= nil, true)
eq('other not previewed', B.preview_path(has('notes.txt')), nil)
B.click('allfiles'); B.click('hidden')
print(('%d checks, %d failed'):format(n, bad))
