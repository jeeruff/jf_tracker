-- jf_tracker_model.lua — снимок проекта REAPER в трекерных строках.
--
-- Единственный модуль трекера, который ЧИТАЕТ reaper.*. Не пишет ничего:
-- трекер — вид таймлайна, а не движок (см. README). Все reaper.* тут — Get*.
--
-- Модель строится по всему проекту в абсолютных строках (строка 0 = QN 0),
-- сетка задаётся LPB (строк на четверть). Вид потом берёт срез. Строка —
-- только масштаб отображения: смена LPB ничего в проекте не меняет.
--
-- Кеш: снимок пересобирается при смене GetProjectStateChangeCount, LPB или
-- хеша MIDI (MIDI_GetTrackHash по трекам, опрос 4 Гц: правка нот в
-- MIDI-редакторе не всегда двигает счётчик состояния проекта).
--
-- Регионы (этап 3): EnumProjectMarkers3 в 7.81 помечен discouraged —
-- брать GetNumRegionsOrMarkers / GetRegionOrMarker / GetSetRegionOrMarkerInfo_String.

local M = {}
local R = reaper

M.DEPOT = 'LIB'          -- 8 окт: библиотека — заглушённый трек LIB (fixed lanes: инструмент — свой лейн с нуля); в колонках не показываем
M.LIB_NAMES = { LIB = true, DEPOT = true }   -- DEPOT — старое имя того же трека
function M.is_lib_name(name) return M.LIB_NAMES[name or ''] == true end
M.BASE_NOTE = 60         -- «C-4 = оригинал»: MIDI 60 показываем как C-4
M.MAX_UNROLL = 256       -- предел разворота зацикленного MIDI-item (повторов)

-- ── ноты и числа ──────────────────────────────────────────────────────────
local NAMES = { 'C-', 'C#', 'D-', 'D#', 'E-', 'F-', 'F#', 'G-', 'G#', 'A-', 'A#', 'B-' }

-- имя ноты трекера от MIDI-номера: 60 → C-4, 61 → C#4, 48 → C-3
function M.note_name(n)
  n = math.floor(n + 0.5)
  -- научная нотация: 60 → 4; BASE_NOTE=60 даёт «C-4 = оригинал»
  local o = math.floor(n / 12) - 1
  if o < 0 then o = 0 elseif o > 9 then o = 9 end
  return NAMES[n % 12 + 1] .. tostring(o)
end

-- две hex-цифры, 0..255
function M.hex2(v)
  v = math.floor(v + 0.5)
  if v < 0 then v = 0 elseif v > 255 then v = 255 end
  return string.format('%02X', v)
end

-- строка и доля строки (xx/256) от позиции в QN
function M.row_of_qn(qn, lpb)
  local x = qn * lpb
  local row = math.floor(x + 1e-7)
  local frac = x - row
  if frac < 0 then frac = 0 end
  local d = math.floor(frac * 256 + 0.5)
  if d >= 256 then row, d = row + 1, 0 end
  return row, d
end

-- полутоны от аудио-take: pitch shift (D_PITCH) либо resample (rate при
-- выключенном preserve pitch). Оба сразу — суммируем, так и звучит.
function M.take_semitones(pitch, rate, ppitch)
  local s = pitch or 0
  if not ppitch and rate and rate > 0 and math.abs(rate - 1) > 1e-9 then
    s = s + 12 * math.log(rate, 2)
  end
  return s
end

-- громкость take*item (линейная) → hex, 0x80 = 0 dB (как в Renoise)
function M.vol_hex(vol)
  return M.hex2((vol or 1) * 128)
end

