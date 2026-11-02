-- live_clips.lua (2 ноя) — живой тест в пустой вкладке-песочнице (tests/sandbox_newtab.lua отдельным запуском):
-- вставка / удаление строк в паттерне и в секции, жёсткие границы (клип через границу режется, ноты не теряются),
-- :mergeclips (pat_merge force), yank / paste из паттерна в паттерн — в клип паттерна, не свободный.
-- Запуск: python3 tests/nw.py lua "return dofile('<путь>/tests/live_clips.lua')" → строка отчёта.
local R = reaper
local DIR = debug.getinfo(1, 'S').source:sub(2):match('(.*)/tests/')
local _, pname = R.EnumProjects(-1, '')
if (pname or '') ~= '' then return 'REFUSED: not an unsaved sandbox tab' end
if R.CountTracks(0) > 1 then return 'REFUSED: the tab has tracks' end
if R.CountTracks(0) == 1 then local _, n = R.GetTrackName(R.GetTrack(0, 0)); if n ~= 'zz_clips' then return 'REFUSED: not my sandbox track' end end

local M = dofile(DIR .. '/jf_tracker_model.lua')
local E = dofile(DIR .. '/jf_tracker_edit.lua')
local A = dofile(DIR .. '/jf_tracker_alias.lua')
E.init(M); A.init(M, E)
E.pat_item = function() return true end

R.SetCurrentBPM(0, 120, false)   -- такт = 2 с, LPB 4: строка = 0.125 с
local LPB, ROW = 4, 0.125
local _, nm, nr = R.CountProjectMarkers(0)
for i = nm + nr - 1, 0, -1 do R.DeleteProjectMarkerByIndex(0, i) end
R.AddProjectMarker2(0, true, 0, 2, 'A1', 1, 0)
R.AddProjectMarker2(0, true, 2, 4, 'B1', 2, 0)
R.AddProjectMarker2(0, true, 4, 6, 'C1', 3, 0)
local REG = { { pos = 0, rgnend = 2 }, { pos = 2, rgnend = 4 }, { pos = 4, rgnend = 6 } }

