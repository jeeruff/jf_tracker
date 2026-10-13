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

P.vol = 1                     -- громкость прослушивания файлов браузера (линейная, слайдер внизу браузера)
P.cur_path, P.cur_len = nil, 0  -- что играет из браузера (мини-волна с позицией)

local cur2                    -- 13 окт: хвост лупа удержания (второе превью ноты)
local function stop_audio()
  if cur then pcall(R.CF_Preview_Stop, cur); cur = nil end
  if cur2 then pcall(R.CF_Preview_Stop, cur2); cur2 = nil end
  P.stop_pos = nil
  P.cur_path = nil
  P.cur_item = nil
end

function P.set_vol(v)
  P.vol = math.max(0, math.min(4, v))
  if cur and P.cur_path then pcall(R.CF_Preview_SetValue, cur, 'D_VOLUME', P.vol) end
end

-- позиция проигрываемого файла: секунды, длина, путь (nil — ничего не играет)
function P.position()
  if not (cur and P.cur_path) then return nil end
  local ok, pos = R.CF_Preview_GetValue(cur, 'D_POSITION')
  if not ok then return nil end
  return pos, P.cur_len, P.cur_path
end

-- 10 окт: плейхед слайсера — где сейчас превью этого item, в секундах от начала item (nil — не играет)
function P.item_pos(item)
  if not (cur and P.cur_item and P.cur_item == item) then return nil end
  local ok, pos = R.CF_Preview_GetValue(cur, 'D_POSITION')
  if not ok then return nil end
  return (pos - (P.cur_offs or 0)) / math.max(1e-6, P.cur_rate or 1), P.cur_t0 or 0
end

local audio_stop_at

-- трек для превью (4 окт): превью входит в трек как вход — армированный трек
-- с выключенным мониторингом его глушит (с jf_rec «звучала тишина»). Такой
-- трек — мимо: превью сразу в мастер (без FX трека, зато слышно)
function P.out_track(track)
  if not (track and R.ValidatePtr(track, 'MediaTrack*')) then return nil end
  if R.GetMediaTrackInfo_Value(track, 'I_RECARM') == 1 and R.GetMediaTrackInfo_Value(track, 'I_RECMON') == 0 then return nil end
  return track
end

-- ── нота инструмента (13 окт): общий построитель превью ─────────────────
-- Без лупа удержания — одно превью источника take с offset / rate / питчем / громкостью.
-- С лупом (lp = { on, ls, le, xf } — секунды файла, P_EXT:jf_loop): атака — секция файла
-- [offs, ls) без лупа, хвост — секция [ls, le) по кругу (xf — кроссфейд шва). Оба превью
-- стартуют вместе, хвост — с отрицательной позицией: CF_Preview молчит до 0, и хвост вступает
-- ровно там, где кончилась атака (без опроса кадров). Звучит, пока не остановят.
-- Секции кэшируются: превью держит свою ссылку на источник (как P.file), уничтожать не нужно.
local sections = {}
local function section(path, a, len, xf)
  local k = ('%s|%.6f|%.6f|%.4f'):format(path, a, len, xf or 0)
  if sections[k] then return sections[k] end
  if not (R.CF_PCM_Source_SetSectionInfo and R.PCM_Source_CreateFromType) then return nil end
  local file = R.PCM_Source_CreateFromFile(path)
  local sec = file and R.PCM_Source_CreateFromType('SECTION')
  if not (sec and R.CF_PCM_Source_SetSectionInfo(sec, file, a, len, false, xf or 0)) then return nil end
  sections[k] = sec
  return sec
end
P.sus_ok = function(lp) return lp and lp.on and lp.le - lp.ls > 1e-3 and R.CF_PCM_Source_SetSectionInfo ~= nil end

