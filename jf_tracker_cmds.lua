-- jf_tracker_cmds.lua — команды-огибающие и генераторы (этап 7).
--
-- Команда хранится у item как текст в P_EXT:jf_cmds («U08,4A3,R42») и
-- ПЕРЕСОБИРАЕТСЯ целиком при каждой правке: take-огибающие (Pitch, Volume)
-- внутри item очищаются и строятся заново, сгенерированные копии
-- (P_EXT:jf_gen = guid родителя) удаляются и создаются снова. Всё
-- нативное: точки take-огибающих, items, tempo-маркеры, MIDI pitchbend.
-- Тиклесс: доли — от строки (xx/16 полутона на строку и т.п.).
--
--   Uxx / Dxx  питч вверх/вниз на xx/16 полутона за строку на всю длину
--              (аудио — take Pitch; MIDI — pitchbend ±2 полутона)
--   Gxx        glide: от высоты предыдущего события к своей за xx строк
--   4xy        vibrato: период 16/x строк (x=0 → 4), глубина y/8 полутона
--   0xy        arpeggio: 0, x, y полутонов по трети строки, ступенями
--   Axy        volume slide: +x/16 за строку вверх, −y/16 вниз (take Volume)
--   Rxy        retrigger: копии каждые x/16 строки (x=0 → 4/16), громкость
--              каждой ×(1 − y/16); копии — items с P_EXT:jf_gen
--   Pxx        вероятность: item заглушается с шансом 1 − xx/FF (бросок
--              при каждой пересборке)
--   Fxx        темп: tempo-маркер в строке события, BPM = xx (hex)

local C = {}
local R = reaper
local model

C.LETTERS = { U = true, D = true, G = true, ['4'] = true, ['0'] = true, A = true, R = true, P = true, F = true, B = true }
-- Bxx — прыжок: когда плейхед доходит до строки события, трекер переводит
-- воспроизведение в слот xx последовательности (матрица). Хранится как
-- команда, огибающих не строит — исполняет main в кадре.

function C.init(m) model = m end