local out, fails = {}, 0
local function check(name, ok, info) if not ok then fails = fails + 1 end; out[#out + 1] = (ok and 'ok ' or 'FAIL ') .. name .. (ok and '' or (' [' .. tostring(info) .. ']')) end

local tr
local function fresh()
  if tr then R.DeleteTrack(tr) end
  R.InsertTrackAtIndex(0, false); tr = R.GetTrack(0, 0)
  R.GetSetMediaTrackInfo_String(tr, 'P_NAME', 'zz_clips', true)
end
local function clip(a, b, notes)
  local it = R.CreateNewMIDIItemInProj(tr, a, b, false)
  local tk = R.GetActiveTake(it)
  for _, t in ipairs(notes or {}) do
    R.MIDI_InsertNote(tk, false, false, R.MIDI_GetPPQPosFromProjTime(tk, t), R.MIDI_GetPPQPosFromProjTime(tk, t + ROW), 0, 60, 100, true)
  end
  R.MIDI_Sort(tk)
  return it
end
-- все ноты трека: времена начала по порядку, число MIDI-клипов
local function notes()
  local t, nclip = {}, 0
  for i = 0, R.CountTrackMediaItems(tr) - 1 do
    local it = R.GetTrackMediaItem(tr, i); local tk = R.GetActiveTake(it)
    if tk and R.TakeIsMIDI(tk) then
      nclip = nclip + 1
      local p0 = R.GetMediaItemInfo_Value(it, 'D_POSITION'); local p1 = p0 + R.GetMediaItemInfo_Value(it, 'D_LENGTH')
      local _, nn = R.MIDI_CountEvts(tk)
      for k = 0, nn - 1 do
        local _, _, _, sp = R.MIDI_GetNote(tk, k)
        local s = R.MIDI_GetProjTimeFromPPQPos(tk, sp)
        if s >= p0 - 1e-6 and s < p1 - 1e-6 then t[#t + 1] = math.floor(s * 1000 + 0.5) / 1000 end   -- только видимые в клипе
      end
    end
  end
  table.sort(t)
  return table.concat(t, ','), nclip
end
local function clips_in(a, b)
  local n = 0
  for i = 0, R.CountTrackMediaItems(tr) - 1 do
    local it = R.GetTrackMediaItem(tr, i); local tk = R.GetActiveTake(it)
    local p = R.GetMediaItemInfo_Value(it, 'D_POSITION')
    if tk and R.TakeIsMIDI(tk) and p >= a - 1e-6 and p < b - 1e-6 then n = n + 1 end
  end
  return n
end

-- 1. вставка строки в B1, клип B1..C1 (ноты C1 в нём), предел — конец B1, потом жёсткие границы
fresh(); clip(2, 5, { 2.0, 3.0, 4.5 })
E.time_insert({ tr }, 2.5, ROW, 4, true, LPB, 1)
A.trim(REG)
local s, n = notes()
check('insert in B1: C1 note stays at 4.5, B1 note moves', s == '2.0,3.125,4.5', s)
check('insert in B1: clip split at the B1/C1 edge', clips_in(4, 6) == 1 and n == 2, n)

-- 2. удаление строки в B1 (keepend), предел — конец B1
fresh(); clip(2, 5, { 2.0, 3.0, 4.5 })
E.time_delete({ tr }, 2.5, 2.5 + ROW, 4, true, LPB, 1, true)
A.trim(REG)
s = notes()
check('delete in B1: C1 note stays at 4.5', s == '2.0,2.875,4.5', s)

-- 3. вставка в секции B1..C1 (предел — конец секции 6): нота C1 едет тоже, за 6 ничего
fresh(); clip(2, 6, { 2.0, 3.0, 4.5 })
E.time_insert({ tr }, 2.5, ROW, 6, true, LPB, 1)
s = notes()
check('insert in section B1..C1: the C1 note moves with it', s == '2.0,3.125,4.625', s)

-- 4. :mergeclips (force): клип через A1/B1, клип внутри B1, пустой айтем (не MIDI) — B1 один клип, A1 и пустой целы
fresh(); clip(1.5, 2.5, { 1.6, 2.1 }); clip(3, 3.5, { 3.1 })
local empty = R.AddMediaItemToTrack(tr); R.SetMediaItemInfo_Value(empty, 'D_POSITION', 2.2); R.SetMediaItemInfo_Value(empty, 'D_LENGTH', 0.2)
local m = E.pat_merge(tr, nil, 2, 4, true)
s = notes()
check('mergeclips: merged', m ~= nil)
check('mergeclips: one MIDI clip in B1', clips_in(2, 4) == 1, clips_in(2, 4))
check('mergeclips: no note lost', s == '1.6,2.1,3.1', s)
check('mergeclips: the non-MIDI item untouched', R.ValidatePtr(empty, 'MediaItem*'))

-- 5. yank из B1, paste в C1 — ноты в клип C1 (один на паттерн), B1 цел
fresh(); clip(2, 4, { 2.0, 2.5 }); clip(4, 6, { 5.0 })
local snap = M.snapshot(LPB)
local col = snap.cols[1]
local heads = {}
for _, ln in ipairs(col and col.lanes or {}) do
  for _, sub in ipairs(ln.subs or {}) do
    for r, c in pairs(sub) do if type(r) == 'number' and r >= 16 and r < 32 and c.kind == 'midi' then c.fi = 1; heads[#heads + 1] = c end end
  end
end
check('yank: two heads in B1', #heads == 2, #heads)
local reg = E.yank(heads, LPB, 16, 1)
E.paste(reg, LPB, 32, function() return { track = tr } end)
s = notes()
check('paste into C1: notes at 4.0 and 4.5, B1 kept', s == '2.0,2.5,4.0,4.5,5.0', s)
check('paste into C1: no free clip (one in C1)', clips_in(4, 6) == 1, clips_in(4, 6))

R.DeleteTrack(tr)
return ('live_clips: %d fail(s) ;; %s'):format(fails, table.concat(out, ' ;; '))