-- → список превью (ещё не запущены) или nil; gain — множитель громкости (скорость MIDI)
local function voice(track, item, semis, lp, gain)
  local take = item and R.ValidatePtr(item, 'MediaItem*') and R.GetActiveTake(item)
  local src = take and R.GetMediaItemTake_Source(take)
  if not src or R.TakeIsMIDI(take) then return nil end
  local rate = R.GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE'); if rate <= 0 then rate = 1 end
  local offs = R.GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS')
  local out_tr = P.out_track(track)
  local function one(s, pos, loop)
    local pv = R.CF_CreatePreview(s)
    if not pv then return nil end
    R.CF_Preview_SetValue(pv, 'D_PITCH', R.GetMediaItemTakeInfo_Value(take, 'D_PITCH') + (semis or 0))   -- нота поверх transpose инструмента (6 окт)
    R.CF_Preview_SetValue(pv, 'D_VOLUME', R.GetMediaItemTakeInfo_Value(take, 'D_VOL') * (gain or 1))
    R.CF_Preview_SetValue(pv, 'D_PLAYRATE', rate)                 -- как прозвучит нота (3 окт)
    R.CF_Preview_SetValue(pv, 'B_PPITCH', R.GetMediaItemTakeInfo_Value(take, 'B_PPITCH'))
    R.CF_Preview_SetValue(pv, 'D_POSITION', pos)
    if loop then R.CF_Preview_SetValue(pv, 'B_LOOP', 1) end
    if out_tr then R.CF_Preview_SetOutputTrack(pv, 0, out_tr) end
    return pv
  end
  if not P.sus_ok(lp) then local pv = one(src, offs); return pv and { pv } or nil, offs, rate end
  -- у головы ноты с лупом источник уже секция [0, ls) — файл берём у родителя
  local file = R.GetMediaSourceParent(src) or src
  local path = R.GetMediaSourceFileName(file, '')
  local per = lp.le - lp.ls
  local tail = (lp.file and lp.boff and R.file_exists(lp.file)) and section(lp.file, lp.boff, per, 0) or section(path, lp.ls, per, lp.xf)   -- 13 окт: запечённый луп
  if not tail then local pv = one(src, offs); return pv and { pv } or nil, offs, rate end
  if offs >= lp.ls - 1e-4 then local pv = one(tail, (offs - lp.ls) % per, true); return pv and { pv } or nil, offs, rate end
  local head = section(path, offs, lp.ls - offs, 0)
  local h = head and one(head, 0)
  local t = h and one(tail, -(lp.ls - offs), true)
  if not t then if h then pcall(R.CF_Preview_Stop, h) end; return nil end
  return { h, t }, offs, rate
end

-- аудио: source образца через трек с питчем (полутоны); max_sec — лимит; lp — луп удержания
-- (13 окт: звучит, пока не P.stop — так зовут только удержания: Cmd+нота, MIDI)
function P.audio(track, depot_item, semis, max_sec, lp)
  if not P.available() or not depot_item then return false end
  stop_audio()
  audio_stop_at = max_sec and (R.time_precise() + max_sec) or nil
  local pvs, offs, rate = voice(track, depot_item, semis, lp, P.gain or 1)   -- 11 окт: P.gain — разовая громкость (смарт: прослушать vol)
  P.gain = nil
  if not pvs then return false end
  for _, pv in ipairs(pvs) do R.CF_Preview_Play(pv) end
  cur, cur2 = pvs[1], pvs[2]
  P.cur_item, P.cur_offs, P.cur_rate = depot_item, offs, rate   -- плейхед в модуле item (Shift+нота, MIDI)
  P.cur_t0 = 0
  P.cur_semis_add = semis or 0                                   -- нота поверх питча take
  return true
end

-- ── голоса MIDI-клавиатуры (13 окт): полифония, нота держится до note-off ──
-- С лупом удержания note-off глушит голос; без лупа — ваншот до конца item (808, удары
-- не обрываются отпусканием). key — номер ноты MIDI.
P.voices = {}
local VMAX = 16
function P.note_off(key)
  local v = P.voices[key]
  if not v or not v.sus then return end
  for _, pv in ipairs(v.pvs) do pcall(R.CF_Preview_Stop, pv) end
  P.voices[key] = nil
end
local function voices_stop()
  for k, v in pairs(P.voices) do for _, pv in ipairs(v.pvs) do pcall(R.CF_Preview_Stop, pv) end; P.voices[k] = nil end
