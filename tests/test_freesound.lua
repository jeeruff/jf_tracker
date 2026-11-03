-- test_freesound.lua (2 ноя) — разбор ответа freesound и сборка запроса, без сети
package.path = './?.lua;' .. package.path
_G.reaper = { GetExtState = function() return '' end, GetResourcePath = function() return '/tmp' end }
local FS = dofile('jf_tracker_freesound.lua')
local n, bad = 0, 0
local function eq(name, got, want) n = n + 1; if got ~= want then bad = bad + 1; print(('FAIL %s: got %s, want %s'):format(name, tostring(got), tostring(want))) end end
local j = FS.json('{"a": [1, 2.5, -3e2, true, false, null], "s": "x\\"y\\u00e9\\n", "o": {}}')
eq('array', #j.a, 5); eq('float', j.a[2], 2.5); eq('exp', j.a[3], -300); eq('bool', j.a[4], true)
eq('string escapes', j.s, 'x"yé\n'); eq('empty object', type(j.o), 'table')
local txt = [[{"count": 2, "next": null, "results": [
 {"id": 626105, "name": "8bit amen break.mp3", "username": "D0tDashDialUp", "license": "http://creativecommons.org/publicdomain/zero/1.0/",
  "duration": 8.676, "previews": {"preview-hq-mp3": "https://cdn.freesound.org/previews/626/626105_13140709-hq.mp3"}, "tags": ["amen", "8bit"], "url": "https://freesound.org/people/D0tDashDialUp/sounds/626105/"},
 {"id": 1, "name": "kick", "username": "u", "license": "https://creativecommons.org/licenses/by/4.0/", "duration": 0.5, "previews": {}, "tags": []}]}]]
local res, err, cnt = FS.parse(txt)
eq('parsed', err, nil); eq('2 hits', #res, 2); eq('count', cnt, 2)
eq('cc0', res[1].lic, 'CC0'); eq('by', res[2].lic, 'CC BY'); eq('mp3', res[1].mp3:sub(-6), 'hq.mp3'); eq('no preview', res[2].mp3, nil)
eq('len', res[1].len, 8.676)
local r2, e2 = FS.parse('{"detail": "Invalid token"}')
eq('api error', e2, 'freesound: Invalid token'); eq('api error nil', r2, nil)
local _, e3 = FS.parse('<html>')
eq('garbage', e3, 'freesound: bad answer')
local u = FS.build_url('amen break <10s cc0', 'K Y')
eq('query', u:match('query=([^&]*)'), 'amen%20break')
eq('filter', u:match('filter=([^&]*)'), FS.urlenc('license:"Creative Commons 0" duration:[0 TO 10]'))
eq('token', u:match('token=([^&]*)$'), 'K%20Y')
eq('file name - author folder', FS.file_of({ id = 7, name = 'a/b: c.wav', user = 'Ragnar59' }), '/tmp/Data/jf_tracker_freesound/Ragnar59/7 a_b_ c.mp3')
print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
