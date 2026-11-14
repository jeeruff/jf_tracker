-- test_cutpaste.lua — вырезать / вставить на НАСТОЯЩЕМ jf_tracker_edit.lua с имитацией REAPER (14 ноя):
-- аудио-айтем и MIDI-нота после x / p на другом треке — те же длина, смещение, скорость, высота.
-- Запуск: lua tests/test_cutpaste.lua
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

-- ── 1. аудио: x на треке A, p на треке B (другие строки) ────────────────────
local function audio_case(name, prep)
  proj.tracks = {}
  local A, B = new_track('A'), new_track('B')
  local src = new_item(A, rt(8), 0.333)
  src.take.v.D_PITCH, src.take.v.D_PLAYRATE, src.take.v.D_STARTOFFS = -12, 1.25, 0.1
  src.s['P_EXT:jf_iid'] = 'x1'
  local src2 = new_item(A, rt(23), 0.9)
  if prep then prep(A, B) end
  local heads = { { kind = 'audio', item = src, row0 = 8, rows = 2, fi = 1, name = 's' }, { kind = 'audio', item = src2, row0 = 23, rows = 8, fi = 1, name = 's2' } }
  local reg = E.yank(heads, LPB, 8, 1)
  E.delete(heads, LPB)
  ok(name .. ': cut removes both', #A.items == 0, #A.items)
  E.paste(reg, LPB, 40, function() return { track = B, lane_idx = nil } end)
  local p1, p2 = at(B, 40), at(B, 55)
  ok(name .. ': first pasted at its row', p1 ~= nil)
  ok(name .. ': second keeps its distance (15 rows)', p2 ~= nil)
  if p1 then
    ok(name .. ': length kept', near(p1.v.D_LENGTH, 0.333), p1.v.D_LENGTH)
    ok(name .. ': pitch kept', near(p1.take.v.D_PITCH, -12), p1.take.v.D_PITCH)
    ok(name .. ': rate kept', near(p1.take.v.D_PLAYRATE, 1.25), p1.take.v.D_PLAYRATE)
    ok(name .. ': start offset kept', near(p1.take.v.D_STARTOFFS, 0.1), p1.take.v.D_STARTOFFS)
  end
  if p2 then ok(name .. ': long item length kept', near(p2.v.D_LENGTH, 0.9), p2.v.D_LENGTH) end
  return A, B, reg
end
audio_case('audio')
-- залипший ограничитель ввода (E.cap_row остался от вставки ноты) — вставка из регистра не должна обрезаться им
audio_case('audio, stale cap_row', function() E.cap_row, E.cap_lpb = 41, LPB end)
E.cap_row, E.cap_lpb = nil, nil
-- трек назначения занят: айтем начинается в строке вставки и ещё один звучит через неё
audio_case('audio, busy target', function(_, B) new_item(B, rt(40), 2.0); new_item(B, rt(36), 3.0) end)

-- ── 2. MIDI: нота из клипа трека M вырезана и вставлена в клип трека N ──────
do
  proj.tracks = {}
  local M, N = new_track('M'), new_track('N')
  local mc = new_item(M, rt(0), rt(64), true)
  local nc = new_item(N, rt(0), rt(64), true)
  local s, e = R.MIDI_GetPPQPosFromProjTime(mc.take, rt(8)), R.MIDI_GetPPQPosFromProjTime(mc.take, rt(11))
  R.MIDI_InsertNote(mc.take, false, false, s, e, 3, 67, 90)
  local heads = { { kind = 'midi', item = mc, take = mc.take, row0 = 8, rows = 3, fi = 1, pitch = 67, ch = 3, sppq = s, idx = 0 } }
  local reg = E.yank(heads, LPB, 8, 1)
  ok('midi: note in the register', #reg.cells == 1, #reg.cells)
  E.delete(heads, LPB)
  ok('midi: cut removes the note', #mc.take.notes == 0, #mc.take.notes)
  E.paste(reg, LPB, 20, function() return { track = N, lane_idx = nil } end)
  local n = nc.take.notes[1]
  ok('midi: pasted into the clip of the target track', n ~= nil)
  if n then
    ok('midi: pitch kept', n.pitch == 67, n.pitch)
    ok('midi: velocity kept', n.vel == 90, n.vel)
    ok('midi: channel kept', n.ch == 3, n.ch)
    ok('midi: starts at the row', near(R.MIDI_GetProjTimeFromPPQPos(nc.take, n.sppq), rt(20)), R.MIDI_GetProjTimeFromPPQPos(nc.take, n.sppq))
    ok('midi: length kept (3 rows)', math.abs((n.eppq - n.sppq) - 3 * 960 / LPB) <= 2, n.eppq - n.sppq)
  end
end

local u = {}
for k, c in pairs(unknown) do u[#u + 1] = k .. ' x' .. c end
table.sort(u)
if #u > 0 then print('not imitated (returned nil): ' .. table.concat(u, ', ')) end
print(('%d checks, %d failed'):format(checks, fails))
os.exit(fails == 0 and 0 or 1)