end
function P.note_on(key, track, item, semis, lp, gain)
  if not P.available() then return false end
  local v = P.voices[key]
  if v then for _, pv in ipairs(v.pvs) do pcall(R.CF_Preview_Stop, pv) end; P.voices[key] = nil end
  local n, old = 0, nil
  for k, o in pairs(P.voices) do n = n + 1; if not old or o.t < P.voices[old].t then old = k end end
  if n >= VMAX and old then for _, pv in ipairs(P.voices[old].pvs) do pcall(R.CF_Preview_Stop, pv) end; P.voices[old] = nil end
  local pvs, offs, rate = voice(track, item, semis, lp, gain)
  if not pvs then return false end
  for _, pv in ipairs(pvs) do R.CF_Preview_Play(pv) end
  local sus = P.sus_ok(lp) and true or false
  local now = R.time_precise()
  P.voices[key] = { pvs = pvs, sus = sus, t = now,
    stop_at = (not sus) and now + R.GetMediaItemInfo_Value(item, 'D_LENGTH') + 0.05 or nil }
  P.cur_item, P.cur_offs, P.cur_rate, P.cur_t0, P.cur_semis_add = item, offs, rate, 0, semis or 0
  return true
end

-- инструмент целиком (3 окт): как прозвучит его нота — offset, rate, питч,
-- громкость take; до конца item (max_sec — лимит раньше). Позиция для
-- плейхеда в модуле item — P.inst_position()
function P.inst(track, item, max_sec)
  if not P.available() or not item then return false end
  local take = R.GetActiveTake(item)
  local src = take and R.GetMediaItemTake_Source(take)
  if not src then return false end
  stop_audio()
  local rate = R.GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE')
  if rate <= 0 then rate = 1 end
  local len = R.GetMediaItemInfo_Value(item, 'D_LENGTH')
  local dur = max_sec and math.min(max_sec, len) or len
  audio_stop_at = R.time_precise() + math.max(0.05, dur)
  local pv = R.CF_CreatePreview(src)
  if not pv then return false end
  local offs = R.GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS')
  R.CF_Preview_SetValue(pv, 'D_POSITION', offs)
  R.CF_Preview_SetValue(pv, 'D_PLAYRATE', rate)
  R.CF_Preview_SetValue(pv, 'B_PPITCH', R.GetMediaItemTakeInfo_Value(take, 'B_PPITCH'))
  R.CF_Preview_SetValue(pv, 'D_PITCH', R.GetMediaItemTakeInfo_Value(take, 'D_PITCH'))
  local pm = R.GetMediaItemTakeInfo_Value(take, 'I_PITCHMODE'); if pm >= 0 then R.CF_Preview_SetValue(pv, 'I_PITCHMODE', pm) end
  R.CF_Preview_SetValue(pv, 'D_VOLUME', R.GetMediaItemTakeInfo_Value(take, 'D_VOL') * R.GetMediaItemInfo_Value(item, 'D_VOL'))
  -- луп источника как у item (3 окт): item длиннее файла играет начало заново —
  -- превью звучит так же, как нота на таймлайне и как нарисована волна
  R.CF_Preview_SetValue(pv, 'B_LOOP', R.GetMediaItemInfo_Value(item, 'B_LOOPSRC'))
  local out_tr = P.out_track(track); if out_tr then R.CF_Preview_SetOutputTrack(pv, 0, out_tr) end
  R.CF_Preview_Play(pv)
  cur = pv
  P.cur_item, P.cur_offs, P.cur_rate = item, offs, rate
  P.cur_t0 = 0
  P.cur_semis_add = 0
  return true
end
-- 6 окт: правка свойств инструмента на лету — звучащее превью этого item
-- (или любого из items — копии инструмента) получает питч, rate, громкость
-- сразу, слайдер слышно в реальном времени
function P.live(items)
  if not (cur and P.cur_item) then return false end
  local hit = false
  for _, it in ipairs(items or {}) do if it == P.cur_item then hit = true; break end end
  if not hit or not R.ValidatePtr(P.cur_item, 'MediaItem*') then return false end
  local take = R.GetActiveTake(P.cur_item)
  if not take then return false end
  local rate = R.GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE'); if rate <= 0 then rate = 1 end
  pcall(R.CF_Preview_SetValue, cur, 'D_PITCH', R.GetMediaItemTakeInfo_Value(take, 'D_PITCH') + (P.cur_semis_add or 0))
  pcall(R.CF_Preview_SetValue, cur, 'D_PLAYRATE', rate)
  pcall(R.CF_Preview_SetValue, cur, 'B_PPITCH', R.GetMediaItemTakeInfo_Value(take, 'B_PPITCH'))
  pcall(R.CF_Preview_SetValue, cur, 'D_VOLUME', R.GetMediaItemTakeInfo_Value(take, 'D_VOL') * R.GetMediaItemInfo_Value(P.cur_item, 'D_VOL'))
  pcall(R.CF_Preview_SetValue, cur, 'D_PAN', R.GetMediaItemTakeInfo_Value(take, 'D_PAN'))
  P.cur_rate = rate
  return true
