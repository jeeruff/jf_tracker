-- test_freesound_module.lua (2 ноя) — клавиши модуля freesound на заглушках: отметки lf, v, счётчик, догрузка, история
package.path = './?.lua;' .. package.path
_G.reaper = { GetExtState = function() return 'k' end, GetResourcePath = function() return '/tmp/nonexist' end, time_precise = os.clock,
  RecursiveCreateDirectory = function() end, ExecProcess = function() end }
_G.gfx = {}
local M = dofile('modules/freesound.lua')
local libs, msgs, menu = {}, {}, nil
M.init({ R = reaper, dir = '.', TX = dofile('jf_tracker_utf8.lua'), msg = function(s) msgs[#msgs + 1] = s end,
  preview_file = function() end, add_to_depot = function(p) libs[#libs + 1] = p end, menu = function(t, it) menu = it end })
local FS = M.FS
local n, bad = 0, 0
local function eq(name, got, want) n = n + 1; if got ~= want then bad = bad + 1; print(('FAIL %s: got %s, want %s'):format(name, tostring(got), tostring(want))) end end
local searched = {}
FS.search = function(q, page, append) searched[#searched + 1] = { q = q, page = page, append = append }; FS.query = q; FS.page = page or 1; return true end
FS.fetch = function(h, fn) fn('/x/' .. h.id) end
FS.results, FS.count, FS.query = {}, 120, 'amen'
for i = 1, 50 do FS.results[i] = { id = i, name = 'n' .. i, user = 'u', lic = 'CC0' } end
local function k(s) for ch in s:gmatch('.') do M.key(ch:byte()) end end
M.search('amen'); FS.results = FS.results   -- S.q = amen
k('m'); k('m'); eq('m marks and steps', #searched, 1)
k('3j')
k('v'); k('jj'); k('v')
M.key(13)
eq('Enter on marked: 2 + 3 into the lib', #libs, 5)
eq('order kept: first marked first', libs[1], '/x/1')
k('G'); M.key(('j'):byte())
eq('j past the end loads the next page appended', searched[#searched].append, true)
eq('page 2', searched[#searched].page, 2)
k('s'); eq('s opens the sort menu', menu and #menu, 6)
menu[2].fn(); eq('sort set', FS.sort, 'downloads_desc')
M.search('kick'); k('h'); eq('h - back to the previous search', searched[#searched].q, 'amen')
print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
