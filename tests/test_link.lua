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

print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