end
-- секунды от начала item, который играет (nil — не играет инструмент)
function P.inst_position(item)
  if not (cur and P.cur_item) or (item and item ~= P.cur_item) then return nil end
  local ok, pos = R.CF_Preview_GetValue(cur, 'D_POSITION')
  if not ok then return nil end
  return (pos - P.cur_offs) / P.cur_rate
end
function P.playing() return cur ~= nil or stop_at ~= nil end
-- позиция в источнике (секунды файла) и путь файла звучащего инструмента /
-- слайса — плейхед на любой записи lib того же файла (родитель или слайс)
function P.src_position()
  if not (cur and P.cur_item and R.ValidatePtr(P.cur_item, 'MediaItem*')) then return nil end
  local ok, pos = R.CF_Preview_GetValue(cur, 'D_POSITION')
  if not ok then return nil end
  local tk = R.GetActiveTake(P.cur_item)
  local src = tk and R.GetMediaItemTake_Source(tk)
  return pos, src and R.GetMediaSourceFileName(src, '') or ''
end

-- слайс инструмента: от t0 до t1 секунд item (через трек)
function P.slice(track, entry, t0, t1, semis)
  if not P.available() or not entry then return false end
  local src = entry.take and R.GetMediaItemTake_Source(entry.take) or entry.src
  if not src then return false end
  stop_audio()
  local rate = entry.rate or 1
  local dur = math.max(0.05, (t1 - t0))
  local pv = R.CF_CreatePreview(src)
  if not pv then return false end
  R.CF_Preview_SetValue(pv, 'D_POSITION', (entry.offs or 0) + t0 * rate)
  -- 8 окт: конец слайса — по позиции самого превью (D_POSITION в источнике),
  -- а не по таймеру от нажатия: таймер не учитывал задержку старта превью,
  -- и короткие слайсы обрывались раньше конца (D_LENGTH у SWS только для
  -- чтения). Таймер — страховка, если позиция не читается
  R.CF_Preview_SetValue(pv, 'D_FADEOUTLEN', 0.004)
  P.stop_pos = (entry.offs or 0) + t1 * rate
  audio_stop_at = R.time_precise() + dur + 0.5
  R.CF_Preview_SetValue(pv, 'D_PLAYRATE', rate)
  -- transpose инструмента — база слайса (6 окт: слайс звучал без него); Option+нота — поверх
  local base = entry.take and R.GetMediaItemTakeInfo_Value(entry.take, 'D_PITCH') or 0
  local pp = entry.take and R.GetMediaItemTakeInfo_Value(entry.take, 'B_PPITCH') or 0
  if semis and semis ~= 0 then pp = 1 end
  if base + (semis or 0) ~= 0 then R.CF_Preview_SetValue(pv, 'B_PPITCH', pp); R.CF_Preview_SetValue(pv, 'D_PITCH', base + (semis or 0)) end
  local out_tr = P.out_track(track); if out_tr then R.CF_Preview_SetOutputTrack(pv, 0, out_tr) end
  R.CF_Preview_Play(pv)
  cur = pv
  -- плейхед слайса на волне инструмента (3 окт: Shift+нота / MIDI-клавиатура)
  P.cur_item, P.cur_offs, P.cur_rate = entry.item, entry.offs or 0, rate ~= 0 and rate or 1
  P.cur_t0 = t0                                                 -- 10 окт: откуда играет — след на волне
  return true
end

