-- test_pm.lua — jf_tracker_pm на стабах (без REAPER / gfx): lua tests/test_pm.lua
-- Декодер-корутина, записи / сортировка, раскладка сетки, курсор, приоритет
-- превью, навигатор, отложенная безопасная запись индекса.
package.path = './?.lua;' .. package.path
reaper = nil; gfx = nil
local PM = dofile('jf_tracker_pm.lua')
PM.init({}, {})
local n, bad = 0, 0
local function eq(name, got, want) n = n + 1; if got ~= want then bad = bad + 1; print(('FAIL %s: got %s want %s'):format(name, tostring(got), tostring(want))) end end
local function near(name, got, want) eq(name, math.abs((got or 1e9) - want) < 1e-6, true) end

-- ── декодер ───────────────────────────────────────────────────────────────
-- null в массиве пропадает (arr[#arr+1] = nil), как у jf_pm — в фикстуре он последний
local fx = '{"a": [1, 2.5, -3, true, false, "x\\ny", "\\u0416", null], "b": {"c": {}, "d": []}, "e": "q\\"w\\\\z", "updated": 42}'
local t = PM.decode(fx)
eq('decode array len (null drops)', #t.a, 7); eq('decode number', t.a[2], 2.5); eq('decode escape', t.a[6], 'x\ny'); eq('decode \\u', t.a[7], 'Ж')
eq('decode nested empty obj', next(t.b.c), nil); eq('decode nested empty arr', #t.b.d, 0); eq('decode quotes', t.e, 'q"w\\z'); eq('decode int', t.updated, 42)
-- корутина: уступает, доля растёт, результат тот же
do
  local co = coroutine.create(function() return PM.decode(fx, 3) end)
  local yields, last = 0, -1
  while true do
    local ok, r = coroutine.resume(co)
    eq('co resume ok', ok, true)
    if coroutine.status(co) == 'dead' then eq('co result same', r.e, 'q"w\\z'); break end
    yields = yields + 1; eq('co frac monotonic', r >= last, true); last = r
  end
  eq('co yielded', yields >= 2, true)
end
-- кодер: round trip
local back = PM.decode(PM.encode(t))
eq('encode round trip', back.a[6], 'x\ny'); eq('encode round trip int', back.updated, 42)

-- ── загрузка по кускам + запись (fs подменён) ─────────────────────────────
local disk, renames = {}, {}
local clock = 0
PM.fs = {
  read = function(p) return disk[p] end,
  write = function(p, s) disk[p] = s; return true end,
  rename = function(a, b) renames[#renames + 1] = a .. '>' .. b; if disk[a] == nil then return nil end; disk[b] = disk[a]; disk[a] = nil; return true end,
  exists = function(p) return disk[p] ~= nil end,
  tail = function(p, k) local s = disk[p]; return s and s:sub(-k) end,
  time = function() return clock end,
  now = function() return 1000 end,
}
PM.INDEX = '/idx.json'
disk['/idx.json'] = PM.encode({ version = 1, updated = 5, projects = {
  ['/p/one.rpp'] = { name = 'one [128]', mtime = 300, ext = { STATUS = 'доделать', TAGS = 'a, b' }, keys = { 'Am' }, tags_extra = { 'z' } },
  ['/p/two.rpp'] = { name = 'two', mtime = 200, tempo = 90, status_over = 'микс', pinned = true, items = { { t = 1, p = 0, l = 2 }, { t = 2, p = 1, l = 1 } }, duration = 4, track_count = 2, regions = { { name = 'intro', pos = 0, fin = 2 } } },
  ['/p/.hidden.rpp'] = { name = 'hidden', mtime = 999 },
  ['/d/song.als'] = { name = 'song', mtime = 250, daw = 'ableton', daw_ext = 'als' },
  ['/p/gone.rpp'] = { name = 'gone', mtime = 1, gone = true },
} })
local ready = 0
PM.on_ready = function() ready = ready + 1 end
PM.ensure()
eq('loading started', PM.loading ~= nil, true); eq('not ready yet', PM.ready, false)
PM.YIELD_EVERY = 5
PM.reload()
local steps = 0
while PM.loading do PM.load_step(1e9); steps = steps + 1 end
eq('ready', PM.ready, true); eq('on_ready called', ready >= 1, true); eq('updated read', PM.file_updated(), 5)

-- ── записи ────────────────────────────────────────────────────────────────
local es = PM.entries(PM.idx, { daw = 'all' })
eq('entries: hidden and gone skipped', #es, 3)
local by = {}; for _, e in ipairs(es) do by[e.path] = e end
eq('status from ext.STATUS via alias', by['/p/one.rpp'].status, 'аранжировка'); eq('status_en', by['/p/one.rpp'].st_en, 'arrangement')
eq('bpm from name', by['/p/one.rpp'].bpm, 128); eq('bpm from tempo', by['/p/two.rpp'].bpm, 90)
eq('tags merged sorted', by['/p/one.rpp'].tagstr, '#a #b #z'); eq('keys', by['/p/one.rpp'].keystr, 'Am')
eq('label searchable', by['/d/song.als'].label:find('ableton', 1, true) ~= nil, true)
eq('label has status', by['/p/two.rpp'].label:find('[микс]', 1, true) ~= nil, true)
eq('daw filter rpp', #PM.entries(PM.idx, { daw = 'rpp' }), 2); eq('daw filter other', #PM.entries(PM.idx, { daw = 'other' }), 1)
-- ── сортировка ────────────────────────────────────────────────────────────
local s = PM.sort(PM.entries(PM.idx, {}), 'date')
eq('sort date: pinned first', s[1].path, '/p/two.rpp'); eq('sort date: newest next', s[2].path, '/p/one.rpp')
s = PM.sort(PM.entries(PM.idx, {}), 'name'); eq('sort name: pinned first still', s[1].path, '/p/two.rpp'); eq('sort name: one before song', s[2].name < s[3].name, true)
s = PM.sort(PM.entries(PM.idx, {}), 'bpm'); eq('sort bpm: no bpm last', s[3].bpm, nil)
s = PM.sort(PM.entries(PM.idx, {}), 'status'); eq('sort status: no status last', s[3].status, '')

-- ── сетка и курсор ────────────────────────────────────────────────────────
for _, cw in ipairs({ 8, 12, 16 }) do
  for _, w in ipairs({ 20 * cw, 36 * cw, 1600 }) do
    local G = PM.grid(w, cw, 4, cw + 2, 'square')
    eq(('grid cols>=1 w%d cw%d'):format(w, cw), G.cols >= 1, true)
    eq(('grid fits w%d cw%d'):format(w, cw), G.cols * G.card_w + (G.cols + 1) * 4 <= w, true)
    eq(('grid thumb>0 w%d cw%d'):format(w, cw), G.thumb > 0, true)
  end
end
eq('square: narrow sidebar 2 cols', PM.grid(20 * 8, 8, 4, 10, 'square').cols, 2); eq('square: wide sidebar 3 cols', PM.grid(36 * 8, 8, 4, 10, 'square').cols, 3)
eq('square: big 10 cols', PM.grid(1600, 16, 4, 18, 'square').cols, 10)
-- wide (по умолчанию): высота три строки, превью квадрат слева, ширина >= превью + 9 символов
local Gw = PM.grid(36 * 8, 8, 4, 10)
eq('wide default shape', Gw.shape, 'wide'); eq('wide height 4 rows', Gw.card_h, 4 * 10 + 12); eq('wide thumb inside the frame (card_h - 3 pad - 1)', Gw.thumb, Gw.card_h - 13)
eq('wide sidebar 2 cols at 36cw', Gw.cols, 2); eq('wide narrow sidebar 1 col', PM.grid(20 * 8, 8, 4, 10).cols, 1); eq('wide 1600: many cols', PM.grid(1600, 8, 4, 10).cols >= 8, true)
local Gc = PM.grid(36 * 8, 8, 4, 10, 'compact'); eq('compact 3 rows', Gc.card_h, 3 * 10 + 12); eq('compact side text', Gc.side, true)
eq('shape cycle', PM.next_shape('wide') .. PM.next_shape('compact') .. PM.next_shape('square'), 'compactsquarewide')
eq('wide no thumb: narrower cards', PM.grid(36 * 8, 8, 4, 10, 'wide', false).cols >= Gw.cols, true); eq('wide no thumb: thumb 0', PM.grid(36 * 8, 8, 4, 10, 'wide', false).thumb, 0)
eq('move l', PM.move(1, 10, 3, 'l'), 2); eq('move h clamp', PM.move(1, 10, 3, 'h'), 1); eq('move j', PM.move(1, 10, 3, 'j'), 4)
eq('move j past end stays', PM.move(9, 10, 3, 'j'), 9); eq('move k top stays', PM.move(2, 10, 3, 'k'), 2); eq('move l clamp', PM.move(10, 10, 3, 'l'), 10)
eq('move cols 1', PM.move(3, 10, 1, 'j'), 4); eq('move empty', PM.move(1, 0, 3, 'l'), 1)

-- ── превью: приоритет и навигатор ─────────────────────────────────────────
local c = { thumb_file = '/t.png', daw = 'ableton' }
eq('kind: missing image falls to daw', PM.thumb_kind(c, '/a.wav'), 'daw')
disk['/t.png'] = 'x'; PM.invalidate()
eq('kind: image first', PM.thumb_kind(c, '/a.wav'), 'image')
eq('kind: wave when audio', PM.thumb_kind({ path = '/x' }, '/a.wav'), 'wave'); eq('kind: nav otherwise', PM.thumb_kind({ path = '/x' }, nil), 'nav')
do
  local two = PM.idx.projects['/p/two.rpp']; two.path = '/p/two.rpp'
  local rects = 0
  local cnt = PM.paint_nav(two, 40, function(x, y, w, h) rects = rects + 1; eq('nav inside x', x >= 0 and x + w <= 40, true); eq('nav inside y', y >= 0 and y + h <= 40, true) end)
  eq('nav rect count = items + regions', cnt, 3); eq('nav rects drawn', rects, 3)
end
-- find_audio: кандидаты по порядку
disk['/p/two.rpp-PROX.wav'] = 'x'
eq('find_audio proxy', PM.find_audio(PM.idx.projects['/p/two.rpp']), '/p/two.rpp-PROX.wav')

-- ── правка и отложенная запись ────────────────────────────────────────────
eq('edit ok', PM.edit('/p/one.rpp', function(cd) cd.pinned = true end), true); eq('edit missing', PM.edit('/nope', function() end), false)
eq('dirty set', PM.dirty ~= nil, true)
clock = 1.0; eq('flush too early', PM.flush(false), false)
clock = 2.0; eq('flush after delay', PM.flush(false), true)
eq('flush wrote index', disk['/idx.json'] ~= nil, true); eq('flush kept .bak', disk['/idx.json.bak'] ~= nil, true)
eq('flush renamed via tmp', renames[#renames], '/idx.json.tmp>/idx.json')
eq('flush bumped updated', PM.file_updated(), 1000); eq('ops cleared', #PM.ops, 0); eq('dirty cleared', PM.dirty, nil)
eq('pinned persisted', PM.decode(disk['/idx.json']).projects['/p/one.rpp'].pinned, true)
-- чужая запись индекса: flush перезагружает и переприменяет правку
disk['/idx.json'] = disk['/idx.json']:gsub('"updated": 1000', '"updated": 2000')
PM.edit('/p/two.rpp', function(cd) cd.tags_extra = { 'fresh' } end)
clock = 10; eq('stale: flush defers', PM.flush(true), false); eq('stale: reload started', PM.loading ~= nil, true)
while PM.loading do PM.load_step(1e9) end
eq('stale: op re-applied', PM.idx.projects['/p/two.rpp'].tags_extra[1], 'fresh'); eq('stale: updated now 2000', PM.idx.updated, 2000)
eq('stale: second flush writes', PM.flush(true), true)

print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
