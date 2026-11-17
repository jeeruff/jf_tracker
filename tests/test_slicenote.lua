-- test_slicenote.lua — нота = слайс (17 ноя) на НАСТОЯЩЕМ jf_tracker_edit.lua с имитацией REAPER (харнесс test_cutpaste):
-- высота слайса — свойство слайса (slp_set: все его ноты), своя высота на месте сохраняется, 0Sxx — старт внутри
-- слайса, транспоз / set_pitch ведут к соседнему слайсу.
-- Запуск: lua tests/test_slicenote.lua
local DIR = (arg and arg[0] or ''):match('(.*)/tests/') or '.'
local fails, checks = 0, 0
local function ok(name, cond, info)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL ' .. name .. (info and (' (' .. tostring(info) .. ')') or '')) end
end
local function near(a, b) return a and b and math.abs(a - b) < 1e-6 end

-- ── имитация REAPER: 120 BPM (QN = 0.5 с), треки и айтемы — таблицы ─────────
local BPM = 120
local proj = { tracks = {}, ext = {} }
local chunks, nchunk = {}, 0
local function copy(t) if type(t) ~= 'table' then return t end; local o = {}; for k, v in pairs(t) do o[k] = copy(v) end; return o end
local function new_track(name) local tr = { kind = 'track', name = name, items = {}, v = {}, s = {} }; proj.tracks[#proj.tracks + 1] = tr; return tr end
local function new_item(tr, pos, len, midi)
  local it = { kind = 'item', track = tr, v = { D_POSITION = pos, D_LENGTH = len, I_FIXEDLANE = 0, B_MUTE = 0, D_VOL = 1, B_LOOPSRC = 0 }, s = {},
               take = { kind = 'take', midi = midi or false, v = { D_PITCH = 0, D_PLAYRATE = 1, D_STARTOFFS = 0, B_PPITCH = 0, D_VOL = 1 }, s = {}, notes = {} } }
  it.take.item = it
  tr.items[#tr.items + 1] = it
  return it
end
local unknown = {}
local R = setmetatable({}, { __index = function(_, k)
  return function(...) unknown[k] = (unknown[k] or 0) + 1; return nil end   -- неизвестный вызов — nil, имя в отчёт
end })
reaper = R
R.ValidatePtr = function(p, kind)
  if type(p) ~= 'table' then return false end
  if kind == 'MediaItem*' then for _, x in ipairs(p.track and p.track.items or {}) do if x == p then return true end end; return false end
  return true
end
R.CountTracks = function() return #proj.tracks end
R.GetTrack = function(_, i) return proj.tracks[i + 1] end
R.CountTrackMediaItems = function(tr) return #tr.items end
R.GetTrackMediaItem = function(tr, i) return tr.items[i + 1] end
R.GetMediaItem_Track = function(it) return it.track end
R.GetMediaItemTrack = R.GetMediaItem_Track
R.GetActiveTake = function(it) return it.take end
R.GetMediaItemTake = function(it) return it.take end
R.GetMediaItemTake_Item = function(tk) return tk.item end
R.CountTakes = function() return 1 end
R.TakeIsMIDI = function(tk) return tk.midi end
R.GetMediaItemInfo_Value = function(it, k) return it.v[k] or 0 end
R.SetMediaItemInfo_Value = function(it, k, v) it.v[k] = v; return true end
R.GetMediaItemTakeInfo_Value = function(tk, k) return tk.v[k] or 0 end
R.SetMediaItemTakeInfo_Value = function(tk, k, v) tk.v[k] = v; return true end
R.GetMediaTrackInfo_Value = function(tr, k) return tr.v[k] or 0 end
R.SetMediaTrackInfo_Value = function(tr, k, v) tr.v[k] = v; return true end
local function gs(o) return function(x, k, v, set) if set then x.s[k] = v; return true, v end; return (x.s[k] ~= nil), x.s[k] or '' end end
R.GetSetMediaItemInfo_String = gs()
R.GetSetMediaTrackInfo_String = gs()
R.GetSetMediaItemTakeInfo_String = gs()
R.GetTrackName = function(tr) return true, tr.name end
R.AddMediaItemToTrack = function(tr) return new_item(tr, 0, 0) end
R.DeleteTrackMediaItem = function(tr, it) for i, x in ipairs(tr.items) do if x == it then table.remove(tr.items, i); return true end end; return false end
R.GetItemStateChunk = function(it) nchunk = nchunk + 1; local id = '<ITEM\nCHUNK ' .. nchunk .. '\n>'; chunks[id] = { v = copy(it.v), s = copy(it.s), take = { midi = it.take.midi, v = copy(it.take.v), s = copy(it.take.s), notes = copy(it.take.notes) } }; return true, id end
R.SetItemStateChunk = function(it, ch)
  local c = chunks[ch]; if not c then return false end
  it.v, it.s = copy(c.v), copy(c.s)
  it.take = { kind = 'take', item = it, midi = c.take.midi, v = copy(c.take.v), s = copy(c.take.s), notes = copy(c.take.notes) }
  return true
end
R.TimeMap2_QNToTime = function(_, q) return q * 60 / BPM end
R.TimeMap2_timeToQN = function(_, t) return t * BPM / 60 end
R.TimeMap_GetDividedBpmAtTime = function() return BPM end
R.Master_GetTempo = function() return BPM end
R.MIDI_GetPPQPosFromProjTime = function(tk, t) return (t - tk.item.v.D_POSITION) * BPM / 60 * 960 end
R.MIDI_GetProjTimeFromPPQPos = function(tk, p) return tk.item.v.D_POSITION + p / 960 * 60 / BPM end
R.MIDI_CountEvts = function(tk) return true, #tk.notes, 0, 0 end
R.MIDI_GetNote = function(tk, i) local n = tk.notes[i + 1]; if not n then return false end; return true, n.sel, n.muted, n.sppq, n.eppq, n.ch, n.pitch, n.vel end
R.MIDI_InsertNote = function(tk, sel, muted, s, e, ch, pitch, vel) tk.notes[#tk.notes + 1] = { sel = sel, muted = muted, sppq = s, eppq = e, ch = ch, pitch = pitch, vel = vel }; return true end
R.MIDI_SetNote = function(tk, i, sel, muted, s, e, ch, pitch, vel) local n = tk.notes[i + 1]; if not n then return false end; n.sel, n.muted, n.sppq, n.eppq, n.ch, n.pitch, n.vel = sel, muted, s or n.sppq, e or n.eppq, ch or n.ch, pitch or n.pitch, vel or n.vel; return true end
R.MIDI_DeleteNote = function(tk, i) table.remove(tk.notes, i + 1); return true end
R.MIDI_Sort = function(tk) table.sort(tk.notes, function(a, b) return a.sppq < b.sppq end) end
R.CreateNewMIDIItemInProj = function(tr, t0, t1) return new_item(tr, t0, t1 - t0, true) end
R.GetProjExtState = function(_, sec, k) local v = proj.ext[sec .. '/' .. k]; return v and 1 or 0, v or '' end
R.SetProjExtState = function(_, sec, k, v) proj.ext[sec .. '/' .. k] = v end
R.GetExtState = function() return '' end
R.HasExtState = function() return false end
R.SetExtState = function() end
R.GetSetProjectGrid = function() return 0, 0.0625, 0, 0 end
for _, k in ipairs({ 'Undo_BeginBlock', 'Undo_BeginBlock2', 'Undo_EndBlock', 'Undo_EndBlock2', 'Undo_OnStateChange', 'Undo_OnStateChange2', 'UpdateArrange', 'UpdateTimeline',
                     'UpdateItemInProject', 'PreventUIRefresh', 'MarkProjectDirty', 'MarkTrackItemsDirty', 'ShowConsoleMsg' }) do R[k] = function() end end
R.time_precise = os.clock
R.GetPlayState = function() return 0 end
R.EnumProjects = function() return proj, '' end

local model = dofile(DIR .. '/jf_tracker_model.lua')
local E = dofile(DIR .. '/jf_tracker_edit.lua'); E.init(model)
local LPB = 4
local function rt(row) return E.row_time(row, LPB, 0) end
local function at(tr, row) for _, it in ipairs(tr.items) do if near(it.v.D_POSITION, rt(row)) then return it end end end

local function head(it, row) return { kind = 'audio', item = it, take = it.take, row0 = row or 0, rows = 1, fi = 1 } end
proj.tracks = {}
local A, B = new_track('A'), new_track('B')
-- корень: 1 с, четыре слайса по 0.25, транспоз корня +2
local root = new_item(A, 10, 1.0)
root.s['P_EXT:jf_slices'] = '0.000000,0.250000,0.500000,0.750000'
root.s['P_EXT:jf_slice_base'] = '0.000000;1.000000;1.000000'
root.s['P_EXT:jf_iid'] = 'R1'
root.take.v.D_PITCH = 2

local n1 = E.insert_slice(B, nil, LPB, 0, root, 2)
ok('insert: slice 2', n1 and n1.s['P_EXT:jf_slice'] == '2')
ok('insert: start of slice 2', n1 and near(n1.take.v.D_STARTOFFS, 0.25), n1 and n1.take.v.D_STARTOFFS)
ok('insert: pitch = root transpose', n1 and near(n1.take.v.D_PITCH, 2), n1 and n1.take.v.D_PITCH)
ok('insert: iid root#2', n1 and n1.s['P_EXT:jf_iid'] == 'R1#2')
ok('insert: the slice pitches stay on the root', n1 and (n1.s[E.SLP] or '') == '')

-- высота слайса 2 = +5: ноты слайса слышат её, новая нота — тоже
ok('slp_set: one note follows', E.slp_set(root, 2, 5) == 1)
ok('slp_set: stored on the root', E.slp_of(root, 2) == 5 and root.s[E.SLP] == '2:5', root.s[E.SLP])
ok('slp_set: note pitch 2 + 5', near(n1.take.v.D_PITCH, 7), n1.take.v.D_PITCH)
local n2 = E.insert_slice(B, nil, LPB, 8, root, 2)
ok('insert after slp_set: pitch 2 + 5', n2 and near(n2.take.v.D_PITCH, 7), n2 and n2.take.v.D_PITCH)
local n3 = E.insert_slice(B, nil, LPB, 16, root, 3)
ok('other slice: no slice pitch', n3 and near(n3.take.v.D_PITCH, 2), n3 and n3.take.v.D_PITCH)

-- своя высота на месте (Option + нота): сверх высоты слайса
E.run('t', function() E.slice_pitch(n1, 3) end)
ok('slice_pitch: root + slice + own', near(n1.take.v.D_PITCH, 10), n1.take.v.D_PITCH)
ok('slice_place: own +3', near(E.slice_place(n1), 3), E.slice_place(n1))

-- 0S80 — старт с половины слайса, слайс тот же; нота доигрывала слайс — доигрывает остаток
E.set_fx({ head(n1) }, LPB, '0S', 128)
ok('0S80: start in the middle of slice 2', near(n1.take.v.D_STARTOFFS, 0.375), n1.take.v.D_STARTOFFS)
ok('0S80: length - the rest of the slice', near(n1.v.D_LENGTH, 0.125), n1.v.D_LENGTH)
ok('0S80: still slice 2', n1.s['P_EXT:jf_slice'] == '2')
ok('0S80: offset tag', E.slofs(n1) == 128)
ok('0S80: pitch kept', near(n1.take.v.D_PITCH, 10), n1.take.v.D_PITCH)

-- транспоз +1 (F2) — соседний слайс: 0S и своя высота остаются, высота слайса — новая
E.transpose({ head(n1) }, LPB, 1)
ok('F2: slice 3', n1.s['P_EXT:jf_slice'] == '3')
ok('F2: offset kept inside slice 3', near(n1.take.v.D_STARTOFFS, 0.625), n1.take.v.D_STARTOFFS)
ok('F2: pitch = root + own (slice 3 has none)', near(n1.take.v.D_PITCH, 5), n1.take.v.D_PITCH)
ok('F2: iid root#3', n1.s['P_EXT:jf_iid'] == 'R1#3')
-- за краем нарезки — ничего, сообщение
E.skip_msg = nil
E.transpose({ head(n1) }, LPB, 5)
ok('transpose past the last slice: unchanged', n1.s['P_EXT:jf_slice'] == '3')
ok('transpose past the last slice: message', E.skip_msg ~= nil)
E.skip_msg = nil
-- обратно на слайс 2 — его высота снова слышна
E.transpose({ head(n1) }, LPB, -1)
ok('F1: back to slice 2, pitch root + slice + own', n1.s['P_EXT:jf_slice'] == '2' and near(n1.take.v.D_PITCH, 10), n1.take.v.D_PITCH)

-- нота выбирает слайс: set_pitch(нота слайса 1) — слайс 1
E.set_pitch({ head(n1) }, LPB, E.slice_note1())
ok('set_pitch: the note of slice 1 - slice 1', n1.s['P_EXT:jf_slice'] == '1')
ok('set_pitch: start of slice 1 + 0S80', near(n1.take.v.D_STARTOFFS, 0.125), n1.take.v.D_STARTOFFS)
E.set_slice({ head(n1) }, LPB, 4)
ok('set_slice 4', n1.s['P_EXT:jf_slice'] == '4' and near(n1.take.v.D_STARTOFFS, 0.875), n1.take.v.D_STARTOFFS)

-- 0S снят — снова с начала слайса
E.clear_fx({ head(n1) }, LPB, '0S')
ok('0S cleared: start of slice 4', near(n1.take.v.D_STARTOFFS, 0.75), n1.take.v.D_STARTOFFS)
ok('0S cleared: no tag', E.slofs(n1) == 0)

-- высота слайса обратно 0 — его ноты без неё
E.slp_set(root, 2, 0)
ok('slp_set 0: note of slice 2 back to the root transpose', near(n2.take.v.D_PITCH, 2), n2.take.v.D_PITCH)
ok('slp_set 0: tag empty', (root.s[E.SLP] or '') == '')

print(('%d checks, %d failed'):format(checks, fails))
if fails > 0 then os.exit(1) end