-- MIDI: транспорт от t0 до t1
function P.midi(t0, t1)
  -- своё превью через транспорт (step listen, 4 окт) — оборвать и начать новое
  if stop_at then stop_at = nil; R.OnStopButton(); if restore_cur then R.SetEditCurPos(restore_cur, false, false); restore_cur = nil end end
  if R.GetPlayState() & 1 == 1 then return false end
  restore_cur = R.GetCursorPosition()
  R.SetEditCurPos(t0, false, false)
  R.OnPlayButton()
  -- 12 окт: стоп — когда позиция воспроизведения дошла до t1, а не по часам: REAPER до ~180 мс готовит звук
  -- заранее (позиция стоит), и короткая строка останавливалась раньше, чем звучала (line молчал)
  P.stop_pos = t1
  stop_at = R.time_precise() + math.max(0.1, t1 - t0) + 1.0      -- страховка, если позиция не пойдёт
  return true
end

-- файл с диска (браузер): через трек, лимит секунд
function P.file(track, path, max_sec, from, semis)
  if not P.available() or not path then return false end
  local src = R.PCM_Source_CreateFromFile(path)
  if not src then return false end
  stop_audio()
  audio_stop_at = max_sec and (R.time_precise() + max_sec) or nil
  local len = R.GetMediaSourceLength(src) or 0
  local pv = R.CF_CreatePreview(src)
  R.PCM_Source_Destroy(src)          -- превью держит свою ссылку
  if not pv then return false end
  local out_tr = P.out_track(track); if out_tr then R.CF_Preview_SetOutputTrack(pv, 0, out_tr) end
  R.CF_Preview_SetValue(pv, 'D_VOLUME', P.vol)
  if from and from > 0 then R.CF_Preview_SetValue(pv, 'D_POSITION', from) end
  -- keys браузера (5 окт): высота как у сэмплера — скорость 2^(n/12)
  if semis and semis ~= 0 then R.CF_Preview_SetValue(pv, 'D_PLAYRATE', 2 ^ (semis / 12)) end
  -- sync браузера (3 окт): нативное ожидание начала такта — только пока
  -- проект играет (на паузе SWS иначе молча продолжает превью)
  if P.sync and R.GetPlayState() & 1 == 1 then R.CF_Preview_SetValue(pv, 'D_MEASUREALIGN', 1) end
  R.CF_Preview_Play(pv)
  cur = pv
  P.cur_path, P.cur_len = path, len
  return true
end

-- звать каждый кадр
function P.tick()
  local now = R.time_precise()
  local dt = math.min(0.05, now - (P.last_tick or now))   -- длина кадра (defer ~30 Гц)
  P.last_tick = now
  if cur and P.stop_pos then
    local ok, pos = R.CF_Preview_GetValue(cur, 'D_POSITION')
    -- 11 окт: стоп с упреждением на полкадра — иначе короткий слайс (70 мс) проигрывал до 30 мс соседнего
    local ok2, rate = R.CF_Preview_GetValue(cur, 'D_PLAYRATE')
    local lead = 0.5 * dt * ((ok2 and rate and rate > 0) and rate or 1)
    if ok and pos >= P.stop_pos - 0.002 - lead then audio_stop_at = nil; stop_audio() end
  end
  if audio_stop_at and R.time_precise() >= audio_stop_at then audio_stop_at = nil; stop_audio() end
  for k, v in pairs(P.voices) do
    if v.stop_at and now >= v.stop_at then for _, pv in ipairs(v.pvs) do pcall(R.CF_Preview_Stop, pv) end; P.voices[k] = nil end
  end
  if stop_at and P.stop_pos and R.GetPlayState() & 1 == 1 and R.GetPlayPosition() >= P.stop_pos - 0.002 then stop_at = R.time_precise() end
  if stop_at and R.time_precise() >= stop_at then
    stop_at = nil; P.stop_pos = nil
    R.OnStopButton()
    if restore_cur then R.SetEditCurPos(restore_cur, false, false); restore_cur = nil end
  end
end

function P.stop()
  stop_audio()
  voices_stop()
  P.stop_pos = nil
  if stop_at then stop_at = nil; R.OnStopButton(); if restore_cur then R.SetEditCurPos(restore_cur, false, false); restore_cur = nil end end
end

return P
