-- test_freesound_module.lua (2 ноя; 3 ноя — две колонки как lf) — клавиши модуля freesound на заглушках
package.path = './?.lua;' .. package.path
_G.reaper = { GetExtState = function() return 'k' end, GetResourcePath = function() return '/tmp/nonexist' end, time_precise = os.clock,
  RecursiveCreateDirectory = function() end, ExecProcess = function() end }
_G.gfx = {}
local M = dofile('modules/freesound.lua')
local libs, menu = {}, nil
M.init({ R = reaper, dir = '.', TX = dofile('jf_tracker_utf8.lua'), msg = function() end,
  preview_file = function() end, add_to_depot = function(p) libs[#libs + 1] = p end, menu = function(t, it) menu = it end })
local FS = M.FS
local n, bad = 0, 0
local function eq(name, got, want) n = n + 1; if got ~= want then bad = bad + 1; print(('FAIL %s: got %s, want %s'):format(name, tostring(got), tostring(want))) end end
local searched = {}
FS.search = function(q, page, append) searched[#searched + 1] = { q = q, page = page, append = append }; FS.query = q; FS.page = page or 1; return true end
FS.fetch = function(h, fn) fn('/x/' .. h.id) end
local function fill(nres)
  FS.results, FS.count = {}, 120
  for i = 1, nres do FS.results[i] = { id = i, name = 'n' .. i, user = 'u' .. ((i - 1) // 5 + 1), lic = 'CC0', tags = {} } end   -- по 5 звуков на автора
end
local function k(s) for ch in s:gmatch('.') do M.key(ch:byte()) end end
M.search('amen'); fill(50)
k('m'); eq('m on an author marks its 5 sounds', #libs, 0)
M.key(13); eq('Enter with marks - all into the lib', #libs, 5)
eq('order: first sound first', libs[1], '/x/1')
k('l'); k('j'); M.key(13); eq('l into the author, j, Enter - one sound', libs[#libs], '/x/7')
k('h'); k('G'); k('j'); eq('j past the last author loads the next page', searched[#searched].append, true)
k('gl'); k('v'); k('jj'); k('v'); M.key(13); eq('v marks inside the author', #libs, 6 + 3)
k('s'); eq('s - the sort menu', menu and #menu, 6)
menu[2].fn(); eq('sort set', FS.sort, 'downloads_desc')
M.search('kick'); k('h'); eq('h on the authors - the previous search', searched[#searched].q, 'amen')
print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