-- ── разбор MIDI ───────────────────────────────────────────────────────────
-- Поток MIDI_GetAllEvts: события подряд, каждое <offset:i4><flag:u8><msg:s4>,
-- offset — в PPQ от предыдущего события. flag &1 selected, &2 muted.
-- Возвращает ноты {ppq, ppq_end, pitch, vel, ch, muted} в порядке потока.
function M.parse_midi(buf)
  local notes, active = {}, {}
  local pos, ppq = 1, 0
  local n = #buf
  while pos <= n do
    local ok, offset, flag, msg, np = pcall(string.unpack, '<i4Bs4', buf, pos)
    if not ok then break end
    pos = np
    ppq = ppq + offset
    if #msg >= 3 then
      local b1 = msg:byte(1)
      local st, ch = b1 & 0xF0, b1 & 0x0F
      local pitch, vel = msg:byte(2), msg:byte(3)
      local key = ch * 128 + pitch
      if st == 0x90 and vel > 0 then
        -- две ноты одной высоты на одном канале одновременно невозможны:
        -- повторный note-on закрывает предыдущую
        local a = active[key]
        if a then a.ppq_end = ppq; notes[#notes + 1] = a end
        active[key] = { ppq = ppq, pitch = pitch, vel = vel, ch = ch, muted = (flag & 2) == 2 }
      elseif st == 0x80 or (st == 0x90 and vel == 0) then
        local a = active[key]
        if a then a.ppq_end = ppq; notes[#notes + 1] = a; active[key] = nil end
      end
    end
  end
  for _, a in pairs(active) do a.ppq_end = ppq; notes[#notes + 1] = a end
  table.sort(notes, function(a, b)
    if a.ppq ~= b.ppq then return a.ppq < b.ppq end
    return a.pitch < b.pitch
  end)
  return notes
end

-- ── раскладка по подколонкам ──────────────────────────────────────────────
-- Lane = список подколонок (sub); sub = карта строка → ячейка. Нота занимает
-- строки [r0, r1] в первой подколонке, где они свободны. Это и полифония
-- MIDI, и перекрывающиеся items на одном треке — один механизм.
local function sub_free(sub, r0, r1)
  for r = r0, r1 do if sub[r] then return false end end
  return true
end

local function place(lane, r0, r1, head, cont, tail)
  if r1 < r0 then r1 = r0 end
  local sub
  for _, s in ipairs(lane.subs) do
    if sub_free(s, r0, r1) then sub = s; break end
  end
  if not sub then sub = {}; lane.subs[#lane.subs + 1] = sub end
  sub[r0] = head
  for r = r0 + 1, r1 - 1 do sub[r] = { kind = 'cont', of = head, i = r - r0 } end
  if r1 > r0 then sub[r1] = tail or { kind = 'cont', of = head, i = r1 - r0 } end
  head.rows = r1 - r0 + 1
  if lane.last_row == nil or r1 > lane.last_row then lane.last_row = r1 end
  for i, s in ipairs(lane.subs) do
    if s == sub then
      -- подколонка с аудио — полной ширины; только MIDI-ноты — узкая
      -- «нота + velocity» (2 окт: аккорд не раздувается в лейны)
      if head.kind == 'audio' then lane.audio_sub = lane.audio_sub or {}; lane.audio_sub[i] = true end
      return sub, i
    end
  end
  return sub
end
M._place = place

-- Колонки команд аудио-item (этап 5, пока только показ): буквы PT2/Renoise,
-- значения из свойств item/take, доли — от строки. Только не-дефолтные.
--   9xx offset (доля длины источника)   8xx pan (80 = центр)
--   Ixx / Oxx fade in/out (строки × 16, >20 мс)  L00 loop source ВЫКЛ   M0x канал
--   Sxx слайс (P_EXT:jf_slice)  Txx beatsync на xx строк  Pxx дробный питч
function M.audio_fx(it, take, src, lpb, qn0, qn1, pitch, rate, ppitch)
  local fx = {}
  if not take then return fx end
  local offs = R.GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS')
  -- слайс (P_EXT:jf_slice): Sxx = номер слайса в исходнике (3 окт) — инструмент
  -- один, номер у ноты общий, а какой кусок — эта команда
  local _, slk = R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_slice', '', false)
  slk = tonumber(slk)
  -- слайс (4 окт, вечер): номер — командой Sxx (hex, как в Renoise); нота — высота
  if slk then offs = 0; fx[#fx + 1] = 'S' .. M.hex2(slk) end
  if offs > 1e-6 and src then
    local slen = R.GetMediaSourceLength(src)
    -- смещение — Sxx, как в Renoise (3 окт; ввод 9xx тоже понимается): xx/256 источника
    if slen and slen > 0 then fx[#fx + 1] = 'S' .. M.hex2(offs / slen * 256) end
  end
  local pan = R.GetMediaItemTakeInfo_Value(take, 'D_PAN')
  if math.abs(pan) > 1e-6 then fx[#fx + 1] = '8' .. M.hex2((pan + 1) / 2 * 255) end
  local pos = R.GetMediaItemInfo_Value(it, 'D_POSITION')
  local len = R.GetMediaItemInfo_Value(it, 'D_LENGTH')
  -- штатные фейды REAPER (10 мс) — не команда, а шум: порог 20 мс
  local fi = R.GetMediaItemInfo_Value(it, 'D_FADEINLEN')
  if fi > 0.02 then fx[#fx + 1] = 'I' .. M.hex2((R.TimeMap2_timeToQN(0, pos + fi) - qn0) * lpb * 16) end
  local fo = R.GetMediaItemInfo_Value(it, 'D_FADEOUTLEN')
  if fo > 0.02 then fx[#fx + 1] = 'O' .. M.hex2((qn1 - R.TimeMap2_timeToQN(0, pos + len - fo)) * lpb * 16) end
  -- loop source в REAPER включён по умолчанию — показываем только ВЫКЛЮЧЕННЫЙ
  if R.GetMediaItemInfo_Value(it, 'B_LOOPSRC') ~= 1 then fx[#fx + 1] = 'L00' end
  local cm = R.GetMediaItemTakeInfo_Value(take, 'I_CHANMODE')
  if cm and cm ~= 0 then fx[#fx + 1] = 'M0' .. tostring(math.floor(cm)) end
  -- слайс (P_EXT:jf_slice) командой не показывается (2 окт): как в Renoise,
  -- ячейка — нота и номер инструмента, а у каждого слайса свой номер в пуле
  if not slk and ppitch and rate and math.abs(rate - 1) > 1e-9 then fx[#fx + 1] = 'T' .. M.hex2((qn1 - qn0) * lpb) end
  if pitch and math.abs(pitch - math.floor(pitch + 0.5)) > 0.01 then fx[#fx + 1] = 'P' .. M.hex2(128 + pitch) end
  -- команды-огибающие и генераторы (P_EXT:jf_cmds) — как записаны
  local _, cm = R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_cmds', '', false)
  if cm and cm ~= '' then for tok in cm:gmatch('[^,]+') do fx[#fx + 1] = tok end end
  return fx
end

-- Аудио-item: голова в строке старта, «|» до предпоследней строки конца.
-- Конец item, попавший ровно на границу строки, эту строку не занимает.
-- длина источника для периода лупа: секция (PCM_Source_GetSectionInfo), иначе файл
function M.src_period(src)
  if not src then return 0 end
  if R.PCM_Source_GetSectionInfo then
    local ok, _, slen = R.PCM_Source_GetSectionInfo(src)
    if ok and slen and slen > 0 then return slen end
  end
  return R.GetMediaSourceLength(M.online_src(src) or src) or 0
end

local function place_audio(lane, lpb, it, take, qn0, qn1)
  local r0, d0 = M.row_of_qn(qn0, lpb)
  local r1, d1 = M.row_of_qn(qn1, lpb)
  if d1 == 0 then r1 = r1 - 1 end
  local src = take and R.GetMediaItemTake_Source(take)
  local pitch = take and R.GetMediaItemTakeInfo_Value(take, 'D_PITCH') or 0
  local rate = take and R.GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE') or 1
  local ppitch = take and R.GetMediaItemTakeInfo_Value(take, 'B_PPITCH') == 1
  local semis = M.take_semitones(pitch, rate, ppitch)
  local vol = R.GetMediaItemInfo_Value(it, 'D_VOL') * (take and R.GetMediaItemTakeInfo_Value(take, 'D_VOL') or 1)
  local head = {
    kind = 'audio', item = it, take = take, src = src,
    name = take and R.GetTakeName(take) or '',
    -- слайс = нота (4 окт): слайс k — нота C-4 + k - 1, питч — командой Pxx
    -- нота = высота (4 окт, вечер): «слайс = нота» не давал показать питч
    -- слайса — номер слайса снова командой Sxx, нота — C-4 + полутона
    note = M.note_name(M.BASE_NOTE + semis),
    frac = math.abs(semis - math.floor(semis + 0.5)) > 0.01,   -- дробный питч
    semis = semis,
    vol = M.vol_hex(vol),
    delay = d0,
    muted = R.GetMediaItemInfo_Value(it, 'B_MUTE_ACTUAL') == 1,
    offs = take and R.GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS') or 0,
    rate = rate,
    len = R.GetMediaItemInfo_Value(it, 'D_LENGTH'),
    guid = R.BR_GetMediaItemGUID and R.BR_GetMediaItemGUID(it) or tostring(it),
    row0 = r0,
    rows_f = (qn1 - qn0) * lpb,          -- точная длина в строках (дробная) — волна строго в границах item
    smk = M.stretch_fracs(take, R.GetMediaItemInfo_Value(it, 'D_LENGTH')),   -- stretch-маркеры: доли длины item
    smap = nil, smap_sig = nil,          -- карта маркеров для волны (ниже)
    start_f = d0 / 256,                  -- дробное начало внутри первой строки
  }
  head.fx = M.audio_fx(it, take, src, lpb, qn0, qn1, pitch, rate, ppitch)
  head.rgb = M.item_rgb(it)
  -- видео-лейн (9 окт): видео-item — событие как аудио (фейды Ixx / Oxx
  -- REAPER применяет и к картинке), в поле ноты — VID
  if src and R.GetMediaSourceType then
    local ps = R.GetMediaSourceParent and R.GetMediaSourceParent(src) or nil
    head.video = R.GetMediaSourceType(ps or src, ''):upper():find('VIDEO', 1, true) ~= nil
  end
  head.smap, head.smap_sig = M.stretch_map(take)
  -- луп (B_LOOPSRC): период в строках и первая граница (offset укорачивает первый проход)
  if src and R.GetMediaItemInfo_Value(it, 'B_LOOPSRC') == 1 then
    local slen = M.src_period(src)
    local r = rate > 0 and rate or 1
    local per = slen / r
    local first = math.max(0, slen - head.offs) / r
    -- stretch-маркеры (5 окт): шов там, где источник доходит до конца по карте
    -- маркеров, а не длина / rate — иначе шов стоял ровно на такте, а в REAPER раньше
    if head.smap then
      local t_end = M.item_time_of_src(head.smap, slen / r)
      local t_beg = M.item_time_of_src(head.smap, head.offs / r)
      if t_end and t_beg and t_end > t_beg + 1e-4 then first = t_end; per = t_end - t_beg end
    end
    if per > 1e-4 and per < head.len - 1e-4 then
      local pos = R.GetMediaItemInfo_Value(it, 'D_POSITION')
      head.loop_rows = (R.TimeMap2_timeToQN(0, pos + per) - qn0) * lpb
      head.loop_first = (R.TimeMap2_timeToQN(0, pos + first) - qn0) * lpb
      head.loop_src = slen                     -- период в секундах источника (волна лупа — по модулю)
    end
  end
  do local _, g = R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_gen', '', false); head.gen = (g ~= nil and g ~= '') or nil end
  local _, si = place(lane, r0, r1, head)
  -- огибающая громкости take (5 окт): точки — значениями в колонке vol на
  -- строках продолжения (кроссфейд и ручные рампы видны числами, как в Renoise)
  local env = take and R.GetTakeEnvelopeByName(take, 'Volume')
  local npt = env and R.CountEnvelopePoints(env) or 0
  if npt > 0 then
    local sub = lane.subs[si]
    local pos = R.GetMediaItemInfo_Value(it, 'D_POSITION')
    local mode = R.GetEnvelopeScalingMode(env)
    local base = R.GetMediaItemInfo_Value(it, 'D_VOL') * R.GetMediaItemTakeInfo_Value(take, 'D_VOL')
    local r = rate > 0 and rate or 1
    for i = 0, npt - 1 do
      local _, t, v = R.GetEnvelopePoint(env, i)
      local row = M.row_of_qn(R.TimeMap2_timeToQN(0, pos + t / r), lpb)
      local cell = sub and sub[row]
      -- 9 окт: служебные точки x-fade (пара точек у самого края item: громкость
      -- и ноль) не показываются: «00» / «80» мешали и сбивали w / y3w
      local tl, ilen = t / r, R.GetMediaItemInfo_Value(it, 'D_LENGTH')
      local edge_zero = tl <= 0.06 or tl >= ilen - 0.06   -- точки x-fade — у самого края item (≤ 60 мс)
      if cell and cell.kind == 'cont' and cell.of == head and not edge_zero then
        cell.vol = M.vol_hex(base * R.ScaleFromEnvelopeMode(mode, v))
      end
    end
  end
  return si, head
end

-- MIDI-item: ноты take → ячейки. Зацикленный item (B_LOOPSRC) разворачиваем:
-- ноты повторяются через длину источника (в QN), пока не кончится item.
local function place_midi(lane, lpb, it, take, qn0, qn1, midi_cache)
  local guid = R.BR_GetMediaItemTakeGUID and R.BR_GetMediaItemTakeGUID(take) or tostring(take)
  local _, hash = R.MIDI_GetHash(take, false, '')
  local key = guid .. '|' .. tostring(hash)
  local notes = midi_cache[key]
  if not notes then
    local ok, buf = R.MIDI_GetAllEvts(take, '')
    notes = ok and M.parse_midi(buf) or {}
    -- позиции нот — сразу в QN проекта (учитывает позицию item и offset)
    for _, nt in ipairs(notes) do
      nt.qn = R.MIDI_GetProjQNFromPPQPos(take, nt.ppq)
      nt.qn_end = R.MIDI_GetProjQNFromPPQPos(take, nt.ppq_end)
    end
    midi_cache[key] = notes
  end
  local loop = R.GetMediaItemInfo_Value(it, 'B_LOOPSRC') == 1
  local period = 0
  if loop then
    local src = R.GetMediaItemTake_Source(take)
    local len, is_qn = R.GetMediaSourceLength(src)
    if is_qn then period = len
    else period = R.TimeMap2_timeToQN(0, R.TimeMap2_QNToTime(0, qn0) + len) - qn0 end
  end
  local reps = 1
  if loop and period > 1e-6 then
    reps = math.min(M.MAX_UNROLL, math.ceil((qn1 - qn0) / period))
  end
  local muted_item = R.GetMediaItemInfo_Value(it, 'B_MUTE_ACTUAL') == 1
  local midi_fx = {}
  do
    local _, cm = R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_cmds', '', false)
    if cm and cm ~= '' then for tok in cm:gmatch('[^,]+') do midi_fx[#midi_fx + 1] = tok end end
  end
  for k = 0, reps - 1 do
    local shift = k * period
    for _, nt in ipairs(notes) do
      local a, b = nt.qn + shift, nt.qn_end + shift
      -- нота должна начинаться внутри item; хвост режется по концу item
      if a >= qn0 - 1e-7 and a < qn1 - 1e-7 then
        if b > qn1 then b = qn1 end
        local r0, d0 = M.row_of_qn(a, lpb)
        local r1, d1 = M.row_of_qn(b, lpb)
        local head = {
          kind = 'midi', item = it, take = take,
          note = M.note_name(nt.pitch), pitch = nt.pitch, semis = nt.pitch - M.BASE_NOTE,
          vol = M.hex2(nt.vel), delay = d0, ch = nt.ch,
          muted = muted_item or nt.muted, row0 = r0, fx = midi_fx,
        }
        local tail = { kind = 'off', of = head, delay = d1 }
        -- note-off ровно на границе строки — OFF стоит в этой строке с delay 0;
        -- если конец в той же строке, что и начало, OFF не помещается: нота
        -- короче строки, показываем только голову
        -- 8 окт: опция «OFF в конце строки» (M.OFF_END): конец ровно на
        -- границе строки r1 — OFF в последней звучащей строке r1 - 1 (нота
        -- звучит и на ней); строка r1 свободна для следующей ноты — короче на строку
        if M.OFF_END and d1 == 0 and r1 > r0 then r1 = r1 - 1 end
        if r1 <= r0 then place(lane, r0, r0, head) else place(lane, r0, r1, head, nil, tail) end
      end
    end
  end
end

-- ── снимок ────────────────────────────────────────────────────────────────
local cache = { key = nil, snap = nil, midi = {}, hash_t = 0, hashes = '' }
local rcache = { key = nil, list = {} }   -- регионы (см. M.regions)

local function midi_hashes()
  local parts = {}
  for ti = 0, R.CountTracks(0) - 1 do
    local tr = R.GetTrack(0, ti)
    local ok, h = R.MIDI_GetTrackHash(tr, true, '')
    parts[#parts + 1] = ok and h or ''
  end
  return table.concat(parts, ',')
end

-- Ключ кеша: state count + LPB + хеши MIDI (опрос не чаще 4 Гц).
function M.cache_key(lpb, now)
  now = now or R.time_precise()
  if now - cache.hash_t > 0.25 then
    cache.hashes = midi_hashes()
    cache.hash_t = now
  end
  return string.format('%d|%d|%s', R.GetProjectStateChangeCount(0), lpb, cache.hashes)
end

local pool_by_item = {}        -- item → gkey (все items, не только первый) — номер инструмента в ячейке
M.bprof = { envs = 0, pool = 0, mods = 0, fx = 0 }
function M.build(lpb)
  M.bprof = { envs = 0, pool = 0, mods = 0, fx = 0 }
  pool_by_item = {}
  local snap = { lpb = lpb, cols = {}, last_row = 0 }
  local depot_tr
  for ti = 0, R.CountTracks(0) - 1 do
    local tr = R.GetTrack(0, ti)
    local _, name = R.GetTrackName(tr)
    if M.is_lib_name(name) then depot_tr = tr end
  end
  snap.depot = depot_tr
  snap.lib_pos = nil                       -- 8 окт: маркера =LIB больше нет
  snap.end_pos = M.marker_pos(M.END_MARKER)
  snap.zone = M.session_zone()                -- зона сессии (7 окт): её items — не библиотека
  -- мастер: для вкладки master (скоп слот 31, цепь FX)
  if R.GetMasterTrack then
    local mt = R.GetMasterTrack(0)
    local ms = { track = mt, fx = M.track_fx(mt) }
    -- 9 окт: полоса master в нижнем микшере — те же поля, что у трека
    ms.guid, ms.name, ms.lanes, ms.depth = 'master', 'master', {}, 0
    ms.vol, ms.pan = R.GetMediaTrackInfo_Value(mt, 'D_VOL'), R.GetMediaTrackInfo_Value(mt, 'D_PAN')
    ms.width, ms.panmode = R.GetMediaTrackInfo_Value(mt, 'D_WIDTH'), math.floor(R.GetMediaTrackInfo_Value(mt, 'I_PANMODE'))
    ms.panL, ms.panR = R.GetMediaTrackInfo_Value(mt, 'D_DUALPANL'), R.GetMediaTrackInfo_Value(mt, 'D_DUALPANR')
    ms.muted = R.GetMediaTrackInfo_Value(mt, 'B_MUTE') == 1
    local sfx = R.TrackFX_GetByName and R.TrackFX_GetByName(mt, 'jf_tracker_scope', false)
    if sfx and sfx >= 0 then ms.scope_slot = math.floor(R.TrackFX_GetParam(mt, sfx, 0)) end
    snap.master = ms
  end
  for ti = 0, R.CountTracks(0) - 1 do
    local tr = R.GetTrack(0, ti)
    local _, name = R.GetTrackName(tr)
    if not M.is_lib_name(name) then
      local freemode = R.GetMediaTrackInfo_Value(tr, 'I_FREEMODE')
      local fixed = freemode == 2
      local color = R.GetTrackColor(tr)
      local col = { track = tr, name = name, color = color, lanes = {}, fixed = fixed,
                    muted = R.GetMediaTrackInfo_Value(tr, 'B_MUTE') == 1, guid = M.track_guid(tr),
                    solo = R.GetMediaTrackInfo_Value(tr, 'I_SOLO') > 0,
                    phase = R.GetMediaTrackInfo_Value(tr, 'B_PHASE') == 1,   -- ø в шапке (8 окт)
                    sel = R.IsTrackSelected and R.IsTrackSelected(tr) or false,                       -- выделен в REAPER (Option+цифра, цели f на фейдере)
                    armed = R.GetMediaTrackInfo_Value(tr, 'I_RECARM') == 1,
                    vol = R.GetMediaTrackInfo_Value(tr, 'D_VOL'), pan = R.GetMediaTrackInfo_Value(tr, 'D_PAN'),
                    width = R.GetMediaTrackInfo_Value(tr, 'D_WIDTH'), panmode = math.floor(R.GetMediaTrackInfo_Value(tr, 'I_PANMODE')),
                    panL = R.GetMediaTrackInfo_Value(tr, 'D_DUALPANL'), panR = R.GetMediaTrackInfo_Value(tr, 'D_DUALPANR'),
                    recmon = math.floor(R.GetMediaTrackInfo_Value(tr, 'I_RECMON')),   -- 0 выкл, 1 вкл, 2 авто (tape)
                    folder = R.GetMediaTrackInfo_Value(tr, 'I_FOLDERDEPTH') == 1,
                    depth = R.GetTrackDepth and R.GetTrackDepth(tr) or 0 }
      -- цвет трека в RGB для полоски под заголовком (0 = цвета нет)
      if color ~= 0 and R.ColorFromNative then
        local r, g, b = R.ColorFromNative(color & 0xFFFFFF)
        col.rgb = { r / 255, g / 255, b / 255 }
      end
      local nl = 1
      if fixed then nl = math.max(1, math.floor(R.GetMediaTrackInfo_Value(tr, 'I_NUMFIXEDLANES'))) end
      for l = 0, nl - 1 do
        local lname = ''
        if fixed then
          local ok, s = R.GetSetMediaTrackInfo_String(tr, 'P_LANENAME:' .. l, '', false)
          if ok then lname = s end
        end
        col.lanes[l + 1] = { idx = l, name = lname, subs = { {} }, items = {} }
      end
      for ii = 0, R.CountTrackMediaItems(tr) - 1 do
        local it = R.GetTrackMediaItem(tr, ii)
        local lane_i = fixed and math.floor(R.GetMediaItemInfo_Value(it, 'I_FIXEDLANE')) or 0
        local lane = col.lanes[lane_i + 1]
        -- items на невидимой lane (C_LANEPLAYS = -1) в колонки не попадают;
        -- items за маркером =END (склад сэмплов, =LIB) трекер не показывает (2 окт)
        if lane and snap.end_pos then
          local ip = R.GetMediaItemInfo_Value(it, 'D_POSITION')
          -- зона сессии видна, когда сессия играет (M.SHOW_ZONE, 7 окт): каждый канал — свой клип
          local in_zone = M.SHOW_ZONE and snap.zone and ip >= snap.zone[1] - 1e-6 and ip < snap.zone[2] - 1e-6
          if ip >= snap.end_pos - 1e-6 and not in_zone then lane = nil end
        end
        if lane then
          local pos = R.GetMediaItemInfo_Value(it, 'D_POSITION')
          local len = R.GetMediaItemInfo_Value(it, 'D_LENGTH')
          local qn0 = R.TimeMap2_timeToQN(0, pos)
          local qn1 = R.TimeMap2_timeToQN(0, pos + len)
          local take = R.GetActiveTake(it)
          local midi = take and R.TakeIsMIDI(take) or false
          local si, ahead, loop_rows
          if midi then
            place_midi(lane, lpb, it, take, qn0, qn1, cache.midi)
            -- период MIDI-лупа = длина источника (в QN) → строки
            if R.GetMediaItemInfo_Value(it, 'B_LOOPSRC') == 1 then
              local src = R.GetMediaItemTake_Source(take)
              local slen, is_qn = R.GetMediaSourceLength(src)
              local per = is_qn and slen or (R.TimeMap2_timeToQN(0, pos + (slen or 0)) - qn0)
              if per and per > 1e-6 and per < (qn1 - qn0) - 1e-6 then loop_rows = per * lpb end
            end
          else
            si, ahead = place_audio(lane, lpb, it, take, qn0, qn1)
            loop_rows = ahead and ahead.loop_rows
          end
          -- рамка item в колонке: дробные строки начала/конца; аудио — в
          -- своей подколонке (si), MIDI — на всю lane (ноты внутри)
          lane.items[#lane.items + 1] = {
            item = it, r0 = qn0 * lpb, r1 = qn1 * lpb, midi = midi, si = si, loop_rows = loop_rows,
            loop_first = (not midi) and ahead and ahead.loop_first or nil,      -- первый стык от начала item (строки)
            rgb = M.item_rgb(it),
            sel = R.IsMediaItemSelected and R.IsMediaItemSelected(it) or false,
            muted = R.GetMediaItemInfo_Value(it, 'B_MUTE_ACTUAL') == 1,
          }
        end
      end
      for _, lane in ipairs(col.lanes) do
        if lane.last_row and lane.last_row > snap.last_row then snap.last_row = lane.last_row end
      end
      -- части пересборки — в M.bprof (пульс hb: что дорого на большом проекте)
      local t0 = R.time_precise()
      col.envs = M.track_envs(tr, lpb)
      col.mlanes = M.track_midilanes(tr, lpb, col.guid)   -- MIDI-лейны: CC / PC / артикуляции / SysEx (6 окт)
      local t1 = R.time_precise()
      col.pool = M.track_pool(tr, depot_tr, nil, snap.end_pos, snap.zone, col.guid, #snap.cols == 0)
      local t2 = R.time_precise()
      col.mods = M.track_mods(tr)
      local t3 = R.time_precise()
      col.fx = M.track_fx(tr)
      local t4 = R.time_precise()
      M.bprof.envs = M.bprof.envs + (t1 - t0); M.bprof.pool = M.bprof.pool + (t2 - t1)
      M.bprof.mods = M.bprof.mods + (t3 - t2); M.bprof.fx = M.bprof.fx + (t4 - t3)
      -- мост осциллоскопа (JSFX jf_tracker_scope): слот из slider1
      local sfx = R.TrackFX_GetByName and R.TrackFX_GetByName(tr, 'jf_tracker_scope', false)
      if sfx and sfx >= 0 then col.scope_slot = math.floor(R.TrackFX_GetParam(tr, sfx, 0)) end
      -- ретро-буфер jf_rec (экосистема jf_grid): слот = slider2
      local rfx = R.TrackFX_GetByName and R.TrackFX_GetByName(tr, 'jf_rec', false)
      if rfx and rfx >= 0 then col.rec_slot = math.floor(R.TrackFX_GetParam(tr, rfx, 1)); col.rec_fx = rfx end
      snap.cols[#snap.cols + 1] = col
    end
  end
  -- ОБЩИЙ пул инструментов (как список инструментов Renoise 3): уникальные
  -- источники всех треков + библиотека; entry.tracks — где используется
  -- (кроме библиотеки). Каждый col.pool указывает на этот же список, так что
  -- номер инструмента один для всех треков.
  local all, seen = {}, {}
  for _, col in ipairs(snap.cols) do
    for _, e in ipairs(col.pool or {}) do
      local g = seen[e.gkey]
      if not g then g = e; g.tracks = {}; g.track_set = {}; g.home = col.name; seen[e.gkey] = g; all[#all + 1] = g end
      if not e.depot and not g.track_set[col.name] then g.track_set[col.name] = true; g.tracks[#g.tracks + 1] = col.name end
    end
  end
  -- родитель: более длинный инструмент того же файла, покрывающий этот
  -- диапазон источника (слайс/кусок → исходник). Предпочтение — нарезанному,
  -- затем самому длинному. Цепочки сворачиваются к корню.
  for i, e in ipairs(all) do e._i = i end
  for _, e in ipairs(all) do
    local best, blen
    local e0, e1 = e.offs, e.offs + e.len * e.rate
    for _, p in ipairs(all) do
      if p ~= e and p.fpath ~= '' and p.fpath == e.fpath then
        local p0, p1 = p.offs, p.offs + p.len * p.rate
        if p0 <= e0 + 1e-4 and p1 >= e1 - 1e-4 and (p1 - p0) > (e1 - e0) + 1e-3 then
          local better = not best or ((p.slices ~= nil) and (best.slices == nil)) or (((p.slices ~= nil) == (best.slices ~= nil)) and (p1 - p0) > blen)
          if better then best, blen = p, p1 - p0 end
        end
      end
    end
    e.parent = best
  end
  for _, e in ipairs(all) do
    local p = e.parent
    while p and p.parent and p.parent ~= e do p = p.parent end
    e.parent = p
    e.slice_k = nil
    if p and p.slices then
      local t0 = (e.offs - p.offs) / (p.rate ~= 0 and p.rate or 1)
      for k, st in ipairs(p.slices) do if math.abs(st - t0) < 0.01 then e.slice_k = k end end
      if not e.slice_k and t0 < 0.01 then e.slice_k = 0 end   -- начало сэмпла до первого слайса
    end
  end
  -- порядок номеров = дерево (2 окт, как список сэмплов Renoise): по трекам
  -- в порядке колонок; на треке — исходные сэмплы (корни, где лежат —
  -- хоть в библиотеке за =LIB), под каждым его слайсы/куски
  local kids = {}
  for _, e in ipairs(all) do
    if e.parent then kids[e.parent] = kids[e.parent] or {}; table.insert(kids[e.parent], e) end
  end
  for _, list in pairs(kids) do
    table.sort(list, function(x, y)
      local kx, ky = x.slice_k or 1e9, y.slice_k or 1e9
      if kx ~= ky then return kx < ky end
      if x.offs ~= y.offs then return x.offs < y.offs end
      return x._i < y._i
    end)
  end
  local ordered, placed = {}, {}
  local function put(e, depth)
    if placed[e] then return end
    placed[e] = true; e.depth = depth; ordered[#ordered + 1] = e
    for _, k in ipairs(kids[e] or {}) do put(k, 1) end
  end
  for _, col in ipairs(snap.cols) do
    for _, e in ipairs(all) do if not e.parent and e.home == col.name then put(e, 0) end end
  end
  for _, e in ipairs(all) do if not e.parent then put(e, 0) end end
  for _, e in ipairs(all) do put(e, e.parent and 1 or 0) end
  -- свой порядок исходников (3 окт): перетаскивание в lib пишет P_EXT:jf_ord
  -- на item исходника; без метки — после размеченных, в порядке дерева
  local any_ord = false
  for _, e in ipairs(ordered) do if not e.parent and e.ord then any_ord = true; break end end
  if any_ord then
    local roots = {}
    for k, e in ipairs(ordered) do if not e.parent then roots[#roots + 1] = { e = e, k = k } end end
    table.sort(roots, function(a, b)
      local oa, ob = a.e.ord or 1e9, b.e.ord or 1e9
      if oa ~= ob then return oa < ob end
      return a.k < b.k
    end)
    ordered, placed = {}, {}
    for _, r in ipairs(roots) do put(r.e, 0) end
    for _, e in ipairs(all) do put(e, e.parent and 1 or 0) end
  end
  all = ordered
  snap.pool = all
  for _, col in ipairs(snap.cols) do col.pool = all end
  -- номер инструмента по item (показывается в строке имени ячейки)
  local by_key = {}
  for i, e in ipairs(all) do by_key[e.gkey] = i end
  snap.inst_of = {}
  for it, key in pairs(pool_by_item) do snap.inst_of[it] = by_key[key] end
  -- номера инструментов (3 окт): только у исходных сэмплов (корней) — 01, 02…;
  -- слайс / кусок вложен в свой исходник и носит его номер (какой слайс —
  -- Sxx в колонке команд). В lib слайсы не показываются.
  local num = 0
  for _, e in ipairs(all) do if not e.parent then num = num + 1; e.num = num end end
  for _, e in ipairs(all) do if e.parent then e.num = e.parent.num end end
  snap.nroots = num
  snap.inst_num = {}
  for it, i in pairs(snap.inst_of) do snap.inst_num[it] = all[i] and all[i].num end
  -- нота относительно инструмента (6 окт): transpose инструмента (D_PITCH /
  -- rate его item в lib) — база, C-4 = как звучит инструмент; раньше нота
  -- была абсолютной и q / вставка играли без транспоза, а клик в lib — с ним
  snap.inst_semis = {}
  for i, e in ipairs(all) do snap.inst_semis[i] = M.take_semitones(e.pitch, e.rate, e.ppitch) end
  for _, col in ipairs(snap.cols) do
    for _, lane in ipairs(col.lanes) do
      for _, sub in ipairs(lane.subs) do
        for _, cell in pairs(sub) do
          if cell.kind == 'audio' and cell.item then
            local i = snap.inst_of[cell.item]
            local base = i and all[i] and all[i].item ~= cell.item and snap.inst_semis[i] or 0
            if base ~= 0 then
              cell.semis_abs = cell.semis
              cell.semis = cell.semis - base
              cell.note = M.note_name(M.BASE_NOTE + cell.semis)
              cell.frac = math.abs(cell.semis - math.floor(cell.semis + 0.5)) > 0.01
            end
          end
        end
      end
    end
  end
  return snap
end

-- Снимок с кешем. Возвращает snap, changed.
function M.snapshot(lpb)
  local key = M.cache_key(lpb)
  if cache.key == key and cache.snap then return cache.snap, false end
  cache.key = key
  cache.snap = M.build(lpb)
  return cache.snap, true
end

function M.invalidate() cache.key = nil; rcache.key = nil end

-- ── строки вида ───────────────────────────────────────────────────────────
-- Описания видимых строк: время, такт/доля. Считаем только для окна вида.
function M.rows(row0, n, lpb)
  local out = {}
  for i = 1, n do
    local row = row0 + i - 1
    local qn = row / lpb
    local t = R.TimeMap2_QNToTime(0, qn)
    local meas, qms = R.TimeMap_QNToMeasures(0, qn)
    local beat = math.abs(qn - math.floor(qn + 0.5)) < 1e-6
    local bar = beat and qms and math.abs(qn - qms) < 1e-6
    out[i] = { row = row, qn = qn, t = t, bar = row >= 0 and bar, beat = row >= 0 and beat, measure = meas,
               label = row >= 0 and string.format('%04d', row % 10000) or '' }   -- до начала (fixed cursor) — пусто
  end
  return out
end

-- Строка плейхеда/курсора от времени проекта (может быть дробной).
function M.row_of_time(t, lpb)
  return R.TimeMap2_timeToQN(0, t) * lpb
end

-- Границы такта, в котором лежит строка: первая строка такта и первая
-- строка следующего.
function M.bar_of_row(row, lpb)
  local qn = row / lpb
  local _, qms, qme = R.TimeMap_QNToMeasures(0, qn)
  if not qms or not qme or qme <= qms then return row, row + 4 * lpb end
  local r0 = M.row_of_qn(qms, lpb)
  local r1 = M.row_of_qn(qme, lpb)
  return r0, r1
end

function M.track_guid(tr)
  return R.GetTrackGUID and R.GetTrackGUID(tr) or tostring(tr)
end

-- ── цвет item ─────────────────────────────────────────────────────────────
-- Отображаемый цвет (свой или трека), как его рисует REAPER.
function M.item_rgb(it)
  -- 9 окт: item мог исчезнуть (Cmd+Z / удаление) раньше пересборки снимка — сетка
  -- клипов сессии спрашивала его цвет и роняла трекер
  if not (it and R.ValidatePtr and R.ValidatePtr(it, 'MediaItem*')) then return nil end
  local c = R.GetDisplayedMediaItemColor and R.GetDisplayedMediaItemColor(it) or 0
  if not c or c == 0 or not R.ColorFromNative then return nil end
  local r, g, b = R.ColorFromNative(c & 0xFFFFFF)
  return { r / 255, g / 255, b / 255 }
end

-- ── пул трека ─────────────────────────────────────────────────────────────
-- «Инструменты» для вставки на трек: items трека и депо, сгруппированные
-- в инструменты. Записи годятся для M.peaks (src/offs/len/rate/guid) —
-- превью в полоске над заголовком. Цифры 1..0 в INSERT выбирают слот.
--
-- Связь (3 окт): инструмент = метка P_EXT:jf_iid (её ставит каждая вставка
-- трекера: нота — id инструмента, слайс — id#k). Все items с одной меткой —
-- ОДИН инструмент, как бы их ни обрезали следующие ноты, какой бы питч или
-- громкость ни дали. Видоизменённая копия (растяжка, offset) получает новую
-- метку — становится уникальной (edit.make_unique). Items без метки (свои
-- или старые) — по файлу + имени + offset + rate, БЕЗ длины: обрезанный
-- кусок — тот же инструмент, а не новая «итерация».
-- Представитель инструмента — item из библиотеки, иначе самый длинный.
M.IID = 'P_EXT:jf_iid'
function M.iid(it)
  local _, v = R.GetSetMediaItemInfo_String(it, M.IID, '', false)
  return v or ''
end
local pool_add_entry                                   -- определена ниже pool_add
local function pool_key(it, take, name)
  local iid = M.iid(it)
  if iid ~= '' then return 'iid:' .. iid end
  local src = R.GetMediaItemTake_Source(take)
  local fn = src and R.GetMediaSourceFileName and R.GetMediaSourceFileName(src, '') or ''
  return string.format('%s|%s|%.3f|%.3f', tostring(fn), name,
    R.GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS'),
    R.GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE'))
end
M.pool_key = pool_key

local function pool_add(pool, seen, it, from_depot)
  local take = R.GetActiveTake(it)
  if not take then return end
  -- MIDI-клипы (9 окт): только из зоны lib / трека LIB — MIDI-item песни это
  -- контейнеры нот трекера, не инструменты; каждый клип — свой (без склейки)
  local midi = R.TakeIsMIDI(take)
  if midi and not from_depot then return end
  local name = R.GetTakeName(take)
  local key = midi and ('midi|' .. (R.BR_GetMediaItemGUID and R.BR_GetMediaItemGUID(it) or tostring(it))) or pool_key(it, take, name)
  pool_by_item[it] = key
  local len = R.GetMediaItemInfo_Value(it, 'D_LENGTH')
  local at = seen[key]
  if at then
    local cur = pool[at]
    cur.n = (cur.n or 1) + 1
    if not cur.ord then local _, o = R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_ord', '', false); cur.ord = tonumber(o) end
    -- представитель: библиотека, затем самый длинный (не обрезанная копия)
    local better = (from_depot and not cur.depot) or ((not from_depot) == (not cur.depot) and len > cur.len + 1e-6)
    if not better then return end
    local n = cur.n
    local ord = cur.ord
    pool[at] = nil
    pool_add_entry(pool, at, it, take, name, key, from_depot)
    pool[at].n = n
    pool[at].ord = pool[at].ord or ord
    return
  end
  seen[key] = #pool + 1
  pool_add_entry(pool, #pool + 1, it, take, name, key, from_depot)
end

pool_add_entry = function(pool, at, it, take, name, key, from_depot)
  local gkey = key
  local src0 = R.GetMediaItemTake_Source(take)
  -- тип источника (9 окт, сортировка lib по типу): video / audio (MIDI в lib не попадает)
  local ps = src0 and R.GetMediaSourceParent and R.GetMediaSourceParent(src0) or nil
  local stype = src0 and R.GetMediaSourceType and R.GetMediaSourceType(ps or src0, '') or ''
  pool[at] = {
    item = it, take = take, name = name, src = src0,
    stype = (R.TakeIsMIDI(take) and 'midi') or (stype:upper():find('VIDEO', 1, true) and 'video') or 'audio',
    ord = tonumber((select(2, R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_ord', '', false)))),   -- порядок в lib (3 окт, перетаскивание)
    offs = R.GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS'),
    len = R.GetMediaItemInfo_Value(it, 'D_LENGTH'),
    rate = R.GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE'),
    guid = R.BR_GetMediaItemGUID and R.BR_GetMediaItemGUID(it) or tostring(it),
    rgb = M.item_rgb(it), depot = from_depot,
    muted = R.GetMediaItemInfo_Value(it, 'B_MUTE') == 1,
    vol = R.GetMediaItemInfo_Value(it, 'D_VOL'),
    -- свойства для панели сэмпла (2 окт): всё нативное, item/take
    tpan = R.GetMediaItemTakeInfo_Value(take, 'D_PAN'),
    pitch = R.GetMediaItemTakeInfo_Value(take, 'D_PITCH'),
    ppitch = R.GetMediaItemTakeInfo_Value(take, 'B_PPITCH') == 1,
    pmode = math.floor(R.GetMediaItemTakeInfo_Value(take, 'I_PITCHMODE')),
    loop = R.GetMediaItemInfo_Value(it, 'B_LOOPSRC') == 1,
    fin = R.GetMediaItemInfo_Value(it, 'D_FADEINLEN'), fout = R.GetMediaItemInfo_Value(it, 'D_FADEOUTLEN'),
    nfx = R.TakeFX_GetCount and R.TakeFX_GetCount(take) or 0,
    fxnames = (function()
      local t = {}
      for k = 0, (R.TakeFX_GetCount and R.TakeFX_GetCount(take) or 0) - 1 do local _, nm = R.TakeFX_GetFXName(take, k, ''); t[#t + 1] = (nm or ''):gsub('^%w+: ', '') end
      return t
    end)(),
    -- путь файла источника (для поиска исходника слайса). НЕ `file`: это поле
    -- у редактора сэмпла значит «файл из браузера» (2 окт: ломало нарезку)
    fpath = (function() local s = R.GetMediaItemTake_Source(take); return s and R.GetMediaSourceFileName and R.GetMediaSourceFileName(s, '') or '' end)(),
    gkey = gkey,
  }
  -- мини-пиано-ролл MIDI-клипа в lib (9 окт): ноты долями длины item
  if pool[at].stype == 'midi' and R.MIDI_CountEvts then
    local _, nn = R.MIDI_CountEvts(take)
    local len = math.max(1e-6, pool[at].len)
    local pos = R.GetMediaItemInfo_Value(it, 'D_POSITION')
    local notes = {}
    for k = 0, math.min(nn, 512) - 1 do
      local _, _, _, sp, ep, _, p = R.MIDI_GetNote(take, k)
      local a = (R.MIDI_GetProjTimeFromPPQPos(take, sp) - pos) / len
      local b = (R.MIDI_GetProjTimeFromPPQPos(take, ep) - pos) / len
      notes[#notes + 1] = { a, b, p }
    end
    pool[at].notes = notes
  end
  -- виртуальная нарезка (jf_tracker_slicer): тайм-коды в P_EXT
  local _, sl = R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_slices', '', false)
  local _, bs = R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_bsync', '', false)
  if sl and sl ~= '' then
    local t = {}
    for v in sl:gmatch('[^,]+') do t[#t + 1] = tonumber(v) end
    -- 6 окт: привязка к волне — как E.item_slices: t · rate0 / rate текущий
    -- (beatsync — его rate0); старая нарезка без rate0 — оценка по длине
    local _, b = R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_slice_base', '', false)
    local _, l0, r0 = (b or ''):match('([^;]+);([^;]+);?([^;]*)')
    l0, r0 = tonumber(l0), tonumber(r0)
    local rn = tonumber(((bs or ''):match('^[^;]+;[^;]+;([^;]+)'))) or R.GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE')
    if not r0 and l0 and l0 > 0 then
      local ln = R.GetMediaItemInfo_Value(it, 'D_LENGTH')
      if math.abs(ln - l0) > 1e-3 then r0 = rn * ln / l0 end
    end
    local f = (r0 and rn > 1e-9) and (r0 / rn) or 1
    if math.abs(f - 1) > 1e-9 then for i = 1, #t do t[i] = t[i] * f end end
    pool[at].slices = t
  end
  -- beatsync: «N;span;rate0;pp0» (edit.bsync_set) — долей = первое поле (5 окт:
  -- tonumber всей строки давал nil, lib и свойства показывали off)
  pool[at].bsync = bs and tonumber(bs:match('^%s*([^;]+)')) or nil
  pool[at].iid = M.iid(it)
  do local _, pt = R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_playthru', '', false); pool[at].playthru = pt == '1' end   -- 6 окт
end

-- lib_pos — позиция маркера =LIB: items трека после него — его депо
-- (библиотека инструментов, помечены *). Трек DEPOT — наследие, тоже читается.
function M.marker_pos(name)
  if not R.CountProjectMarkers then return nil end
  local n = R.CountProjectMarkers(0)
  for i = 0, n - 1 do
    local _, isrgn, pos, _, nm = R.EnumProjectMarkers3(0, i)
    if not isrgn and nm == name then return pos end
  end
  return nil
end
function M.lib_pos() return M.marker_pos(M.LIB_MARKER) end
M.END_MARKER = '=END'
M.START_MARKER = '=START'

-- Пул трека: items до маркера =END (последовательность) и после =LIB
-- (библиотека). Всё между =END и =LIB — не читается (просьба 1 окт: путаница;
-- сэмплы библиотеки реально лежат на треках за =LIB).
function M.track_pool(tr, depot_tr, lib_pos, end_pos, zone, guid, first)
  local pool, seen = {}, {}
  for i = 0, R.CountTrackMediaItems(tr) - 1 do
    local it = R.GetTrackMediaItem(tr, i)
    local pos = R.GetMediaItemInfo_Value(it, 'D_POSITION')
    if zone and pos >= zone[1] - 1e-6 and pos < zone[2] - 1e-6 then goto skip_item end   -- копии клипов сессии — не инструменты
    local in_lib = lib_pos ~= nil and pos >= lib_pos - 1e-6 and (end_pos == nil or pos >= end_pos - 1e-6)
    local after_end = end_pos ~= nil and pos >= end_pos - 1e-6
    if in_lib or not after_end then pool_add(pool, seen, it, in_lib) end
    ::skip_item::
  end
  if depot_tr then
    -- 8 окт: семпл трека LIB — у трека-владельца (P_EXT:jf_home = GUID трека);
    -- без владельца — у первого трека
    for i = 0, R.CountTrackMediaItems(depot_tr) - 1 do
      local it = R.GetTrackMediaItem(depot_tr, i)
      local _, home = R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_home', '', false)
      if (home ~= '' and home == guid) or (home == '' and first) then pool_add(pool, seen, it, true) end
    end
  end
  return pool
end

-- ── модуляции параметров FX трека (нативные: LFO / ACS / plink) ──────────
-- TrackFX_GetNamedConfigParm 'param.N.mod.active' и т.д. Считается в
-- снимке (не каждый кадр); до 64 параметров на FX.
M.MOD_KEYS = { 'mod.baseline', 'lfo.active', 'lfo.shape', 'lfo.speed', 'lfo.temposync', 'lfo.strength',
  'acs.active', 'acs.attack', 'acs.release', 'acs.strength', 'plink.active', 'plink.effect', 'plink.param',
  'plink.scale', 'plink.offset' }
-- адреса всех FX трека, включая детей контейнеров (0x2000000…, v7.06+:
-- container_item.X) — модуляция нативна и на них (2 окт); prefix — путь имён
function M.fx_addresses(tr)
  local out = {}
  if not R.TrackFX_GetNamedConfigParm then return out end
  local function walk(id, prefix, depth)
    out[#out + 1] = { fx = id, prefix = prefix }
    local ok, n = R.TrackFX_GetNamedConfigParm(tr, id, 'container_count')
    if ok and depth < 4 then
      local _, nm = R.TrackFX_GetFXName(tr, id, '')
      local short = (nm or ''):gsub('^[^:]*: ', ''):sub(1, 8)
      for k = 0, (tonumber(n) or 0) - 1 do
        local ok2, cid = R.TrackFX_GetNamedConfigParm(tr, id, 'container_item.' .. k)
        cid = ok2 and tonumber(cid)
        if cid then walk(cid, prefix .. short .. '>', depth + 1) end
      end
    end
  end
  for fx = 0, R.TrackFX_GetCount(tr) - 1 do walk(fx, '', 0) end
  return out
end

function M.track_mods(tr)
  local out = {}
  if not R.TrackFX_GetNamedConfigParm then return out end
  for _, fa in ipairs(M.fx_addresses(tr)) do
    local fx = fa.fx
    local _, fxname = R.TrackFX_GetFXName(tr, fx, '')
    fxname = fa.prefix .. (fxname or ''):gsub('^[^:]*: ', '')
    local np = math.min(64, R.TrackFX_GetNumParams(tr, fx))
    for pi = 0, np - 1 do
      local ok, act = R.TrackFX_GetNamedConfigParm(tr, fx, ('param.%d.mod.active'):format(pi))
      if ok and act == '1' then
        local _, pname = R.TrackFX_GetParamName(tr, fx, pi, '')
        local function flag(k) local o, v = R.TrackFX_GetNamedConfigParm(tr, fx, ('param.%d.%s'):format(pi, k)); return o and v == '1' end
        local _, lfo_speed = R.TrackFX_GetNamedConfigParm(tr, fx, ('param.%d.lfo.speed'):format(pi))
        local _, plink_fx = R.TrackFX_GetNamedConfigParm(tr, fx, ('param.%d.plink.effect'):format(pi))
        local _, plink_par = R.TrackFX_GetNamedConfigParm(tr, fx, ('param.%d.plink.param'):format(pi))
        -- все числовые поля для модуляционной матрицы (m.v['lfo.speed'] …)
        local v = {}
        for _, k in ipairs(M.MOD_KEYS) do
          local o, sv = R.TrackFX_GetNamedConfigParm(tr, fx, ('param.%d.%s'):format(pi, k))
          if o then v[k] = tonumber(sv) end
        end
        local link_name
        if v['plink.active'] and v['plink.active'] >= 0.5 and v['plink.effect'] and v['plink.effect'] >= 0 then
          local _, sfx = R.TrackFX_GetFXName(tr, math.floor(v['plink.effect']), '')
          local _, spn = R.TrackFX_GetParamName(tr, math.floor(v['plink.effect']), math.floor(v['plink.param'] or 0), '')
          link_name = ((sfx or ''):gsub('^[^:]*: ', ''):sub(1, 6)) .. '.' .. (spn or '?')
        end
        out[#out + 1] = { fx = fx, fxname = (fxname or ''):gsub('^[^:]*: ', ''), param = pi, pname = pname or ('p' .. pi),
          lfo = flag('lfo.active'), acs = flag('acs.active'), plink = flag('plink.active'),
          lfo_speed = tonumber(lfo_speed), plink_fx = tonumber(plink_fx), plink_par = tonumber(plink_par),
          value = R.TrackFX_GetParamNormalized(tr, fx, pi), v = v, link_name = link_name }
      end
    end
  end
  return out
end

-- ── FX трека для нижней DSP-панели ────────────────────────────────────────
-- Имя, bypass, первые MAXP параметров: нормализованное значение и
-- форматированная строка. Считается в снимке; значения параметров живые —
-- M.fx_values(tr, fx, n) по запросу (кадр).
M.DSP_MAXP = 8
M.dspmods = nil      -- реестр кураторских модулей (jf_tracker_dspmods.lua), ставит main
-- ── адаптер FX (2 окт): цепочка трека или take одним кодом ────────────────
-- obj — MediaTrack* или MediaItem_Take*; M.fxapi(obj) даёт таблицу функций
-- TrackFX_* / TakeFX_* с общими именами (GetCount, GetFXName, …). Отличаются
-- только AddByName, огибающая и копирование — их разбирает edit.
local FXNAMES = { 'GetCount', 'GetFXName', 'GetNumParams', 'GetNamedConfigParm', 'GetEnabled', 'SetEnabled',
  'GetParamName', 'GetParameterStepSizes', 'GetParamEx', 'GetParamNormalized', 'SetParamNormalized',
  'GetFormattedParamValue', 'Show', 'Delete', 'GetFXGUID', 'GetOpen', 'GetParamFromIdent', 'SetNamedConfigParm' }   -- Set… (6 окт): parallel / имя в контейнере
local function fx_table(prefix)
  local t = { kind = prefix == 'TakeFX_' and 'take' or 'track' }
  for _, n in ipairs(FXNAMES) do t[n] = R[prefix .. n] end
  return t
end
M.FXT, M.FXK = fx_table('TrackFX_'), fx_table('TakeFX_')
function M.is_take(obj) return obj ~= nil and R.ValidatePtr ~= nil and R.ValidatePtr(obj, 'MediaItem_Take*') end
function M.fxapi(obj) if M.is_take(obj) then return M.FXK end return M.FXT end
-- цепочка take (те же записи, что у трека)
function M.take_fx(take) return M.track_fx(take) end

local function param_entry(tr, fx, pi, label)
  local A = M.fxapi(tr)
  local _, pname = A.GetParamName(tr, fx, pi, '')
  local kind, nsteps = 'slider', nil
  if A.GetParameterStepSizes then
    local ok, step, small, large, istoggle = A.GetParameterStepSizes(tr, fx, pi)
    if ok then
      if istoggle then kind = 'toggle'
      elseif step and step > 0 then
        local _, mn, mx = A.GetParamEx(tr, fx, pi)
        local n = (mx and mn) and math.floor((mx - mn) / step + 0.5) or 0
        if n >= 1 and n <= 16 then kind, nsteps = 'steps', n + 1 end
      end
    end
  end
  return { i = pi, name = label or pname or ('p' .. pi), kind = kind, nsteps = nsteps }
end

-- Контейнер (REAPER 7): дети по container_item.K (адреса 0x2000000+…, годятся
-- во все TrackFX_*), маршрутизация — parallel ребёнка (0 — за предыдущим,
-- 1 — параллельно ему, 2 — параллельно с суммированием). Параметры детей
-- собираются в один список с префиксом имени — виджеты и клавиши те же.
local function container_children(tr, fx)
  local A = M.fxapi(tr)
  local ok, n = A.GetNamedConfigParm(tr, fx, 'container_count')
  if not ok then return nil end
  n = tonumber(n) or 0
  local kids = {}
  for k = 0, n - 1 do
    local ok2, id = A.GetNamedConfigParm(tr, fx, 'container_item.' .. k)
    id = ok2 and tonumber(id)
    if id then
      local _, nm = A.GetFXName(tr, id, '')
      local _, par = A.GetNamedConfigParm(tr, id, 'parallel')
      local kid = { i = id, name = (nm or ''):gsub('^[^:]*: ', ''), enabled = A.GetEnabled(tr, id),
                    parallel = tonumber(par) or 0, np = A.GetNumParams(tr, id) }
      local ok3 = A.GetNamedConfigParm(tr, id, 'container_count')
      if ok3 then kid.container = true end
      kids[#kids + 1] = kid
    end
  end
  return kids
end

-- ── автомодуль (3 окт) ─────────────────────────────────────────────────────
-- Классификация один раз на тип плагина (имя + число параметров): имена,
-- шаги и текст значения (единицы) первых 512 параметров → FC.auto. Пользовательский
-- модуль (M.user_mods, learn касанием) — приоритетнее; кураторский реестр — тоже.
M.fxclass = nil            -- jf_tracker_fxclass.lua (ставит main)
M.user_mods = nil          -- пользовательские модули: имя FX → { title, cols, params = { {i, label} } }
local auto_cache = {}
local function param_kind(A, tr, fx, pi)
  local kind, nsteps = 'slider', nil
  if A.GetParameterStepSizes then
    local ok, step, small, large, istoggle = A.GetParameterStepSizes(tr, fx, pi)
    if ok then
      if istoggle then kind = 'toggle'
      elseif step and step > 0 then
        local _, mn, mx = A.GetParamEx(tr, fx, pi)
        local n = (mx and mn) and math.floor((mx - mn) / step + 0.5) or 0
        if n >= 1 and n <= 16 then kind, nsteps = 'steps', n + 1 end
      end
    end
  end
  return kind, nsteps
end
M.param_kind = param_kind
-- категория параметра (для цвета) — по имени и единицам, кэш по имени FX
local cat_cache = {}
function M.param_cat(tr, fx, short, pi, pname, kind)
  local key = short .. '|' .. pi
  local c = cat_cache[key]
  if c then return c end
  local A = M.fxapi(tr)
  local ok, units = A.GetFormattedParamValue(tr, fx, pi, '')
  c = M.fxclass and M.fxclass.class(pname or '', ok and units or '', kind) or nil
  cat_cache[key] = c or false
  return c
end
function M.auto_module(tr, fx, short, np)
  local key = short .. '|' .. np
  if auto_cache[key] then return auto_cache[key] end
  local A = M.fxapi(tr)
  local FC = M.fxclass
  local list = {}
  for pi = 0, math.min(np, 512) - 1 do
    local _, pname = A.GetParamName(tr, fx, pi, '')
    local kind, nsteps = param_kind(A, tr, fx, pi)
    local ok, units = A.GetFormattedParamValue(tr, fx, pi, '')
    list[#list + 1] = { i = pi, name = pname or ('p' .. pi), units = ok and units or '', kind = kind, nsteps = nsteps }
  end
  local out
  if FC then
    out = FC.auto(list, 42)            -- до 3 колонок по 14 строк; лишние колонки срежет отрисовка
    local byi = {}
    for _, p in ipairs(list) do byi[p.i] = p end
    for _, a in ipairs(out) do a.nsteps = byi[a.i] and byi[a.i].nsteps end
  else
    out = {}
    for k = 1, math.min(M.DSP_MAXP, #list) do local p = list[k]; out[k] = { i = p.i, name = p.name, kind = p.kind, nsteps = p.nsteps } end
  end
  auto_cache[key] = out
  return out
end
function M.auto_reset(short) M.fx_gen = M.fx_gen + 1; for k in pairs(auto_cache) do if not short or k:sub(1, #short + 1) == short .. '|' then auto_cache[k] = nil end end end

-- кэш цепочки (3 окт, скорость): пересборка снимка на каждую правку проекта
-- собирала FX заново (90 % времени); цепочка меняется редко — кэш по подписи:
-- число FX, их GUID и bypass, состав контейнеров, счётчик правок модулей
-- (M.fx_gen). Значения параметров читаются вживую каждый кадр (fx_values);
-- файл сэмплера (FILE0) обновляется при каждом обращении.
M.fx_gen = 0
local fx_cache = setmetatable({}, { __mode = 'k' })   -- 8 окт, замер: слабый ключ MediaTrack* живёт и после GC
local build_track_fx
function M.track_fx(tr)
  local A = M.fxapi(tr)
  if not A.GetCount then return {} end
  local n = A.GetCount(tr)
  local parts = { M.fx_gen, n }
  for fx = 0, n - 1 do
    parts[#parts + 1] = A.GetFXGUID and A.GetFXGUID(tr, fx) or fx
    parts[#parts + 1] = A.GetEnabled(tr, fx) and 1 or 0
    if A.GetNamedConfigParm then
      local ok, cc = A.GetNamedConfigParm(tr, fx, 'container_count')
      if ok then
        parts[#parts + 1] = 'c' .. tostring(cc)
        -- дети (6 окт): bypass / parallel / порядок видны в рамке — в ключ кэша
        for k = 0, (tonumber(cc) or 0) - 1 do
          local ok2, id = A.GetNamedConfigParm(tr, fx, 'container_item.' .. k)
          id = ok2 and tonumber(id)
          if id then
            local _, par = A.GetNamedConfigParm(tr, id, 'parallel')
            parts[#parts + 1] = (A.GetFXGUID and A.GetFXGUID(tr, id) or id) .. (A.GetEnabled(tr, id) and '+' or '-') .. (par or '')
          end
        end
      end
    end
  end
  local key = table.concat(parts, '|')
  local c = fx_cache[tr]
  if c and c.key == key then
    M.bprof.fxhit = (M.bprof.fxhit or 0) + 1
    for _, e in ipairs(c.out) do
      if e.wave and A.GetNamedConfigParm then
        local ok, file = A.GetNamedConfigParm(tr, e.i, 'FILE0')
        e.file = ok and file ~= '' and file or nil
      end
    end
    return c.out
  end
  local out = build_track_fx(tr)
  M.bprof.fxmiss = (M.bprof.fxmiss or 0) + 1
  fx_cache[tr] = { key = key, out = out }
  return out
end

-- один эффект по адресу fx (верхний уровень или ребёнок контейнера) → в out;
-- 6 окт: вынесено из цикла, чтобы дети контейнера строились тем же модулем
local build_one
function build_track_fx(tr)
  local out = {}
  local A = M.fxapi(tr)
  if not A.GetCount then return out end
  for fx = 0, A.GetCount(tr) - 1 do build_one(tr, fx, out) end
  return out
end
function build_one(tr, fx, out)
  local A = M.fxapi(tr)
  do
    local _, name = A.GetFXName(tr, fx, '')
    local np = A.GetNumParams(tr, fx)
    local params = {}
    local short = (name or ''):gsub('^[^:]*: ', '')
    local um = M.user_mods and M.user_mods[short]
    local lay = (not um) and M.dspmods and M.dspmods.match(short)
    local kids = A.GetNamedConfigParm and container_children(tr, fx)
    if kids then
      -- контейнер: сначала его макросы (нативные container_map — параметры
      -- детей, выведенные наружу; на них работает обычная модуляция), затем
      -- дети + их первые параметры (по 4 на ребёнка), 2 колонки
      for pi = 0, np - 1 do
        local _, pn = A.GetParamName(tr, fx, pi, '')
        if pn and pn ~= '' and pn ~= 'Bypass' and pn ~= 'Wet' and pn ~= 'Delta' then
          local e = param_entry(tr, fx, pi)
          e.name = 'M ' .. e.name
          e.macro = true
          params[#params + 1] = e
        end
      end
      -- 6 окт: дети — полным модулем (кураторский / свой / автомодуль), как на
      -- верхнем уровне; e.kid — колонка ребёнка в развёрнутой рамке
      local has_m = #params > 0
      for ki, kid in ipairs(kids) do
        local one = {}
        build_one(tr, kid.i, one)
        kid.entry = one[1]
        for _, e0 in ipairs(one[1] and one[1].params or {}) do
          local e = {}
          for k2, v2 in pairs(e0) do e[k2] = v2 end
          e.fx = e0.fx or kid.i      -- адрес ребёнка (внука — свой): fx_values / fx_param идут по нему
          e.kid = ki
          params[#params + 1] = e
        end
      end
      out[#out + 1] = { i = fx, name = short, enabled = A.GetEnabled(tr, fx), np = np, params = params,
                        cols = math.max(1, (has_m and 1 or 0) + #kids), container = true, kids = kids, has_macros = has_m }
    elseif um then
      -- пользовательский модуль (learn касанием): параметры по номерам
      for _, sp in ipairs(um.params or {}) do
        if sp.i < np then
          local e = param_entry(tr, fx, sp.i, sp.label)
          e.cat = M.param_cat(tr, fx, short, sp.i, e.name, e.kind)
          params[#params + 1] = e
        end
      end
      local ue = { i = fx, name = um.title or short, enabled = A.GetEnabled(tr, fx), np = np, params = params, cols = um.cols or 2, user = true, fxname = short }
      -- XY-пэд своего модуля (5 окт): оси — параметры плагина из learn (X / Y)
      if um.xy_x and um.xy_y then
        for k, e in ipairs(params) do if e.i == um.xy_x then ue.xy_x = k end; if e.i == um.xy_y then ue.xy_y = k end end
        if ue.xy_x and ue.xy_y then ue.xy = true; ue.cols = math.max(2, ue.cols) end   -- пэд — первая колонка, параметры — правее
      end
      out[#out + 1] = ue
    elseif lay then
      -- кураторский модуль: параметры по подстроке имени, в порядке реестра
      local names = {}
      for pi = 0, np - 1 do local _, pn = A.GetParamName(tr, fx, pi, ''); names[pi] = (pn or ''):lower() end
      local wa, wb, e_xy_x, e_xy_y, e_view_p
      -- ReaEQ (7 окт): полосы по именам параметров, в порядке появления
      local dyn = {}
      if lay.dyn_eq then
        local order, by = {}, {}
        for pi = 0, np - 1 do
          local _, raw = A.GetParamName(tr, fx, pi, '')
          local kind, band = (raw or ''):match('^(%a+)%-(.+)$')
          local bk = ({ Freq = 'f', Gain = 'g', BW = 'q' })[kind or '']
          if bk then
            if not by[band] then by[band] = {}; order[#order + 1] = band end
            by[band][bk] = pi
          end
        end
        for k, band in ipairs(order) do
          local lb = band:lower()
          local bt = lb:find('low shelf') and 'ls' or (lb:find('high shelf') and 'hs') or (lb:find('low pass') and 'lp') or (lb:find('high pass') and 'hp')
            or (lb:find('notch') and 'nt') or (lb:find('band pass') and 'bp') or 'pk'
          for _, bk in ipairs({ 'f', 'g', 'q' }) do
            local pi = by[band][bk]
            if pi then
              local e = param_entry(tr, fx, pi, k .. ' ' .. bk)
              e.band, e.bk, e.btype = k, bk, bt
              e.cat = M.param_cat(tr, fx, short, pi, names[pi], e.kind)
              params[#params + 1] = e
            end
          end
        end
        if #params > 0 then
          for pi = 0, np - 1 do if names[pi] == 'global gain' then params[#params + 1] = param_entry(tr, fx, pi, 'gain') end end
          dyn = { done = true }
        end
      end
      for _, spec in ipairs(dyn.done and {} or lay.params) do
        local want = spec[1]:lower()
        for pi = 0, np - 1 do
          -- exact (5 окт): имя целиком (Amigo: «Loop» иначе находит «Loop Start»)
          if (spec.exact and names[pi] == want) or (not spec.exact and names[pi]:find(want, 1, true)) then
            params[#params + 1] = param_entry(tr, fx, pi, spec[2])
            params[#params].cat = M.param_cat(tr, fx, short, pi, names[pi], params[#params].kind)
            params[#params].labels = spec.labels                     -- 9 окт: подписи положений (пульт slixer)
            if lay.wave and want == lay.wave.start then wa = #params end
            if lay.wave and want == lay.wave.stop then wb = #params end
            if lay.view_param and spec[2] == lay.view_param then e_view_p = #params end
            if lay.xy and want == lay.xy.x then e_xy_x = #params end
            if lay.xy and want == lay.xy.y then e_xy_y = #params end
            break
          end
        end
      end
      local e = { i = fx, name = lay.title or short, enabled = A.GetEnabled(tr, fx), np = np, params = params, cols = lay.cols or 1,
                  groups = lay.groups, rows = lay.rows }               -- 9 окт: колонка = группа с заголовком
      -- живой вид модуля (гранулятор): какой и какой параметр тянется по нему
      if lay.view then e.view, e.view_p = lay.view, e_view_p end
      -- XY-пэд (TG33 vector): индексы параметров X / Y
      if lay.xy and e_xy_x and e_xy_y then e.xy, e.xy_x, e.xy_y = true, e_xy_x, e_xy_y end
      -- волна сэмплера (RS5K): файл FILE0, индексы start / end в params
      if lay.wave and A.GetNamedConfigParm then
        local ok, file = A.GetNamedConfigParm(tr, fx, 'FILE0')
        e.wave, e.file, e.wave_a, e.wave_b = true, ok and file ~= '' and file or nil, wa, wb
      end
      out[#out + 1] = e
    else
      -- автомодуль (3 окт): любой эффект — параметры по категориям и
      -- подгруппам (jf_tracker_fxclass.lua), кэш на тип плагина
      local am = M.auto_module(tr, fx, short, np)
      for _, a in ipairs(am) do
        params[#params + 1] = { i = a.i, name = a.name, kind = a.kind, nsteps = a.nsteps, cat = a.cat, group = a.group }
      end
      local cols = math.max(1, math.min(3, math.ceil(#params / 8)))
      -- Airwindows (4 окт): имя без «(airwindows)» — по нему категория и описание (Airwindopedia)
      local aw = short:match('^(.-)%s*%([Aa]irwindows%)')
      out[#out + 1] = { i = fx, name = short, enabled = A.GetEnabled(tr, fx), np = np, params = params, cols = cols, auto = true, airwin = aw }
    end
  end
end

function M.fx_values(tr, f)
  local A = M.fxapi(tr)
  local v = {}
  for k, p in ipairs(f.params) do
    local id = p.fx or f.i
    local ok, str = A.GetFormattedParamValue(tr, id, p.i, '')
    v[k] = { n = A.GetParamNormalized(tr, id, p.i), s = ok and str or '' }
  end
  return v
end

-- ── огибающие трека (показ, вертикально) ──────────────────────────────────
-- Видимые и активные огибающие трека; диапазон — из BR_EnvGetProperties (SWS),
-- без SWS — 0..1 и все огибающие. Точки и значения не кешируются: считаются
-- только для видимых строк (M.env_values), это дёшево.
-- lpb — для automation items (дробные строки начала/конца, цвет темы env_item_*)
-- ключ темы огибающей — как у аранжировки (пары «Envelope: …» / ключ из
-- бинарника REAPER): громкость col_env2 (pre-FX col_env1), панорама col_env4
-- (pre-FX col_env3), ширина и громкость посыла col_env7, панорама посыла
-- col_env8, playrate / tempo мастера col_env5 / 6, параметры FX — по кругу
-- col_env13..16 (nfx — сколько FX-огибающих уже было на треке).
function M.env_key(name, nfx)
  local nm = (name or ''):lower()
  local pre = nm:find('pre%-fx') ~= nil
  if nm:find('/') then return 'col_env' .. (13 + (nfx or 0) % 4) end   -- «Параметр / FX»
  if nm:find('trim') then return 'env_trim_vol' end
  if nm:find('send') then
    if nm:find('mute') then return 'env_sends_mute' end
    if nm:find('pan') then return 'col_env8' end
    return 'col_env7'
  end
  if nm:find('volume') then return pre and 'col_env1' or 'col_env2' end
  if nm:find('pan') then return pre and 'col_env3' or 'col_env4' end
  if nm:find('width') then return 'col_env7' end
  if nm:find('mute') then return 'env_track_mute' end
  if nm:find('playrate') then return 'col_env5' end
  if nm:find('tempo') then return 'col_env6' end
  return 'col_env' .. (13 + (nfx or 0) % 4)
end

-- MIDI-лейны трека (6 окт): события MIDI items, не огибающие. Лейн — CC по
-- номеру, pc (program change), tx (текст / нотация REAPER: артикуляции), sx
-- (SysEx). ev[row] = { v = значение, text = подпись, n = событий в строке }.
-- M.extra_lanes[guid] = { 74, 'pc', … } — пустые лейны, добавленные :cc N / :pc
M.extra_lanes = {}
function M.track_midilanes(tr, lpb, guid)
  local by = {}
  local function lane(key, kind, num)
    local l = by[key]
    if not l then l = { key = key, kind = kind, num = num, ev = {} }; by[key] = l end
    return l
  end
  local function put(l, row, v, text)
    local e = l.ev[row]
    if e then e.n = e.n + 1; e.v = v; e.text = text or e.text else l.ev[row] = { v = v, text = text, n = 1 } end
  end
  for i = 0, R.CountTrackMediaItems(tr) - 1 do
    local it = R.GetTrackMediaItem(tr, i)
    local tk = R.GetActiveTake(it)
    if tk and R.TakeIsMIDI(tk) then
      local _, _, ccn, txn = R.MIDI_CountEvts(tk)
      for k = 0, (ccn or 0) - 1 do
        local _, _, _, ppq, chanmsg, _, m2, m3 = R.MIDI_GetCC(tk, k)
        local row = math.floor(M.row_of_time(R.MIDI_GetProjTimeFromPPQPos(tk, ppq), lpb) + 1e-6)
        if chanmsg == 0xB0 then put(lane('cc' .. m2, 'cc', m2), row, m3)
        elseif chanmsg == 0xC0 then put(lane('pc', 'pc'), row, m2) end
      end
      for k = 0, (txn or 0) - 1 do
        local _, _, _, ppq, typ, msg = R.MIDI_GetTextSysexEvt(tk, k)
        local row = math.floor(M.row_of_time(R.MIDI_GetProjTimeFromPPQPos(tk, ppq), lpb) + 1e-6)
        if typ == -1 then put(lane('sx', 'sx'), row, #(msg or ''), ('%02X'):format((msg or ''):byte(1) or 0))
        elseif typ and typ >= 1 then
          -- нотация REAPER: «NOTE ch pitch articulation staccato …» — слово после articulation
          local t = msg or ''
          t = t:match('articulation%s+(%S+)') or t:match('text%s+(%S+)') or t
          put(lane('tx', 'tx'), row, 0, t)
        end
      end
    end
  end
  for _, x in ipairs(M.extra_lanes[guid] or {}) do
    if type(x) == 'number' then lane('cc' .. x, 'cc', x) elseif x == 'pc' then lane('pc', 'pc') end
  end
  local out = {}
  for _, l in pairs(by) do out[#out + 1] = l end
  local ORD = { cc = 1, pc = 2, tx = 3, sx = 4 }
  table.sort(out, function(a, b) if ORD[a.kind] ~= ORD[b.kind] then return ORD[a.kind] < ORD[b.kind] end return (a.num or 0) < (b.num or 0) end)
  for _, l in ipairs(out) do
    l.name = l.kind == 'cc' and ('CC' .. l.num) or (l.kind == 'pc' and 'PC' or (l.kind == 'tx' and 'art' or 'SX'))
    l.rows = {}
    for r in pairs(l.ev) do l.rows[#l.rows + 1] = r end
    table.sort(l.rows)
  end
  return out
end

function M.track_envs(tr, lpb)
  local out = {}
  local nfx = 0
  if not R.CountTrackEnvelopes then return out end
  for i = 0, R.CountTrackEnvelopes(tr) - 1 do
    local env = R.GetTrackEnvelope(tr, i)
    local _, name = R.GetEnvelopeName(env, '')
    local vis, mn, mx = true, 0, 1
    if R.BR_EnvAlloc then
      local be = R.BR_EnvAlloc(env, false)
      if be then
        local active, visible, _, _, _, _, a, b = R.BR_EnvGetProperties(be)
        R.BR_EnvFree(be, false)
        vis = active and visible
        if a and b and b > a then mn, mx = a, b end
      end
    end
    if vis then
      -- цвет как в аранжировке: ключ темы по типу огибающей
      local nm = (name or ''):lower()
      local key = M.env_key(name, nfx)
      if key:match('^col_env1[3-6]$') then nfx = nfx + 1 end
      -- границы в шкале огибающей (6 окт): громкость фейдерная — сырые значения
      -- точек лежат в ней; амплитудные границы BR давали зигзаг там, где REAPER
      -- рисует плоско. amin / amax — исходные (амплитуда), для подписей
      local smode = R.GetEnvelopeScalingMode and R.GetEnvelopeScalingMode(env) or 0
      local smn, smx = mn, mx
      if smode ~= 0 then smn, smx = R.ScaleToEnvelopeMode(smode, mn), R.ScaleToEnvelopeMode(smode, mx) end
      local e = { env = env, name = name or '', min = smn, max = smx, amin = mn, amax = mx, smode = smode, key = key, idx = i, ais = {} }
      -- automation items: как в аранжировке — цвет темы по типу огибающей
      e.ai_key = (nm:find('volume') and 'env_item_vol') or (nm:find('pan') and 'env_item_pan')
                 or (nm:find('mute') and 'env_item_mute') or 'env_item_pitch'
      if lpb and R.CountAutomationItems then
        for k = 0, R.CountAutomationItems(env) - 1 do
          local pos = R.GetSetAutomationItemInfo(env, k, 'D_POSITION', 0, false)
          local len = R.GetSetAutomationItemInfo(env, k, 'D_LENGTH', 0, false)
          local ai = { r0 = R.TimeMap2_timeToQN(0, pos) * lpb, r1 = R.TimeMap2_timeToQN(0, pos + len) * lpb,
                       sel = R.GetSetAutomationItemInfo(env, k, 'D_UISEL', 0, false) ~= 0, idx = k, pos = pos, len = len }
          -- подпись как в аранжировке: «пул: имя огибающей» (или имя пула)
          local pid = math.floor((R.GetSetAutomationItemInfo(env, k, 'D_POOL_ID', 0, false) or 0) + 0.5)
          local pname = R.GetSetAutomationItemInfo_String and select(2, R.GetSetAutomationItemInfo_String(env, k, 'P_POOL_NAME', '', false)) or ''
          ai.label = (pname and pname ~= '') and pname or ('%d: %s'):format(pid + 1, name or '')
          -- луп (2 окт): стыки повторов пула — срезами, как в аранжировке
          if R.GetSetAutomationItemInfo(env, k, 'D_LOOPSRC', 0, false) ~= 0 then
            local pq = R.GetSetAutomationItemInfo(env, k, 'D_POOL_QNLEN', 0, false) or 0
            local rate = R.GetSetAutomationItemInfo(env, k, 'D_PLAYRATE', 0, false) or 1
            local offs = R.GetSetAutomationItemInfo(env, k, 'D_STARTOFFS', 0, false) or 0
            if pq > 1e-6 and rate > 1e-6 then
              ai.loop_rows = pq / rate * lpb
              local q0 = R.TimeMap2_timeToQN(0, pos)
              local offs_rows = (R.TimeMap2_timeToQN(0, pos + offs) - q0) * lpb
              ai.loop_first = ai.r0 + (ai.loop_rows - (offs_rows % ai.loop_rows))
            end
          end
          e.ais[#e.ais + 1] = ai
        end
      end
      out[#out + 1] = e
    end
  end
  return out
end

-- n равномерных отсчётов огибающей на [t0, t1) (0..1) — мини-автоматизация
-- в ячейке матрицы
function M.env_samples(e, t0, t1, n)
  local out = {}
  local span = e.max - e.min
  for i = 1, n do
    local _, raw = R.Envelope_Evaluate(e.env, t0 + (t1 - t0) * (i - 0.5) / n, 0, 0)
    local v = span > 0 and ((raw or 0) - e.min) / span or 0
    out[i] = math.max(0, math.min(1, v))
  end
  return out
end

-- значения огибающей по строкам вида: v 0..1, pt — в строке есть точка
M.ENV_SUB = 4   -- подточек на строку — линия без изломов
function M.env_values(e, rows)
  local out = {}
  local span = e.max - e.min
  local function norm(raw)
    local v = span > 0 and ((raw or 0) - e.min) / span or 0
    if v < 0 then v = 0 elseif v > 1 then v = 1 end
    return v
  end
  for i, r in ipairs(rows) do
    local _, raw = R.Envelope_Evaluate(e.env, r.t, 0, 0)
    local v = norm(raw)
    local nxt = rows[i + 1] and rows[i + 1].t or (r.t + (r.t - (rows[i - 1] and rows[i - 1].t or (r.t - 0.1))))
    local sub = {}
    for j = 1, M.ENV_SUB - 1 do
      local _, rv = R.Envelope_Evaluate(e.env, r.t + (nxt - r.t) * j / M.ENV_SUB, 0, 0)
      sub[j] = norm(rv)
    end
    local pt, shape = false, nil
    -- 6 окт: под automation item — точки его пула (все проходы лупа, как
    -- видны в аранжировке; опция aipoints), точки огибающей под ним скрыты
    local ai
    for _, a in ipairs(e.ais or {}) do
      if a.pos and r.t >= a.pos - 1e-9 and r.t < a.pos + a.len then ai = a end
    end
    if ai then
      if M.aipoints ~= false and R.GetEnvelopePointByTimeEx then
        local idx = R.GetEnvelopePointByTimeEx(e.env, ai.idx, nxt - 1e-6)
        if idx and idx >= 0 then
          local ok, pt_t, _, shp = R.GetEnvelopePointEx(e.env, ai.idx, idx)
          if ok and pt_t >= r.t - 1e-6 and pt_t < nxt - 1e-9 then pt = true; shape = shp end
        end
      end
    else
      local idx = R.GetEnvelopePointByTime(e.env, nxt - 1e-6)
      if idx and idx >= 0 then
        local ok, pt_t, _, shp = R.GetEnvelopePoint(e.env, idx)
        if ok and pt_t >= r.t - 1e-6 then pt = true; shape = shp end
      end
    end
    out[i] = { v = v, pt = pt, raw = raw, sub = sub, shape = shape }
  end
  return out
end

-- ── регионы (матрица паттернов) ───────────────────────────────────────────
-- EnumProjectMarkers3 в 7.81 помечен «discouraged» (новые: GetNumRegionsOrMarkers,
-- GetRegionOrMarker, GetSetRegionOrMarkerInfo_String), но сигнатуры новых в
-- строках бинарника нет — берём старую, она работает. Кеш по ключу снимка.
function M.regions(lpb)
  local key = string.format('%d|%d', R.GetProjectStateChangeCount(0), lpb)
  if rcache.key == key then return rcache.list end
  local out = {}
  local markers = {}      -- маркеры для линейки трекера (2 окт): имя, строка (дробная), цвет
  -- библиотека паттернов: всё после маркера =LIB не входит в последовательность
  local lib_pos, end_pos, start_pos
  local i = 0
  while true do
    local ret, isrgn, pos, _, name, idx, color = R.EnumProjectMarkers3(0, i)
    if not ret or ret == 0 then break end
    if not isrgn then
      if name == M.LIB_MARKER then lib_pos = pos end
      if name == M.END_MARKER then end_pos = pos end
      if name == M.START_MARKER and not start_pos then start_pos = pos end
      markers[#markers + 1] = { idx = idx, name = name or '', pos = pos, row_f = R.TimeMap2_timeToQN(0, pos) * lpb, color = color }
    end
    i = i + 1
  end
  i = 0
  while true do
    local ret, isrgn, pos, rgnend, name, idx, color = R.EnumProjectMarkers3(0, i)
    if not ret or ret == 0 then break end
    if isrgn then
      local qn0, qn1 = R.TimeMap2_timeToQN(0, pos), R.TimeMap2_timeToQN(0, rgnend)
      local r0 = M.row_of_qn(qn0, lpb)
      local r1 = M.row_of_qn(qn1, lpb)
      out[#out + 1] = { idx = idx, name = name or '', pos = pos, rgnend = rgnend,
                        qn0 = qn0, qn1 = qn1, r0 = r0, r1 = r1, color = color,
                        -- библиотека — после =LIB И после =END (2 окт: =LIB, поставленный
                        -- раньше =END, прятал регионы последовательности)
                        lib = end_pos ~= nil and pos >= end_pos - 1e-6 and name ~= '=SESSION',   -- 8 окт: паттерны библиотеки — регионы после =END (маркера =LIB нет)
                        session = name == '=SESSION' }
    end
    i = i + 1
  end
  table.sort(out, function(a, b) return a.pos < b.pos end)
  out.lib_pos = lib_pos
  out.end_pos, out.start_pos = end_pos, start_pos   -- для последовательности без перебора маркеров каждый кадр
  out.markers = markers
  rcache.key, rcache.list = key, out
  return out
end
M.LIB_MARKER = '=LIB'
M.SESSION_REGION = '=SESSION'   -- зона сессии (6 окт): не слот, не паттерн
M.SHOW_ZONE = false             -- трекер показывает зону (сессия играет), ставит main
function M.session_zone()
  if not R.EnumProjectMarkers3 then return nil end
  local i = 0
  while true do
    local ret, isrgn, pos, rgnend, name = R.EnumProjectMarkers3(0, i)
    if not ret or ret == 0 then return nil end
    if isrgn and name == M.SESSION_REGION then return { pos, rgnend } end
    i = i + 1
  end
end

-- Паттерны: уникальные имена регионов; номер — минимальный idx экземпляра,
-- источник — первый экземпляр в последовательности (иначе в библиотеке).
function M.patterns(regions)
  local by = {}
  local list = {}
  for _, rg in ipairs(regions) do
    if rg.name ~= '' then
      local p = by[rg.name]
      if not p then p = { name = rg.name, num = rg.idx, src = nil, n = 0 }; by[rg.name] = p; list[#list + 1] = p end
      if rg.idx < p.num then p.num = rg.idx end
      if not rg.lib and not rg.session then p.n = p.n + 1 end
      if not p.src or (p.src.lib and not rg.lib) then p.src = rg end
    end
  end
  -- устойчивый порядок: по имени (без регистра, числа по значению), номер =
  -- позиция в списке. Раньше номер = минимальный idx региона с этим именем —
  -- после смены слота имена переезжали, номера пересчитывались, и стрелки
  -- < > прыгали через паттерны.
  local function key(nm) return (nm:lower():gsub('%d+', function(d) return ('%08d'):format(tonumber(d)) end)) end
  table.sort(list, function(a, b) return key(a.name) < key(b.name) end)
  for i, p in ipairs(list) do p.num = i end
  return list, by
end

-- ── пики (этап 2) ─────────────────────────────────────────────────────────
-- Вертикальная волна item: npix пиков (по пикселю на строку высоты).
-- Кеш по GUID item + offs/len/rate + npix. Пики, которых у REAPER ещё нет,
-- достраиваются порциями (BUILD_STEPS за вызов), чтобы окно не замирало.
-- кеш волн с пределом (5 окт): новый ключ на каждую ширину / зум / item —
-- без предела рос всю сессию; > 600 — сброс, видимые пересчитаются за кадры
local peaks_n = 0
local function new_peaks()
  peaks_n = 0
  return setmetatable({}, { __newindex = function(t, k, v) rawset(t, k, v); peaks_n = peaks_n + 1 end })
end
local peaks = new_peaks()
local building = {}
M.BUILD_STEPS = 40

-- Офлайн-источник (REAPER держит медиа офлайн: длина 0, пиков нет) —
-- подменяем свежим PCM-источником из того же файла (кеш по пути).
local fresh_src = {}
function M.online_src(src)
  if not src then return nil end
  local len = R.GetMediaSourceLength(src)
  if len and len > 0 then return src end
  local fn = R.GetMediaSourceFileName(src, '')
  if not fn or fn == '' then return src end
  local f = fresh_src[fn]
  if f == nil then
    f = R.PCM_Source_CreateFromFile(fn) or false
    fresh_src[fn] = f
  end
  return f or src
end

-- want_spec — ещё и спектральная окраска REAPER (extra_type 115: в каждом
-- пике 32-бит слово, младшие 15 бит — частота в Гц)
-- stretch-маркеры как карта «время item → время источника» (2 окт): список
-- { pos, src } по pos и подпись для ключа кэша пиков; nil, если маркеров нет
-- обратная карта (5 окт): позиция маркера-источника u (в долях при playrate,
-- как GetTakeStretchMarker) → время item; вне маркеров — наклон 1
function M.item_time_of_src(pts, u)
  if not pts or #pts == 0 then return nil end
  if u <= pts[1].src then return pts[1].pos - (pts[1].src - u) end
  for k = 1, #pts - 1 do
    local a, b = pts[k], pts[k + 1]
    if u <= b.src then
      local d = b.src - a.src
      return d > 1e-9 and (a.pos + (u - a.src) / d * (b.pos - a.pos)) or a.pos
    end
  end
  local z = pts[#pts]
  return z.pos + (u - z.src)
end

function M.stretch_map(take)
  if not take or not R.GetTakeNumStretchMarkers then return nil end
  local n = R.GetTakeNumStretchMarkers(take)
  if n == 0 then return nil end
  local pts, sig = {}, {}
  for i = 0, n - 1 do
    local _, pos, src = R.GetTakeStretchMarker(take, i)
    if pos and src then pts[#pts + 1] = { pos = pos, src = src }; sig[#sig + 1] = ('%.4f:%.4f'):format(pos, src) end
  end
  if #pts == 0 then return nil end
  table.sort(pts, function(a, b) return a.pos < b.pos end)
  return pts, table.concat(sig, ',')
end

-- время item t → секунды источника по карте маркеров. Позиция маркера в
-- источнике у REAPER — в долях при playrate (3 окт: конец 2.667 при rate 1.5 =
-- 4.0 с файла; раньше бралась как секунды — волна показывала 2/3 файла):
-- карта считается в этих долях (вне маркеров — наклон 1), потом × rate
local function map_src(pts, t, rate)
  local function u()
    if t <= pts[1].pos then return pts[1].src - (pts[1].pos - t) end
    for k = 1, #pts - 1 do
      local a, b = pts[k], pts[k + 1]
      if t <= b.pos then
        local d = b.pos - a.pos
        return d > 1e-9 and (a.src + (t - a.pos) / d * (b.src - a.src)) or a.src
      end
    end
    local z = pts[#pts]
    return z.src + (t - z.pos)
  end
  return u() * rate
end

-- stretch-маркеры take → доли длины item (0..1); nil, если нет
function M.stretch_fracs(take, len)
  if not take or not R.GetTakeNumStretchMarkers or len <= 0 then return nil end
  local n = R.GetTakeNumStretchMarkers(take)
  if n == 0 then return nil end
  local out = {}
  for i = 0, n - 1 do
    local _, pos = R.GetTakeStretchMarker(take, i)
    if pos and pos > 1e-6 and pos < len - 1e-6 then out[#out + 1] = pos / len end
  end
  return #out > 0 and out or nil
end

M.OVERSAMPLE = 1   -- 1/2/4: пиков на пиксель (Options → wave detail); max/min по группе
function M.peaks(head, npix, want_spec)
  if not head.src or npix < 2 then return nil end
  if peaks_n > 600 then peaks = new_peaks() end
  npix = math.floor(npix)
  -- луп (2 окт): пики одного периода источника, разложенные по item по модулю
  -- периода (раньше читался «источник» за его концом — волна сбивалась)
  if head.loop_src and not head._lin and not head.smap then
    local per = head.loop_src
    local rate = (head.rate and head.rate > 0) and head.rate or 1
    local key = ('%s|loop|%.4f|%.4f|%.4f|%d%s|%d'):format(head.guid, per, head.offs or 0, head.len, npix, want_spec and 's' or '', M.OVERSAMPLE or 1)
    local p = peaks[key]
    if p then return p end
    local nlin = math.max(2, math.min(16384, math.floor(npix * per * rate / math.max(1e-6, head.len)) * 2 + 2))
    local lin = M.peaks({ src = head.src, guid = head.guid .. '|loopsrc', offs = 0, len = per, rate = 1, _lin = true }, nlin, want_spec)
    if not lin then return nil end
    local out = { n = npix, max = {}, min = {}, spec = lin.spec and {} or nil }
    local function pick(a, b, acc)          -- a..b — секунды источника внутри [0, per)
      local ja = math.max(1, math.min(lin.n, math.floor(a / per * lin.n) + 1))
      local jb = math.max(ja, math.min(lin.n, math.floor(b / per * lin.n)))
      for j = ja, jb do
        if lin.max[j] > acc[1] then acc[1] = lin.max[j] end
        if lin.min[j] < acc[2] then acc[2] = lin.min[j] end
      end
      return ja
    end
    for i = 1, npix do
      local s0 = (head.offs or 0) + (i - 1) / npix * head.len * rate
      local s1 = (head.offs or 0) + i / npix * head.len * rate
      local a, b = s0 % per, s1 % per
      local acc = { -2, 2 }
      local ja
      if s1 - s0 >= per then ja = pick(0, per, acc)
      elseif b >= a then ja = pick(a, b, acc)
      else ja = pick(a, per, acc); pick(0, b, acc) end
      out.max[i], out.min[i] = acc[1] > -2 and acc[1] or 0, acc[2] < 2 and acc[2] or 0
      if out.spec then out.spec[i] = lin.spec[ja] end
    end
    peaks[key] = out
    return out
  end
  -- stretch-маркеры (2 окт): пики источника читаются линейно, потом
  -- раскладываются по карте «время item → время источника», как в REAPER
  if head.smap and not head._lin then
    local key = ('%s|smap|%s|%.4f|%.4f|%d%s|%d'):format(head.guid, head.smap_sig or '', head.len, head.rate, npix, want_spec and 's' or '', M.OVERSAMPLE or 1)
    local p = peaks[key]
    if p then return p end
    local rate = (head.rate and head.rate > 0) and head.rate or 1
    local srcs, lo, hi = {}, math.huge, -math.huge
    for i = 0, npix do
      local s = map_src(head.smap, i / npix * head.len, rate)
      srcs[i] = s
      if s < lo then lo = s end
      if s > hi then hi = s end
    end
    if lo < 0 then lo = 0 end
    if hi - lo < 1e-4 then return nil end
    local nlin = math.min(16384, npix * 2)
    local lin = M.peaks({ src = head.src, guid = head.guid .. '|lin', offs = lo, len = hi - lo, rate = 1, _lin = true }, nlin, want_spec)
    if not lin then return nil end
    local out = { n = npix, max = {}, min = {}, spec = lin.spec and {} or nil }
    local span = hi - lo
    for i = 1, npix do
      local a, b = srcs[i - 1], srcs[i]
      if a > b then a, b = b, a end
      local ja = math.max(1, math.min(lin.n, math.floor((a - lo) / span * lin.n) + 1))
      local jb = math.max(ja, math.min(lin.n, math.floor((b - lo) / span * lin.n)))
      local mx, mn = -2, 2
      for j = ja, jb do
        if lin.max[j] > mx then mx = lin.max[j] end
        if lin.min[j] < mn then mn = lin.min[j] end
      end
      out.max[i], out.min[i] = mx > -2 and mx or 0, mn < 2 and mn or 0
      if out.spec then out.spec[i] = lin.spec[ja] end
    end
    peaks[key] = out
    return out
  end
  local os = M.OVERSAMPLE or 1
  -- период лупа и длина источника — в ключе (5 окт): шов лупа меняет секцию
  -- источника, а guid / offs / len те же — волна оставалась старой
  local key = string.format('%s|%.4f|%.4f|%.4f|%d%s|%d|%.4f|%s', head.guid, head.offs, head.len, head.rate, npix, want_spec and 's' or '', os, head.loop_src or 0, tostring(head.src))
  local p = peaks[key]
  if p ~= nil then
    -- отрицательный результат (офлайн-медиа, ещё нет пиков) — не навсегда: повтор через 2 с
    if p == false then return nil end
    if p.retry then if R.time_precise() < p.retry then return nil end; peaks[key] = nil
    else return p end
  end
  local src = M.online_src(head.src)
  local span = head.len * head.rate            -- секунды источника под item
  if span <= 0 then peaks[key] = false; return nil end
  local function fetch(n, et)
    local b = R.new_array(n * (et == 115 and 3 or 2)); b.clear()
    local r = R.PCM_Source_GetPeaks(src, n / span, head.offs, 1, n, et, b)
    return r, r & 0xfffff, b
  end
  -- блоки буфера (4 окт): max — n запрошенных точек, за ним min — тоже со
  -- сдвигом n ЗАПРОШЕННЫХ, а не полученных (spl < n у края источника — min
  -- читались из max, нижняя половина волны пропадала)
  local nreq = math.min(npix * os, 16384)
  local rv, spl, buf = fetch(nreq, 0)
  if spl == 0 then
    -- пиков нет: запускаем достройку, результат — на следующих кадрах
    local b = building[key]
    if not b then
      if R.PCM_Source_BuildPeaks(src, 0) ~= 0 then building[key] = { src = src, t0 = R.time_precise() }
      else
        -- пики уже есть на диске, но свежий источник их ещё не подхватил:
        -- финализировать и сразу перечитать (как build_env слайсера)
        R.PCM_Source_BuildPeaks(src, 2)
        rv, spl, buf = fetch(nreq, 0)
        if spl == 0 then peaks[key] = { retry = R.time_precise() + 2.0 }; return nil end
      end
      if spl == 0 then return nil end
    else
      -- достройка не завершается (медиа ушло офлайн, источник сменился) —
      -- через 4 с бросаем и пробуем заново, иначе волна пропадает навсегда
      if R.time_precise() - (b.t0 or 0) > 4 then building[key] = nil; peaks[key] = { retry = R.time_precise() + 1.0 }; return nil end
      for _ = 1, M.BUILD_STEPS do
        if R.PCM_Source_BuildPeaks(b.src or src, 1) == 0 then
          R.PCM_Source_BuildPeaks(b.src or src, 2); building[key] = nil; break
        end
      end
      return nil
    end
  end
  if spl == 0 then return nil end
  -- «Сырой» режим (биты 20..23 rv ≠ 0): на высокой плотности REAPER отдаёт
  -- по одному сэмплу на точку, огибающая теряется (тонкая линия при громком
  -- сэмпле, 1 окт). Просим реже, пока не вернутся пары max/min, и
  -- растягиваем на сетку npix.
  local n = math.min(npix * os, 16384)
  while (rv >> 20) & 0xF ~= 0 and n > 32 do
    n = n // 2
    local r2, s2, b2 = fetch(n, 0)
    if s2 == 0 then break end
    rv, spl, buf, nreq = r2, s2, b2, n
  end
  local t = buf.table()
  local raw = (rv >> 20) & 0xF ~= 0
  local out = { n = npix, max = {}, min = {} }
  -- точек больше, чем пикселей (передискретизация) — max/min по группе;
  -- меньше — растяжка (одна точка на несколько пикселей)
  for i = 1, npix do
    local j0 = math.floor((i - 1) / npix * spl) + 1
    local j1 = math.max(j0, math.floor(i / npix * spl))
    local mx, mn = -2, 2
    for j = j0, j1 do
      local a, b
      if raw then a = t[j]; b = a else a = t[j]; b = t[nreq + j] end
      if a and a > mx then mx = a end
      if b and b < mn then mn = b end
    end
    if mx < -1 then mx = 0 end; if mn > 1 then mn = 0 end
    out.max[i], out.min[i] = mx, mn
  end
  -- спектр (extra_type 115): всегда отдельным запросом на ~200 точек/с —
  -- на пиксельной плотности бита 0x1000000 нет; растягиваем на сетку
  if want_spec then
    local n2 = math.max(2, math.min(npix, math.floor(span * 200)))
    local r2, s2, b2 = fetch(n2, 115)
    if s2 > 0 and (r2 >> 20) & 0xF == 0 and r2 & 0x1000000 ~= 0 then
      local t2 = b2.table()
      out.spec = {}
      for i = 1, npix do out.spec[i] = t2[2 * n2 + math.floor((i - 1) / npix * s2) + 1] end   -- блок spec — после 2 × n2 запрошенных
    end
  end
  -- сплошной ноль = пики ещё не подхвачены (свежий источник офлайн-файла
  -- сначала отдаёт тишину) — не кешировать навсегда, перечитать через 1 с
  local peak = 0
  for i = 1, npix do local a = math.abs(out.max[i] or 0); if a > peak then peak = a end; a = math.abs(out.min[i] or 0); if a > peak then peak = a end end
  if peak < 1e-4 then
    R.PCM_Source_BuildPeaks(src, 0); R.PCM_Source_BuildPeaks(src, 2)
    peaks[key] = { retry = R.time_precise() + 1.0 }
    return nil
  end
  peaks[key] = out
  return out
end

-- пики файла браузера: PCM-источник живёт в кеше (до FILE_SRC_MAX), пики — M.peaks
local file_src, file_src_n, file_src_order = {}, 0, {}
M.FILE_SRC_MAX = 300
function M.file_peaks(path, npix)
  local e = file_src[path]
  if e == nil then
    local src = R.PCM_Source_CreateFromFile(path)
    if not src then file_src[path] = false; return nil end
    local len = R.GetMediaSourceLength(src) or 0
    e = { src = src, guid = 'file:' .. path, offs = 0, len = len, rate = 1 }
    file_src[path] = e
    file_src_n = file_src_n + 1; file_src_order[#file_src_order + 1] = path
    if file_src_n > M.FILE_SRC_MAX then
      local old = table.remove(file_src_order, 1)
      local oe = file_src[old]
      if oe and oe.src then pcall(R.PCM_Source_Destroy, oe.src) end
      file_src[old] = nil; file_src_n = file_src_n - 1
    end
  end
  if not e or e.len <= 0 then return nil end
  return M.peaks(e, npix)
end

function M.clear_peaks() peaks = new_peaks(); building = {} end
M.peaks_cache_size = function() local n = 0; for _ in pairs(peaks) do n = n + 1 end; return n end

return M
