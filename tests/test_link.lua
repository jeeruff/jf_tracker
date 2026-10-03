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
print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
