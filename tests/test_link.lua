-- test_link.lua — связь копий инструмента и beatsync в edit на стабах: lua tests/test_link.lua
-- Проверяет: метки jf_iid, уникальность изменённой копии, «применить ко всем»,
-- подгонку beatsync под темп в месте ноты и выключение beatsync.
package.path = './?.lua;' .. package.path
local BPM = 120
local function qn2t(qn) return qn * 60 / BPM end
local function t2qn(t) return t * BPM / 60 end
local tracks = { { items = {} } }
local guid_n = 0
local function item(pos, len, offs, rate, ext)
  local tk = { offs = offs or 0, rate = rate or 1, pp = 0, pm = -1 }
  local it = { pos = pos, len = len, take = tk, ext = ext or {} }
  table.insert(tracks[1].items, it)
  return it
end
_G.reaper = {
  genGuid = function() guid_n = guid_n + 1; return ('{%08X-0000-0000-0000-000000000000}'):format(guid_n) end,
  GetSetMediaItemInfo_String = function(it, k, v, set) if set then it.ext[k] = v; return true, v end return true, it.ext[k] or '' end,
  CountTracks = function() return #tracks end,
  GetTrack = function(_, i) return tracks[i + 1] end,
  CountTrackMediaItems = function(tr) return #tr.items end,
  GetTrackMediaItem = function(tr, i) return tr.items[i + 1] end,
  GetActiveTake = function(it) return it.take end,
  ValidatePtr = function() return true end,
  GetMediaItemInfo_Value = function(it, k) if k == 'D_POSITION' then return it.pos elseif k == 'D_LENGTH' then return it.len end return 0 end,
  SetMediaItemInfo_Value = function(it, k, v) if k == 'D_POSITION' then it.pos = v elseif k == 'D_LENGTH' then it.len = v end end,
  GetMediaItemTakeInfo_Value = function(tk, k)
    if k == 'D_STARTOFFS' then return tk.offs elseif k == 'D_PLAYRATE' then return tk.rate elseif k == 'B_PPITCH' then return tk.pp elseif k == 'I_PITCHMODE' then return tk.pm end
    return 0
  end,
  SetMediaItemTakeInfo_Value = function(tk, k, v)
    if k == 'D_STARTOFFS' then tk.offs = v elseif k == 'D_PLAYRATE' then tk.rate = v elseif k == 'B_PPITCH' then tk.pp = v elseif k == 'I_PITCHMODE' then tk.pm = v end
  end,
  TimeMap2_timeToQN = function(_, t) if t >= 8 then return t2qn(8) + (t - 8) * 4 end return t2qn(t) end,   -- после 8 с темп 240 (4 доли в секунду)
  TimeMap2_QNToTime = function(_, qn) local q8 = t2qn(8); if qn >= q8 then return 8 + (qn - q8) / 4 end return qn2t(qn) end,
  Undo_BeginBlock2 = function() end, Undo_EndBlock2 = function() end,
  PreventUIRefresh = function() end, UpdateArrange = function() end, UpdateItemInProject = function() end,
  time_precise = function() return os.clock() end,
  GetTakeNumStretchMarkers = function(tk) return #(tk.sm or {}) end,
  GetTakeStretchMarker = function(tk, i) local m = tk.sm[i + 1]; return i, m.pos, m.src end,
  DeleteTakeStretchMarkers = function(tk) tk.sm = {} end,
  PCM_Source_CreateFromFile = function(path) return { file = path } end,
  GetMediaItemTake_Source = function(tk) return tk.src end,
  SetMediaItemTake_Source = function(tk, src) tk.src = src end,
  GetMediaSourceFileName = function(src) return src and src.file or '' end,
  Main_OnCommand = function() end,
  TakeIsMIDI = function() return false end,
  GetItemStateChunk = function(it) return true, it.chunk or ('<ITEM\nPOSITION ' .. it.pos .. '\n>') end,
  AddMediaItemToTrack = function(tr) local it = { pos = 0, len = 1, take = { offs = 0, rate = 1, pp = 0, pm = -1 }, ext = {} }; table.insert(tr.items, it); return it end,
  SetItemStateChunk = function(it, ch) it.chunk = ch; return true end,
  DeleteTrackMediaItem = function(tr, it) for i, x in ipairs(tr.items) do if x == it then table.remove(tr.items, i); break end end end,
  GetMediaTrackInfo_Value = function() return 0 end,
  RecursiveCreateDirectory = function(d) os.execute("mkdir -p '" .. d .. "'") end,
  GetResourcePath = function() return os.getenv('TMPDIR') or '/tmp' end,
  GetSetMediaTrackInfo_String = function(tr, k, v, set) tr.ext = tr.ext or {}; if set then tr.ext[k] = v end; return true, tr.ext[k] or '' end,
}
local E = dofile('jf_tracker_edit.lua')
E.init({ invalidate = function() end })
E.keep_samples = false
local n, bad = 0, 0
local function eq(name, got, want)
  n = n + 1
  if got ~= want then bad = bad + 1; print(('FAIL %s: got %s, want %s'):format(name, tostring(got), tostring(want))) end