-- ── разбор / хранение ─────────────────────────────────────────────────────
function C.parse(str)
  local out = {}
  for tok in (str or ''):gmatch('[^,]+') do
    local letter, hex = tok:match('^(%w)(%x%x)$')
    if letter and C.LETTERS[letter] then
      local xx = tonumber(hex, 16)
      out[#out + 1] = { cmd = letter, xx = xx, x = xx >> 4, y = xx & 15 }
    end
  end
  return out
end

function C.format(list)
  local t = {}
  for _, c in ipairs(list) do t[#t + 1] = c.cmd .. ('%02X'):format(c.xx) end
  return table.concat(t, ',')
end

function C.get(it)
  local _, s = R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_cmds', '', false)
  return C.parse(s)
end

function C.set(it, list)
  R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_cmds', C.format(list), true)
end

-- добавить/заменить команду letter со значением xx (nil — снять)
function C.put(it, letter, xx)
  local list = C.get(it)
  local out = {}
  for _, c in ipairs(list) do if c.cmd ~= letter then out[#out + 1] = c end end
  if xx then out[#out + 1] = { cmd = letter, xx = xx, x = xx >> 4, y = xx & 15 } end
  C.set(it, out)
  return out
end

-- ── take-огибающие ────────────────────────────────────────────────────────
local env_action = {}
local function find_action(what)
  if env_action[what] ~= nil then return env_action[what] end
  local found = false
  for _, range in ipairs({ { 41600, 41700 }, { 40000, 41600 }, { 41700, 42500 } }) do
    for id = range[1], range[2] do
      local t = R.kbd_getTextFromCmd(id, 0) or ''
      if t:match('^Take: Toggle take ' .. what .. ' envelope') then found = id; break end
    end
    if found then break end
  end
  env_action[what] = found
  return found
end

local function ensure_take_env(it, take, name)
  local env = R.GetTakeEnvelopeByName(take, name)
  if env then return env end
  local id = find_action(name:lower())
  if not id then return nil end
  R.SelectAllMediaItems(0, false); R.SetMediaItemSelected(it, true)
  R.Main_OnCommand(id, 0)
  return R.GetTakeEnvelopeByName(take, name)
end

local function env_range(env, dmin, dmax)
  if R.BR_EnvAlloc then
    local be = R.BR_EnvAlloc(env, false)
    local _, _, _, _, _, _, mn, mx = R.BR_EnvGetProperties(be); R.BR_EnvFree(be, false)
    if mn and mx and mx > mn then return mn, mx end
  end
  return dmin, dmax
end

local function clear_env(env, it, take)
  local len = R.GetMediaItemInfo_Value(it, 'D_LENGTH') * R.GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE')
  R.DeleteEnvelopePointRange(env, -1e-6, len + 1e-6)
end

local function pt(env, t, v, shape) R.InsertEnvelopePoint(env, t, v, shape or 0, 0, false, true) end

-- ── генераторы ────────────────────────────────────────────────────────────
local function strip_guids(chunk)
  return (chunk:gsub('\n%s*GUID %b{}', ''):gsub('\n%s*IGUID %b{}', ''))
end

local function item_guid(it) return R.BR_GetMediaItemGUID and R.BR_GetMediaItemGUID(it) or tostring(it) end

local function delete_generated(tr, guid)
  for i = R.CountTrackMediaItems(tr) - 1, 0, -1 do
    local it = R.GetTrackMediaItem(tr, i)
    local _, g = R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_gen', '', false)
    if g == guid then R.DeleteTrackMediaItem(tr, it) end
  end
end

-- ── пересборка команд одного item ─────────────────────────────────────────
-- head: голова из модели (item, take, row0, rows, pitch/semis); lpb; prev —
-- высота (полутоны) предыдущего события в подколонке (для glide)
function C.rebuild(head, lpb, prev_semis)
  local it, take = head.item, head.take
  if not it or not take then return end
  local list = C.get(it)
  local tr = R.GetMediaItem_Track(it)
  local guid = item_guid(it)
  delete_generated(tr, guid)
  local pos = R.GetMediaItemInfo_Value(it, 'D_POSITION')
  -- retrigger укорачивал родителя: вернуть исходную длину из P_EXT:jf_len
  do
    local _, l0 = R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_len', '', false)
    if l0 and tonumber(l0) then R.SetMediaItemInfo_Value(it, 'D_LENGTH', tonumber(l0)); R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_len', '', true) end
  end
  -- tempo-маркер, поставленный нами (P_EXT:jf_tempo) — убрать перед пересборкой
  do
    local _, tm = R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_tempo', '', false)
    if tm == '1' then
      local idx = R.FindTempoTimeSigMarker(0, pos + 1e-4)
      if idx and idx >= 0 then
        local ok, t = R.GetTempoTimeSigMarker(0, idx)
        if ok and math.abs(t - pos) < 1e-3 then R.DeleteTempoTimeSigMarker(0, idx) end
      end
      R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_tempo', '', true)
    end
  end
  local len = R.GetMediaItemInfo_Value(it, 'D_LENGTH')
  local rate = R.GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE')
  local is_midi = R.TakeIsMIDI(take)
  local qn0 = R.TimeMap2_timeToQN(0, pos)
  local row_sec = R.TimeMap2_QNToTime(0, qn0 + 1 / lpb) - pos      -- длина строки у старта
  local rows = math.max(1e-6, len / row_sec)
  local tlen = len * rate                                           -- длина в секундах источника
  local need_pitch, need_vol = false, false
  for _, c in ipairs(list) do
    if c.cmd == 'U' or c.cmd == 'D' or c.cmd == 'G' or c.cmd == '4' or c.cmd == '0' then need_pitch = true end
    if c.cmd == 'A' then need_vol = true end
  end
  if is_midi then
    -- MIDI: только U/D через pitchbend (±2 полутона = 8191)
    local _, _, ncc = R.MIDI_CountEvts(take)
    for i = ncc - 1, 0, -1 do
      local _, _, _, ppq, typ = R.MIDI_GetCC(take, i)
      if typ == 0xE0 then
        local tt = R.MIDI_GetProjTimeFromPPQPos(take, ppq)
        if tt >= pos - 1e-6 and tt <= pos + len + 1e-6 then R.MIDI_DeleteCC(take, i) end
      end
    end
    for _, c in ipairs(list) do
      if c.cmd == 'U' or c.cmd == 'D' then
        local semis = (c.xx / 16) * rows * (c.cmd == 'U' and 1 or -1)
        local bend = math.max(0, math.min(16383, math.floor(8192 + semis / 2 * 8191 + 0.5)))
        local p0 = R.MIDI_GetPPQPosFromProjTime(take, pos)
        local p1 = R.MIDI_GetPPQPosFromProjTime(take, pos + len)
        R.MIDI_InsertCC(take, false, false, p0, 0xE0, head.ch or 0, 0, 64)
        R.MIDI_InsertCC(take, false, false, p1, 0xE0, head.ch or 0, bend & 127, bend >> 7)
        local _, _, ncc2 = R.MIDI_CountEvts(take)
        for i = 0, ncc2 - 1 do
          local _, _, _, ppq, typ = R.MIDI_GetCC(take, i)
          if typ == 0xE0 and math.abs(ppq - p0) < 1 then R.MIDI_SetCCShape(take, i, 1, 0, true) end
        end
        R.MIDI_Sort(take)
      end
    end
    return
  end
  -- аудио: огибающие
  local penv = need_pitch and ensure_take_env(it, take, 'Pitch') or R.GetTakeEnvelopeByName(take, 'Pitch')
  local venv = need_vol and ensure_take_env(it, take, 'Volume') or R.GetTakeEnvelopeByName(take, 'Volume')
  if penv then clear_env(penv, it, take) end
  if venv then clear_env(venv, it, take) end
  local pmin, pmax = -3, 3
  if penv then pmin, pmax = env_range(penv, -3, 3) end
  local function clampp(v) return math.max(pmin, math.min(pmax, v)) end
  local vol_mul = 1
  local muted = false
  for _, c in ipairs(list) do
    if (c.cmd == 'U' or c.cmd == 'D') and penv then
      local total = (c.xx / 16) * rows * (c.cmd == 'U' and 1 or -1)
      pt(penv, 0, 0); pt(penv, tlen, clampp(total))
    elseif c.cmd == 'G' and penv then
      local from = (prev_semis or 0) - (head.semis or 0)
      local gl = math.min(tlen, math.max(1, c.xx) * row_sec * rate)
      pt(penv, 0, clampp(from)); pt(penv, gl, 0)
    elseif c.cmd == '4' and penv then
      local period = (c.x > 0 and 16 / c.x or 4) * row_sec * rate
      local depth = c.y / 8
      local n = math.max(2, math.floor(tlen / period * 8))
      for i = 0, n do
        local t = tlen * i / n
        pt(penv, t, clampp(depth * math.sin(2 * math.pi * t / period)))
      end
    elseif c.cmd == '0' and penv then
      local step = row_sec * rate / 3
      local vals = { 0, c.x, c.y }
      local i, t = 0, 0
      while t < tlen do pt(penv, t, clampp(vals[i % 3 + 1]), 1); i = i + 1; t = t + step end
    elseif c.cmd == 'A' and venv then
      local v1 = 1 + (c.x - c.y) / 16 * rows
      local vmin, vmax = env_range(venv, 0, 2)
      pt(venv, 0, 1); pt(venv, tlen, math.max(vmin, math.min(vmax, v1)))
    elseif c.cmd == 'R' then
      local every = (c.x > 0 and c.x or 4) / 16 * row_sec
      local decay = 1 - c.y / 16
      local ok, chunk = R.GetItemStateChunk(it, '', false)
      if ok and every > 1e-4 then
        chunk = strip_guids(chunk)
        local k, t = 1, pos + every
        while t < pos + len - 1e-6 and k < 64 do
          local copy = R.AddMediaItemToTrack(tr)
          R.SetItemStateChunk(copy, chunk, false)
          R.SetMediaItemInfo_Value(copy, 'D_POSITION', t)
          R.SetMediaItemInfo_Value(copy, 'D_LENGTH', math.min(every, pos + len - t))
          R.SetMediaItemInfo_Value(copy, 'D_VOL', R.GetMediaItemInfo_Value(it, 'D_VOL') * decay ^ k)
          if R.GetMediaTrackInfo_Value(tr, 'I_FREEMODE') == 2 then R.SetMediaItemInfo_Value(copy, 'I_FIXEDLANE', R.GetMediaItemInfo_Value(it, 'I_FIXEDLANE')) end
          R.GetSetMediaItemInfo_String(copy, 'P_EXT:jf_gen', guid, true)
          R.GetSetMediaItemInfo_String(copy, 'P_EXT:jf_cmds', '', true)
          k = k + 1; t = t + every
        end
        R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_len', ('%.6f'):format(len), true)
        R.SetMediaItemInfo_Value(it, 'D_LENGTH', math.min(len, every))
      end
    elseif c.cmd == 'P' then
      if math.random() > c.xx / 255 then muted = true end
    elseif c.cmd == 'F' then
      local bpm = c.xx > 0 and c.xx or 120
      R.SetTempoTimeSigMarker(0, -1, pos, -1, -1, bpm, 0, 0, false)
      R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_tempo', '1', true)
    end
  end
  if penv then R.Envelope_SortPoints(penv) end
  if venv then R.Envelope_SortPoints(venv) end
  local has_p = false
  for _, c in ipairs(list) do if c.cmd == 'P' then has_p = true end end
  if has_p then R.SetMediaItemInfo_Value(it, 'B_MUTE', muted and 1 or 0) end
end

return C
