-- live_retro.lua (2 ноя) — живой тест ретро-записи R в пустой вкладке-песочнице (tests/sandbox_newtab.lua отдельно).
-- Действие 40211 (сыгранное — новым MIDI-айтемом) без живого MIDI-входа не вызвать: тест строит такой айтем сам
-- (как его кладёт REAPER: тишина до первой ноты) и проверяет edit.retro_settle — то, что делает R после 40211.
local R = reaper
local DIR = debug.getinfo(1, 'S').source:sub(2):match('(.*)/tests/')
local _, pname = R.EnumProjects(-1, '')
if (pname or '') ~= '' then return 'REFUSED: not an unsaved sandbox tab' end
if R.CountTracks(0) > 0 then return 'REFUSED: the tab has tracks' end

local M = dofile(DIR .. '/jf_tracker_model.lua')
local E = dofile(DIR .. '/jf_tracker_edit.lua')
E.init(M)
R.SetCurrentBPM(0, 120, false)   -- такт 2 с, строка (LPB 4) 0.125 с
local ROW = 0.125
local PATS = { { pos = 0, rgnend = 2 }, { pos = 2, rgnend = 4 }, { pos = 4, rgnend = 6 } }

local out, fails = {}, 0
local function check(name, ok, info) if not ok then fails = fails + 1 end; out[#out + 1] = (ok and 'ok ' or 'FAIL ') .. name .. (ok and '' or (' [' .. tostring(info) .. ']')) end
local tr
local function fresh()
  if tr then R.DeleteTrack(tr) end
  R.InsertTrackAtIndex(0, false); tr = R.GetTrack(0, 0)
  R.GetSetMediaTrackInfo_String(tr, 'P_NAME', 'zz_retro', true)
end
local function clip(a, b, notes)
  local it = R.CreateNewMIDIItemInProj(tr, a, b, false)
  local tk = R.GetActiveTake(it)
  for _, t in ipairs(notes or {}) do R.MIDI_InsertNote(tk, false, false, R.MIDI_GetPPQPosFromProjTime(tk, t), R.MIDI_GetPPQPosFromProjTime(tk, t + ROW), 0, 60, 100, true) end
  R.MIDI_Sort(tk)
  return it
end
local function notes()
  local t, n = {}, 0
  for i = 0, R.CountTrackMediaItems(tr) - 1 do
    local it = R.GetTrackMediaItem(tr, i); local tk = R.GetActiveTake(it)
    if tk and R.TakeIsMIDI(tk) then
      n = n + 1
      local p0 = R.GetMediaItemInfo_Value(it, 'D_POSITION'); local p1 = p0 + R.GetMediaItemInfo_Value(it, 'D_LENGTH')
      local _, nn = R.MIDI_CountEvts(tk)
      for k = 0, nn - 1 do
        local _, _, _, sp = R.MIDI_GetNote(tk, k); local s = R.MIDI_GetProjTimeFromPPQPos(tk, sp)
        if s >= p0 - 1e-6 and s < p1 - 1e-6 then t[#t + 1] = math.floor(s * 1000 + 0.5) / 1000 end
      end
    end
  end
  table.sort(t)
  return table.concat(t, ','), n
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

-- 1. при стопе: сыгранное пришло к курсору с тишиной 0.4 с — первая нота на строку курсора (2.5), в клип B1
fresh(); clip(2, 4, { 2.0 })
local made = clip(2.5, 3.5, { 2.9, 3.15 })   -- как 40211 при стопе: айтем с курсора, ноты после паузы
local m, at = E.retro_settle(tr, made, 2.5, nil, PATS)
local s, n = notes()
check('stopped: first note on the cursor row', s == '2.0,2.5,2.75', s)
check('stopped: not "where played"', at == false, tostring(at))
check('stopped: merged into the B1 clip (one clip)', clips_in(2, 4) == 1 and n == 1, n)
check('stopped: returns the clip with the notes', m ~= nil and R.ValidatePtr(m, 'MediaItem*'))

-- 2. при игре: сыгранное лежит где играли (через B1/C1) — остаётся там, режется по границе в клипы обоих паттернов
fresh(); clip(2, 4, { 2.0 }); clip(4, 6, { 5.5 })
made = clip(3.0, 5.0, { 3.5, 4.25 })
m, at = E.retro_settle(tr, made, 1.0, nil, PATS)
s, n = notes()
check('playing: notes stay where played', s == '2.0,3.5,4.25,5.5', s)
check('playing: "where played"', at == true, tostring(at))
check('playing: one clip in B1 and one in C1', clips_in(2, 4) == 1 and clips_in(4, 6) == 1 and n == 2, n)

-- 3. без pattern MIDI item (pats = nil): свободный клип, как раньше
fresh()
made = clip(2.5, 3.5, { 2.75 })
m = E.retro_settle(tr, made, 2.5, nil, nil)
s, n = notes()
check('no pattern item: free clip kept, note on the row', s == '2.5' and n == 1 and m == made, s .. ' n' .. n)

-- 4. пустой паттерн (клипа нет): сыгранное само становится клипом паттерна
fresh()
made = clip(4.25, 5.0, { 4.5 })
m = E.retro_settle(tr, made, 4.25, nil, PATS)
s, n = notes()
check('empty pattern: one clip, note on the row', s == '4.25' and n == 1 and clips_in(4, 6) == 1, s .. ' n' .. n)

R.DeleteTrack(tr)
return ('live_retro: %d fail(s) ;; %s'):format(fails, table.concat(out, ' ;; '))