end
local function near(name, got, want) eq(name, math.abs((got or 1e9) - want) < 1e-6, true) end

-- метки и уникальность
local inst = item(100, 2, 0, 1)
local v = E.ensure_iid(inst)
eq('iid assigned', v ~= '', true)
eq('iid stable', E.ensure_iid(inst), v)
local a = item(0, 1, 0, 1, { ['P_EXT:jf_iid'] = v })
local b = item(1, 0.5, 0, 1, { ['P_EXT:jf_iid'] = v })
eq('linked copies found', #E.items_with_iid(v), 3)
-- одиночная копия без связанных — не уникализируется
local lone = item(50, 1, 0, 1, { ['P_EXT:jf_iid'] = 'solo' })
E.note_modified(lone)
eq('lone: no question', #E.modified, 0)
eq('lone keeps its mark', E.get_iid(lone), 'solo')
-- растянули a: стала уникальной, вопрос в очереди
a.take.rate = 0.5; a.len = 2
E.note_modified(a)
eq('modified queued', #E.modified, 1)
eq('modified copy unique', E.get_iid(a) ~= v and E.get_iid(a):sub(1, #v) == v, true)
eq('others still linked', #E.items_with_iid(v), 2)
E.note_modified(a)
eq('no double queue', #E.modified, 1)
-- «применить ко всем»: rate как у a, длины по отношению, метка снова общая
local mods = E.take_modified()
eq('queue taken', #E.modified, 0)
local cnt = E.propagate(mods)
eq('propagated to linked', cnt, 2)
near('inst rate', inst.take.rate, 0.5); near('inst length doubled', inst.len, 4)
near('b length doubled (keeps its cut)', b.len, 1)
eq('a relinked', E.get_iid(a), v)
eq('all linked again', #E.items_with_iid(v), 3)

-- beatsync: 2 с источника = 4 доли при 120; нота за 8 с (темп 240) — короче
local s = item(200, 2, 0, 1)
local c1 = item(0, 2, 0, 1)
local c2 = item(9, 1, 0, 1)                -- обрезанная копия в зоне 240 BPM
eq('guess 4 beats', E.bsync_guess(2, 0), 4)
E.bsync_set({ s, c1, c2 }, s, 4)
near('120 bpm: 4 beats = 2 s, rate 1', c1.take.rate, 1); near('120 bpm length', c1.len, 2)
near('240 bpm: rate 2', c2.take.rate, 2); near('240 bpm: cut copy keeps its share', c2.len, 0.5)
eq('keep pitch on stretch', c2.take.pp, 1)
local bs = E.bsync_of(c2)
eq('mark stored', bs and bs.n, 4)
-- новая копия на месте с 240 BPM подгоняется
local c3 = item(10, 2, 0, 1, { ['P_EXT:jf_bsync'] = s.ext['P_EXT:jf_bsync'] })
E.bsync_fit(c3)
near('fit at insert', c3.take.rate, 2); near('fit length', c3.len, 1)
-- выключение: исходный rate, длина назад, метка снята
E.bsync_set({ s, c1, c2 }, s, nil)
near('off: rate back', c2.take.rate, 1); near('off: length back', c2.len, 1)
eq('off: mark removed', E.bsync_of(c2), nil)
eq('off: keep pitch restored', c2.take.pp, 0)

-- слайс корня с stretch-маркерами (3 окт): копия — свой кусок источника
-- маркеры: позиция item → позиция в источнике (в долях при rate), как у REAPER
local rt = item(300, 2, 0, 1.5)
rt.take.sm = { { pos = 0, src = 0 }, { pos = 1, src = 0.8 }, { pos = 2, src = 2 } }
local pts = E.root_markers(rt.take)
eq('root markers read', pts and #pts, 3)
local cp = item(0, 2, 0, 1.5)
cp.take.sm = { { pos = 0, src = 0 }, { pos = 1, src = 0.8 }, { pos = 2, src = 2 } }   -- скопированы от корня
eq('unwarp ok', E.unwarp_piece(cp, pts, 1.5, 1, 2), true)
eq('copy markers removed', #cp.take.sm, 0)
near('offset = map(1) * rate', cp.take.offs, 0.8 * 1.5)
near('rate fits 1.2 src units in 1 s', cp.take.rate, (2 - 0.8) * 1.5 / 1)
near('length b - a', cp.len, 1)
eq('pitch kept', cp.take.pp, 1)
local cp2 = item(0, 1, 0, 1.5)
E.unwarp_piece(cp2, pts, 1.5, 0.5, 1)
near('mid-segment offset', cp2.take.offs, 0.4 * 1.5)
-- порядок lib (3 окт): метка jf_ord на исходнике и всех его копиях
local o1 = item(500, 1, 0, 1, { ['P_EXT:jf_iid'] = 'ORD1' })
local o1c = item(501, 0.5, 0, 1, { ['P_EXT:jf_iid'] = 'ORD1' })
local o2 = item(502, 1, 0, 1, { ['P_EXT:jf_iid'] = 'ORD2' })
E.lib_order({ o2, o1 })
eq('first gets 1', o2.ext['P_EXT:jf_ord'], '1')
eq('second gets 2', o1.ext['P_EXT:jf_ord'], '2')
eq('copies follow', o1c.ext['P_EXT:jf_ord'], '2')
-- swap (3 окт): файл у исходника и всех его нот, слайсы тоже; повтор — назад
local sw1 = item(600, 2, 0, 1, { ['P_EXT:jf_iid'] = 'SW' }); sw1.take.src = { file = '/a/amen.wav' }
local sw2 = item(602, 0.5, 0.5, 1, { ['P_EXT:jf_iid'] = 'SW#3' }); sw2.take.src = { file = '/a/amen.wav' }
local other = item(604, 1, 0, 1, { ['P_EXT:jf_iid'] = 'SWX' }); other.take.src = { file = '/a/other.wav' }
eq('swap count', E.swap_source(sw1, '/b/think.wav'), 2)
eq('root swapped', sw1.take.src.file, '/b/think.wav')
eq('slice swapped, offset kept', sw2.take.src.file .. '@' .. sw2.take.offs, '/b/think.wav@0.5')
eq('other untouched', other.take.src.file, '/a/other.wav')
eq('swapped remembers', E.swapped(sw1), '/a/amen.wav')
E.swap_source(sw1, '/c/funky.wav')
eq('second swap keeps the original to return to', E.swapped(sw1), '/a/amen.wav')
eq('swap back', E.swap_source(sw1, nil), 2)
eq('back to original', sw2.take.src.file, '/a/amen.wav')
eq('mark cleared', E.swapped(sw1), nil)
-- порядок арпеджио (3 окт)
local function seq(t) return table.concat(t, ' ') end
eq('arp up', seq(E.arp_order({ 64, 60, 67 }, 'up', 1)), '60 64 67')
eq('arp down 2 oct', seq(E.arp_order({ 64, 60, 67 }, 'down', 2)), '79 76 72 67 64 60')
eq('arp updown', seq(E.arp_order({ 60, 64, 67 }, 'updown', 1)), '60 64 67 64')
eq('arp played keeps order', seq(E.arp_order({ 67, 60, 64 }, 'played', 1)), '67 60 64')
local r = E.arp_order({ 60, 64, 67 }, 'random', 1, 42)
table.sort(r); eq('arp random is a permutation', seq(r), '60 64 67')
-- легато (3 окт): нота до начала следующей, скорость — под новую длину
tracks[1].items = {}
local l1 = item(10, 0.25, 0, 1.5)              -- кусок 0.375 с источника
local l2 = item(11, 0.25, 1, 1.5)
local l3 = item(11.5, 0.25, 2, 1.5)
E.legato(tracks[1], nil)
near('legato: l1 to l2', l1.len, 1); near('l1 rate keeps the piece', l1.take.rate, 1.5 * 0.25 / 1)
eq('l1 pitch kept', l1.take.pp, 1)
near('l2 to l3', l2.len, 0.5); near('last note natural', l3.len, 0.25)
E.legato(tracks[1], nil)
near('repeat does not compound', l1.take.rate, 1.5 * 0.25 / 1)
E.legato(tracks[1], nil, nil, nil, true)
near('off: length back', l1.len, 0.25); near('off: rate back', l1.take.rate, 1.5); eq('off: pitch flag back', l1.take.pp, 0)
E.legato_auto(tracks[1], true); eq('auto flag', E.legato_auto(tracks[1]), true)
E.legato_auto(tracks[1], false); eq('auto off', E.legato_auto(tracks[1]), false)
-- наборы lib (4 окт): шаблон трека с item, разбор блоков <ITEM>
local k1 = item(0, 2, 0, 1); k1.chunk = '<ITEM\nPOSITION 5\nLENGTH 2\nIGUID {AAA}\n<SOURCE WAVE\nFILE "/a/amen (v2).wav"\n>\n<EXT\njf_iid X\n>\n>\n'
local k2 = item(0, 1, 0, 1); k2.chunk = '<ITEM\nPOSITION 9\nLENGTH 1\n<SOURCE WAVE\nFILE "/a/b.wav"\n>\n>\n'
local kpath, kn = E.kit_save({ k1, k2 }, 'test kit')
eq('kit saved', kpath ~= nil and kn, 2)
local kf = io.open(kpath); local ktxt = kf:read('*a'); kf:close()
eq('track template', ktxt:match('^<TRACK') ~= nil, true)
local blocks = E.kit_items(ktxt)
eq('two items parsed', #blocks, 2)
eq('nested source kept', blocks[1]:find('amen (v2).wav', 1, true) ~= nil and blocks[1]:find('jf_iid X', 1, true) ~= nil, true)
eq('positions packed from 0', blocks[1]:match('POSITION ([%d%.]+)'), '0.0000000000')
eq('second after the first + 1 s', tonumber(blocks[2]:match('POSITION ([%d%.]+)')), 3)
eq('guids stripped', blocks[1]:find('IGUID', 1, true), nil)
os.remove(kpath)
-- повтор паттерна над курсором (4 окт, Paketti): строки [0, 4) → с 4 до 16
tracks[1].items = {}
local p1 = item(qn2t(0 / 4), qn2t(1 / 4), 0, 1)     -- строка 0, длина 1 строка (LPB 4, 120 BPM)
local p2 = item(qn2t(2 / 4), qn2t(1 / 4), 0, 1)     -- строка 2
local old = item(qn2t(9 / 4), qn2t(1 / 4), 0, 1)    -- строка 9 — заменится
local made = E.repeat_above(tracks[1], 4, 0, 4, 16)
eq('repeat: 2 items x 3 repeats', made, 6)
eq('old content below the cursor removed', (function() for _, x in ipairs(tracks[1].items) do if x == old then return false end end return true end)(), true)
local rows = {}
for _, x in ipairs(tracks[1].items) do rows[#rows + 1] = math.floor(t2qn(x.pos) * 4 + 0.5) end
table.sort(rows)
eq('rows of the repeats', table.concat(rows, ','), '0,2,4,6,8,10,12,14')
-- скрэмбл (4 окт): слайсы перемешаны между нотами, места и длины не растут
do
  local root = item(300, 4, 0, 1, { ['P_EXT:jf_iid'] = 'SCR', ['P_EXT:jf_slices'] = '0,1,2,3', ['P_EXT:jf_slice_base'] = '0;4' })
  local function sl(pos, len, k) return item(pos, len, k - 1, 1, { ['P_EXT:jf_iid'] = 'SCR#' .. k, ['P_EXT:jf_slice'] = tostring(k) }) end
  local s1, s2, s3 = sl(0, 1, 1), sl(1, 1, 2), sl(2, 0.5, 3)
  local hs = {}
  for _, it in ipairs({ s1, s2, s3 }) do hs[#hs + 1] = { kind = 'audio', item = it, take = it.take } end
  local changed = E.scramble(hs, 4, function() return 1 end)     -- [1,2,3] -> [2,3,1]
  eq('scramble: 3 notes changed', changed, 3)
  eq('scramble: s1 -> slice 2', s1.ext['P_EXT:jf_slice'], '2')
  eq('scramble: s2 -> slice 3', s2.ext['P_EXT:jf_slice'], '3')
  eq('scramble: s3 -> slice 1', s3.ext['P_EXT:jf_slice'], '1')
  near('scramble: s1 plays from slice 2', s1.take.offs, 1)
  near('scramble: positions stay', s2.pos, 1)
  near('scramble: s3 not longer than before', s3.len, 0.5)
  eq('scramble: root untouched', root.ext['P_EXT:jf_slice'], nil)
  local a1, b1 = { kind = 'audio', item = s1 }, { kind = 'audio', item = s3 }
  eq('swap_events', E.swap_events(a1, b1), true)
  near('swap: s1 at s3 place', s1.pos, 2)
  near('swap: s3 at s1 place', s3.pos, 0)
  eq('swap: midi refused', E.swap_events({ kind = 'midi', item = s1 }, b1), false)
end
print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
