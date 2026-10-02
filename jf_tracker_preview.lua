-- jf_tracker_preview.lua — предпрослушивание вставляемого события.
--
-- Аудио (копия item из DEPOT): CF_Preview (SWS) — источник образца играет
-- ЧЕРЕЗ ЦЕПОЧКУ FX целевого трека (CF_Preview_SetOutputTrack) с тем же
-- D_PITCH, что получит item. Транспорт не трогается.
-- MIDI-нота: через транспорт — play от строки на длину ноты, потом stop и
-- возврат edit-курсора; так звучит именно инструмент трека. Если проект
-- уже играет — ничего не делаем (нота и так прозвучит на своём месте).
-- Без SWS аудио-превью молча выключено.

local P = {}
local R = reaper
local cur                     -- текущий CF_Preview
local stop_at, restore_cur    -- MIDI-превью через транспорт

function P.available() return R.CF_CreatePreview ~= nil end

local function stop_audio()
  if cur then pcall(R.CF_Preview_Stop, cur); cur = nil end
end

local audio_stop_at

-- аудио: source образца через трек с питчем (полутоны); max_sec — лимит
function P.audio(track, depot_item, semis, max_sec)
  if not P.available() or not depot_item then return false end
  local take = R.GetActiveTake(depot_item)
  local src = take and R.GetMediaItemTake_Source(take)
  if not src then return false end
  stop_audio()
  audio_stop_at = max_sec and (R.time_precise() + max_sec) or nil
  local pv = R.CF_CreatePreview(src)
  if not pv then return false end
  R.CF_Preview_SetValue(pv, 'D_PITCH', semis or 0)
  R.CF_Preview_SetValue(pv, 'D_VOLUME', take and R.GetMediaItemTakeInfo_Value(take, 'D_VOL') or 1)
  R.CF_Preview_SetValue(pv, 'D_POSITION', take and R.GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS') or 0)
  if track then R.CF_Preview_SetOutputTrack(pv, 0, track) end
  R.CF_Preview_Play(pv)
  cur = pv
  return true
end

-- слайс инструмента: от t0 до t1 секунд item (через трек)
function P.slice(track, entry, t0, t1)
  if not P.available() or not entry then return false end
  local src = entry.take and R.GetMediaItemTake_Source(entry.take) or entry.src
  if not src then return false end
  stop_audio()
  local rate = entry.rate or 1
  audio_stop_at = R.time_precise() + math.max(0.05, (t1 - t0))
  local pv = R.CF_CreatePreview(src)
  if not pv then return false end
  R.CF_Preview_SetValue(pv, 'D_POSITION', (entry.offs or 0) + t0 * rate)
  R.CF_Preview_SetValue(pv, 'D_PLAYRATE', rate)
  if track then R.CF_Preview_SetOutputTrack(pv, 0, track) end
  R.CF_Preview_Play(pv)
  cur = pv
  return true
end

-- MIDI: транспорт от t0 до t1
function P.midi(t0, t1)
  if R.GetPlayState() & 1 == 1 then return false end
  restore_cur = R.GetCursorPosition()
  R.SetEditCurPos(t0, false, false)
  R.OnPlayButton()
  stop_at = R.time_precise() + math.max(0.1, t1 - t0)
  return true
end

-- файл с диска (браузер): через трек, лимит секунд
function P.file(track, path, max_sec)
  if not P.available() or not path then return false end
  local src = R.PCM_Source_CreateFromFile(path)
  if not src then return false end
  stop_audio()
  audio_stop_at = max_sec and (R.time_precise() + max_sec) or nil
  local pv = R.CF_CreatePreview(src)
  R.PCM_Source_Destroy(src)          -- превью держит свою ссылку
  if not pv then return false end
  if track then R.CF_Preview_SetOutputTrack(pv, 0, track) end
  R.CF_Preview_Play(pv)
  cur = pv
  return true
end

-- звать каждый кадр
function P.tick()
  if audio_stop_at and R.time_precise() >= audio_stop_at then audio_stop_at = nil; stop_audio() end
  if stop_at and R.time_precise() >= stop_at then
    stop_at = nil
    R.OnStopButton()
    if restore_cur then R.SetEditCurPos(restore_cur, false, false); restore_cur = nil end
  end
end

function P.stop()
  stop_audio()
  if stop_at then stop_at = nil; R.OnStopButton(); if restore_cur then R.SetEditCurPos(restore_cur, false, false); restore_cur = nil end end
end

return P
