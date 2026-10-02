-- sandbox_setup.lua — наполнить ПУСТУЮ вкладку тестовым материалом трекера.
--
-- Запускать только в новой вкладке (Main_OnCommand 40859 — отдельным шагом,
-- она убивает вызвавший defer-скрипт). Отказывается работать, если в
-- проекте уже есть треки или у него есть имя файла: защита от прогона в
-- проекте пользователя (память reaper-script-testing).
--
-- Содержимое: трек A (аудио, перекрытие, питч rate/pitch), трек B (fixed
-- lanes ×2), трек M (MIDI, полифония, зацикленный item), трек DEPOT (не
-- должен показываться). Темп 120, 4/4.

local R = reaper
local AUDIO = os.getenv('HOME') .. '/samples/!breaks/amen/amenattempt2.wav'
local EXT = 'jf_tracker'

local _, pname = R.EnumProjects(-1, '')
if R.CountTracks(0) > 0 or (pname and pname ~= '') then
  R.SetExtState(EXT, 'sandbox', 'REFUSED: project not empty (' .. tostring(pname) .. ')', false)
  return
end

local function audio_item(tr, pos, len, name, opts)
  local it = R.AddMediaItemToTrack(tr)
  local tk = R.AddTakeToMediaItem(it)
  local src = R.PCM_Source_CreateFromFile(AUDIO)
  R.SetMediaItemTake_Source(tk, src)
  R.GetSetMediaItemTakeInfo_String(tk, 'P_NAME', name, true)
  R.SetMediaItemInfo_Value(it, 'D_POSITION', pos)
  R.SetMediaItemInfo_Value(it, 'D_LENGTH', len)
  local ITEM_KEYS = { I_FIXEDLANE = true, B_MUTE = true, D_VOL = true }
  for k, v in pairs(opts or {}) do
    if ITEM_KEYS[k] then R.SetMediaItemInfo_Value(it, k, v)
    else R.SetMediaItemTakeInfo_Value(tk, k, v) end
  end
  return it, tk
end

R.Undo_BeginBlock()
R.SetCurrentBPM(0, 120, false)

-- A: аудио
R.InsertTrackAtIndex(0, true)
local A = R.GetTrack(0, 0)
R.GetSetMediaTrackInfo_String(A, 'P_NAME', 'A drums', true)
R.SetTrackColor(A, R.ColorToNative(220, 120, 60))
audio_item(A, 0, 2.0, 'amen', { D_PLAYRATE = 2 ^ (2 / 12), B_PPITCH = 0 })   -- D-4 resample
audio_item(A, 0.375, 0.5, 'snare', { D_PITCH = -12 })                        -- C-3, перекрытие → 2-я подколонка
audio_item(A, 2.5, 0.125, 'hat', { D_STARTOFFS = 0.7 })                        -- ровно строка 20 при LPB 4
audio_item(A, 3.0, 1.0, 'muted', { B_MUTE = 1 })

-- B: fixed lanes
R.InsertTrackAtIndex(1, true)
local B = R.GetTrack(0, 1)
R.GetSetMediaTrackInfo_String(B, 'P_NAME', 'B lanes', true)
R.SetMediaTrackInfo_Value(B, 'I_FREEMODE', 2)
R.SetMediaTrackInfo_Value(B, 'I_NUMFIXEDLANES', 2)
R.GetSetMediaTrackInfo_String(B, 'P_LANENAME:0', 'top', true)
R.GetSetMediaTrackInfo_String(B, 'P_LANENAME:1', 'bot', true)
audio_item(B, 0.0, 1.0, 'lane0', { I_FIXEDLANE = 0 })
audio_item(B, 0.5, 1.0, 'lane1', { I_FIXEDLANE = 1 })
R.UpdateTimeline()

-- M: MIDI, зацикленный item 2 такта из источника в 1 такт
R.InsertTrackAtIndex(2, true)
local M = R.GetTrack(0, 2)
R.GetSetMediaTrackInfo_String(M, 'P_NAME', 'M synth', true)
R.SetTrackColor(M, R.ColorToNative(80, 160, 220))
local mi = R.CreateNewMIDIItemInProj(M, 2.0, 4.0, false)     -- такт 2 (2.0 с при 120)
local mt = R.GetActiveTake(mi)
local function ppq(t) return R.MIDI_GetPPQPosFromProjTime(mt, t) end
R.MIDI_DisableSort(mt)
R.MIDI_InsertNote(mt, false, false, ppq(2.0), ppq(2.5), 0, 60, 100, true)   -- C-4, 1 QN
R.MIDI_InsertNote(mt, false, false, ppq(2.0), ppq(3.0), 0, 64, 90, true)    -- E-4, 2 QN (полифония)
R.MIDI_InsertNote(mt, false, false, ppq(2.5), ppq(2.625), 0, 67, 70, true)  -- G-4, короче строки
R.MIDI_InsertNote(mt, false, false, ppq(3.0625), ppq(3.5), 0, 62, 80, true) -- D-4 с delay
R.MIDI_Sort(mt)
R.SetMediaItemInfo_Value(mi, 'B_LOOPSRC', 1)
R.SetMediaItemInfo_Value(mi, 'D_LENGTH', 4.0)                 -- 2 такта → повтор

-- DEPOT: не показывать
R.InsertTrackAtIndex(3, true)
local D = R.GetTrack(0, 3)
R.GetSetMediaTrackInfo_String(D, 'P_NAME', 'DEPOT', true)
R.SetMediaTrackInfo_Value(D, 'B_MUTE', 1)
audio_item(D, 0, 1.0, 'depot sample')

R.Undo_EndBlock('jf_tracker sandbox', -1)
R.UpdateArrange()
R.SetExtState(EXT, 'sandbox', 'ok tracks=' .. R.CountTracks(0), false)
