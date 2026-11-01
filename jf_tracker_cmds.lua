-- jf_tracker_cmds.lua — команды-огибающие и генераторы (этап 7).
--
-- Команда хранится у item как текст в P_EXT:jf_cmds («0U08,0VA3,0R24») и
-- ПЕРЕСОБИРАЕТСЯ целиком при каждой правке: take-огибающие (Pitch, Volume)
-- внутри item очищаются и строятся заново, сгенерированные копии
-- (P_EXT:jf_gen = guid родителя) удаляются и создаются снова. Всё
-- нативное: точки take-огибающих, items, tempo-маркеры, MIDI pitchbend.
-- Тиклесс: доли — от строки (xx/16 полутона на строку и т.п.).
-- Коды — двухсимвольные, как в Renoise (12 окт: было по одной букве):
--
--   0Uxx / 0Dxx питч вверх/вниз на xx/16 полутона за строку (стиль — C.MODE: renoise / ft2 / it / pt)
--               (аудио — take Pitch; MIDI — pitchbend ±2 полутона)
--   0Gxx        glide: от высоты предыдущего события к своей за xx строк
--   0Vxy        vibrato: период 16/x строк (x=0 → 4), глубина y/8 полутона
--   0Axy        arpeggio: 0, x, y полутонов по трети строки, ступенями
--   0Ixx / 0Oxx громкость вверх / вниз на xx/256 за строку (take Volume)
--   0Rxy        retrigger: копии каждые y/16 строки (y=0 → 4/16), громкость
--               каждой ×(1 − x/16) — порядок x/y как в Renoise; копии —
--               items с P_EXT:jf_gen
--   0Yxx        вероятность: item заглушается с шансом 1 − xx/FF (бросок
--               при каждой пересборке)
--   ZTxx        темп: tempo-маркер в строке события, BPM = xx (hex)
--
-- 12 окт: у каждой строки своя команда. Токен с @смещением (четверти от
-- начала ноты, не строки — LPB не ломает): «0U08@0.75». Без @ — первая строка.
-- Как в Furnace: команда действует со своей строки до следующей того же рода
-- в этой ноте (или до конца ноты), значение 00 — выключить. Роды: slide (0U 0D),
-- vibrato (0V), arp (0A), volume slide (0I 0O), retrig (0R), tempo (ZT, маркер на
-- своей строке), jump (ZJ). 0G и 0Y — свойства всей ноты.

local C = {}
local R = reaper
local model

C.CODES = { ['0U'] = true, ['0D'] = true, ['0G'] = true, ['0V'] = true, ['0A'] = true, ['0I'] = true, ['0O'] = true,
  ['0R'] = true, ['0Y'] = true, ZT = true, ZJ = true, ZB = true, ['0T'] = true }   -- 1 ноя: 0T — тремоло (PT 7xy)   -- 1 ноя: ZB — pattern break (ProTracker Dxx)
-- ZJxx — прыжок: когда плейхед доходит до строки события, трекер переводит
-- воспроизведение в слот xx последовательности (матрица). Хранится как
-- команда, огибающих не строит — исполняет main в кадре.

function C.init(m) model = m end

-- 30 окт: стиль слайда 0U / 0D (опция slide style) — как в трекере, откуда пришла привычка:
--   renoise  xx/16 полутона за строку
--   ft2      FastTracker 2, линейные частоты: xx/16 полутона за ТИК, тиков со слайдом speed − 1
--   it       Schism / Impulse Tracker, линейные слайды: как ft2, память 00 у 0U и 0D общая
--   pt       ProTracker: период Amiga −xx (вверх) / +xx за тик, высота нелинейна (зависит от ноты), 113..856
-- Что делает 00 — отдельная опция (C.ZERO)
-- Новая нота во всех — со своей высоты (слайд — внутри ноты)
C.MODE, C.SPEED = 'renoise', 6
C.MIDI_FX = true   -- 1 ноя: высота / громкость MIDI-нот — эффектами трека (любой инструмент), не pitch bend
C.ZERO = 'repeat'   -- 00 у 0U / 0D: repeat — повтор прошлого значения (как в Renoise), stop — слайд стоит (опция slide 00)
C.MODES = { 'renoise', 'ft2', 'it', 'pt' }
local function pt_period(pitch) return 428 * 2 ^ ((60 - (pitch or 60)) / 12) end   -- C-4 трекера (60) = C-2 ProTracker
-- сдвиг в полутонах за rows строк слайда команды c от ноты pitch
function C.slide_semis(c, rows, pitch)
  local sgn = c.cmd == '0U' and 1 or -1
  local m = C.MODE
  if m == 'ft2' or m == 'it' then return sgn * c.xx / 16 * (C.SPEED - 1) * rows end
  if m == 'pt' then
    local p0 = pt_period(pitch)
    local p = math.max(113, math.min(856, p0 - sgn * c.xx * (C.SPEED - 1) * rows))
    p0 = math.max(113, math.min(856, p0))
    return 12 * math.log(p0 / p, 2)
  end
  return sgn * c.xx / 16 * rows
end
-- 00 = повтор прошлого значения (C.ZERO = 'repeat'; it — память общая у 0U и 0D); stop — 00 останавливает слайд
function C.slide_memory(list)
  if C.ZERO ~= 'repeat' then return list end
  local last, out = {}, {}
  for _, c in ipairs(list) do
    if c.cmd == '0U' or c.cmd == '0D' then
      local key = C.MODE == 'it' and 'ud' or c.cmd
      if c.xx == 0 and last[key] then c = { cmd = c.cmd, xx = last[key], x = last[key] >> 4, y = last[key] & 15, off = c.off }
      elseif c.xx > 0 then last[key] = c.xx end
    end
    out[#out + 1] = c
  end
  return out
end

-- ── разбор / хранение ─────────────────────────────────────────────────────
function C.parse(str)
  local out = {}
  for tok in (str or ''):gmatch('[^,]+') do
    local code, hex, off = tok:match('^(%w%w)(%x%x)@?([%d%.]*)$')
    if code and C.CODES[code] then
      local xx = tonumber(hex, 16)
      out[#out + 1] = { cmd = code, xx = xx, x = xx >> 4, y = xx & 15, off = tonumber(off) or 0 }
    end
  end
  table.sort(out, function(a, b) if math.abs(a.off - b.off) > 1e-6 then return a.off < b.off end; return false end)
  return out
end

local function fmt_off(o) return (o and o > 1e-6) and ('@' .. (('%.4f'):format(o):gsub('0+$', ''):gsub('%.$', ''))) or '' end
function C.format(list)
  local t = {}
  for _, c in ipairs(list) do t[#t + 1] = c.cmd .. ('%02X'):format(c.xx) .. fmt_off(c.off) end
  return table.concat(t, ',')
end
C.fmt_off = fmt_off
-- токен как в ячейке: «0U08» (смещение — место в строке, не текст)
function C.token(c) return c.cmd .. ('%02X'):format(c.xx) end

function C.get(it)
  local _, s = R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_cmds', '', false)
  return C.parse(s)
end

function C.set(it, list)
  R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_cmds', C.format(list), true)
end

-- добавить/заменить команду code со значением xx в строке off (четверти от начала ноты; nil — снять)
function C.put(it, code, xx, off)
  off = off or 0
  local list = C.get(it)
  local out = {}
  for _, c in ipairs(list) do if not (c.cmd == code and math.abs(c.off - off) < 1e-4) then out[#out + 1] = c end end
  if xx then out[#out + 1] = { cmd = code, xx = xx, x = xx >> 4, y = xx & 15, off = off } end
  C.set(it, out)
  return out
end

-- 12 окт: отрезки рода: { {a, b, c} … } — команда c действует [a, b) (в своих единицах времени);
-- t(off) переводит смещение в время; xx = 00 — отрезок без действия
function C.segments(list, kinds, t, tend)
  local seg = {}
  for _, c in ipairs(list) do
    if kinds[c.cmd] then
      local a = math.max(0, math.min(tend, t(c.off)))
      if #seg > 0 then seg[#seg][2] = math.max(seg[#seg][1], a) end
      seg[#seg + 1] = { a, tend, c }
    end
  end
  local out = {}
  for _, sg in ipairs(seg) do if sg[3].xx > 0 and sg[2] > sg[1] + 1e-9 then out[#out + 1] = sg end end
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

-- ── 1 ноя: модуляция MIDI-трека — простые эффекты в конце цепи, для любого инструмента ──
-- pitch — ReaPitch «Shift (semitones)», vol / pan — JS Volume/Pan Smoother v5. Нет эффекта и create — ставится
-- в конец цепи (после инструмента); есть — берётся тот же. → огибающая, перевод значения в сырое значение
-- параметра (pitch — полутоны, vol — амплитуда 0..2, pan — −1..1), индекс эффекта
C.FX_MOD = {
  pitch = { add = 'ReaPitch', match = 'reapitch', param = 'shift (semitones)' },
  vol = { add = 'JS: Volume/Pan Smoother v5', match = 'volume/pan smoother', param = 'volume' },
  pan = { add = 'JS: Volume/Pan Smoother v5', match = 'volume/pan smoother', param = 'pan' },
}
local function num_of(s) return tonumber(((s or ''):match('[-+]?%d+%.?%d*')) or '') end
function C.fx_env(tr, kind, create)
  local d = C.FX_MOD[kind]
  if not d then return nil end
  local fx
  for f = 0, R.TrackFX_GetCount(tr) - 1 do
    local _, fn = R.TrackFX_GetFXName(tr, f, '')
    if fn:lower():find(d.match, 1, true) then fx = f end
  end
  if not fx then
    if not create then return nil end
    fx = R.TrackFX_AddByName(tr, d.add, false, -1)
    if not fx or fx < 0 then return nil end
  end
  local p
  for k = 0, R.TrackFX_GetNumParams(tr, fx) - 1 do
    local _, pn = R.TrackFX_GetParamName(tr, fx, k, '')
    if not p and pn:lower():find(d.param, 1, true) then p = k end
  end
  if not p then return nil end
  local env = R.GetFXEnvelope(tr, fx, p, create and true or false)
  if not env then return nil end
  local _, mn, mx = R.TrackFX_GetParam(tr, fx, p)
  if not (mn and mx and mx > mn) then mn, mx = 0, 1 end
  local conv
  if kind == 'pitch' then
    -- полутоны → сырое: показ параметра на краях (0 и 1) даёт шкалу
    local _, s0 = R.TrackFX_FormatParamValueNormalized(tr, fx, p, 0, '')
    local _, s1 = R.TrackFX_FormatParamValueNormalized(tr, fx, p, 1, '')
    local a, b = num_of(s0) or -12, num_of(s1) or 12
    if b == a then a, b = -12, 12 end
    conv = function(semis) local nrm = math.max(0, math.min(1, (semis - a) / (b - a))); return mn + nrm * (mx - mn) end
  elseif kind == 'vol' then
    conv = function(amp) local db = amp > 1e-6 and 20 * math.log(amp, 10) or -200; return math.max(mn, math.min(mx, db)) end
  else
    conv = function(pan) return mn + (math.max(-1, math.min(1, pan)) + 1) / 2 * (mx - mn) end
  end
  return env, conv, fx, p
end

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
  -- tempo-маркеры, поставленные нами (P_EXT:jf_tempo: «1» — в начале ноты, или времена через ;) — убрать
  do
    local _, tm = R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_tempo', '', false)
    if tm and tm ~= '' then
      local times = {}
      if tm == '1' then times[1] = pos else for v in tm:gmatch('[^;]+') do times[#times + 1] = tonumber(v) end end
      for _, tt in ipairs(times) do
        local idx = tt and R.FindTempoTimeSigMarker(0, tt + 1e-4)
        if idx and idx >= 0 then
          local ok, t = R.GetTempoTimeSigMarker(0, idx)
          if ok and math.abs(t - tt) < 1e-3 then R.DeleteTempoTimeSigMarker(0, idx) end
        end
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
    if c.cmd == '0U' or c.cmd == '0D' or c.cmd == '0G' or c.cmd == '0V' or c.cmd == '0A' then need_pitch = true end
    if c.cmd == '0I' or c.cmd == '0O' or c.cmd == '0T' then need_vol = true end
  end
  if is_midi then
    -- 1 ноя: высота MIDI-ноты — не pitch bend (не каждый инструмент его понимает), а ReaPitch в конце цепи трека
    -- (C.MIDI_FX; ниже, вместе с аудио); pitch bend — только если C.MIDI_FX выключен
    local _, _, ncc = R.MIDI_CountEvts(take)
    for i = (C.MIDI_FX and -1 or ncc - 1), 0, -1 do
      local _, _, _, ppq, typ = R.MIDI_GetCC(take, i)
      if typ == 0xE0 then
        local tt = R.MIDI_GetProjTimeFromPPQPos(take, ppq)
        if tt >= pos - 1e-6 and tt <= pos + len + 1e-6 then R.MIDI_DeleteCC(take, i) end
      end
    end
    -- 12 окт: отрезки slide (0U / 0D со своих строк), pitchbend ±2 полутона, линейно между границами
    local tq = function(off) return R.TimeMap2_QNToTime(0, qn0 + off) - pos end
    -- 19 окт: команда — у своей ноты: отрезок slide до конца этой ноты (или до следующей 0U / 0D), потом bend — в центр;
    -- соседние ноты клипа не задеваются
    table.sort(list, function(a, b) return (a.off or 0) < (b.off or 0) end)
    local nends = {}
    do
      local _, nn = R.MIDI_CountEvts(take)
      for k = 0, nn - 1 do
        local _, _, _, sp, ep, _, pi = R.MIDI_GetNote(take, k)
        nends[#nends + 1] = { s = R.MIDI_GetProjTimeFromPPQPos(take, sp) - pos, e = R.MIDI_GetProjTimeFromPPQPos(take, ep) - pos, pi = pi }
      end
    end
    local function note_end(t)
      local best, bp
      for _, ne in ipairs(nends) do if math.abs(ne.s - t) < row_sec / 2 and (not best or ne.e > best) then best, bp = ne.e, ne.pi end end
      return best, bp
    end
    local function note_over(t)   -- нота, что звучит в t (команда со смещением внутри длинной ноты)
      for _, ne in ipairs(nends) do if ne.s <= t + 1e-6 and ne.e > t + 1e-6 then return ne end end
    end
    local segs = C.segments(C.slide_memory(list), { ['0U'] = true, ['0D'] = true }, tq, len)
    if #segs > 0 and not C.MIDI_FX then
      local brange = (C.bend_range and C.bend_range(tr)) or 2   -- 19 окт: диапазон bend инструмента (пэды кита — их Pitchbend range)
      local function bend_at(semis) return math.max(0, math.min(16383, math.floor(8192 + semis / brange * 8191 + 0.5))) end
      local pts = { { 0, 0 } }
      -- 30 окт: слайд внутри одной ноты копится от команды к команде (раньше каждая строка начинала с нуля);
      -- новая нота — с нуля; стиль — C.slide_semis (pt нелинеен — точка на каждый тик)
      local acc, cur_end, cur_pi = 0, nil, nil
      for _, sg in ipairs(segs) do
        local ne, npi = note_end(sg[1])
        if ne then acc, cur_end, cur_pi = 0, ne, npi
        else
          local no = note_over(sg[1])
          if not (no and cur_end and math.abs(no.e - cur_end) < 1e-6) then acc = 0; cur_end, cur_pi = no and no.e, no and no.pi end
        end
        local b = cur_end and math.min(sg[2], cur_end) or sg[2]
        local rows = (b - sg[1]) / row_sec
        local n = C.MODE == 'pt' and math.max(1, math.min(64, math.floor(rows * (C.SPEED - 1) + 0.5))) or 1
        pts[#pts + 1] = { sg[1], acc }
        for j = 1, n do
          local v = acc + C.slide_semis(sg[3], rows * j / n, cur_pi)
          pts[#pts + 1] = { sg[1] + (b - sg[1]) * j / n, math.max(-brange, math.min(brange, v)) }
        end
        acc = pts[#pts][2]
        if not cur_end or b >= cur_end - 1e-6 then pts[#pts + 1] = { b + 0.0005, 0 }; acc = 0 end   -- после ноты — назад в центр
      end
      for _, p in ipairs(pts) do
        local bnd = bend_at(p[2])
        local pp = R.MIDI_GetPPQPosFromProjTime(take, pos + p[1])
        R.MIDI_InsertCC(take, false, false, pp, 0xE0, head.ch or 0, bnd & 127, bnd >> 7)
      end
      local _, _, ncc2 = R.MIDI_CountEvts(take)
      for i = 0, ncc2 - 1 do
        local _, _, _, ppq, typ = R.MIDI_GetCC(take, i)
        local tt = R.MIDI_GetProjTimeFromPPQPos(take, ppq)
        if typ == 0xE0 and tt >= pos - 1e-6 and tt <= pos + len + 1e-6 then R.MIDI_SetCCShape(take, i, 1, 0, true) end
      end
      R.MIDI_Sort(take)
    end
    -- 28 окт: 0R на MIDI — нота перезапускается копиями (каждые y/16 строки, velocity ×(1 − x/16)) до конца ноты;
    -- копии помечены в P_EXT:jf_rtg («ppq:pitch:ch;…»), исходная длина — в P_EXT:jf_rtl («ppq:pitch:end;…»),
    -- при пересборке — сперва убрать прошлое
    do
      local _, gen = R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_rtg', '', false)
      local _, lens = R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_rtl', '', false)
      local changed = false
      if (gen or '') ~= '' or (lens or '') ~= '' then
        local G, Lm = {}, {}
        for a1, b1, c1 in (gen or ''):gmatch('([%-%d%.]+):(%d+):(%d+)') do G[('%d:%d:%d'):format(math.floor(tonumber(a1) + 0.5), tonumber(b1), tonumber(c1))] = true end
        for a1, b1, e1 in (lens or ''):gmatch('([%-%d%.]+):(%d+):([%-%d%.]+)') do Lm[('%d:%d'):format(math.floor(tonumber(a1) + 0.5), tonumber(b1))] = tonumber(e1) end
        local _, nn = R.MIDI_CountEvts(take)
        for k = nn - 1, 0, -1 do
          local _, sel, mu, sp, ep, ch, pi, ve = R.MIDI_GetNote(take, k)
          local key3 = ('%d:%d:%d'):format(math.floor(sp + 0.5), pi, ch)
          local key2 = ('%d:%d'):format(math.floor(sp + 0.5), pi)
          if G[key3] then R.MIDI_DeleteNote(take, k); changed = true
          elseif Lm[key2] then R.MIDI_SetNote(take, k, sel, mu, sp, Lm[key2], ch, pi, ve, true); changed = true end
        end
        R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_rtg', '', true)
        R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_rtl', '', true)
      end
      local rsegs = C.segments(list, { ['0R'] = true }, tq, len)
      local gout, lout = {}, {}
      if #rsegs > 0 then
        local _, nn = R.MIDI_CountEvts(take)
        local notes = {}
        for k = 0, nn - 1 do
          local _, sel, mu, sp, ep, ch, pi, ve = R.MIDI_GetNote(take, k)
          notes[#notes + 1] = { k = k, sel = sel, mu = mu, sp = sp, ep = ep, ch = ch, pi = pi, ve = ve,
            s = R.MIDI_GetProjTimeFromPPQPos(take, sp) - pos, e = R.MIDI_GetProjTimeFromPPQPos(take, ep) - pos }
        end
        for _, sg in ipairs(rsegs) do
          local c = sg[3]
          local every = (c.y > 0 and c.y or 4) / 16 * row_sec
          local decay = 1 - c.x / 16
          -- ноты, что звучат на начале отрезка (начались не позже его строки)
          for _, nt in ipairs(notes) do
            if nt.s <= sg[1] + row_sec / 2 and nt.e > sg[1] + 1e-4 and every > 1e-4 then
              local stop = math.min(nt.e, sg[2])
              local t = math.max(nt.s, sg[1]) + every
              local j = 1
              local first = true
              while t < stop - 1e-4 and j <= 64 do
                -- 28 окт: целые тики — метка копии (floor(pp + 0.5)) совпадает с тем, что хранит REAPER (дробный тик
                -- он режет иначе: половина копий теряла метку, становилась нотами и не убиралась — залипание)
                local pp = math.floor(R.MIDI_GetPPQPosFromProjTime(take, pos + t) + 0.5)
                local pnext = math.floor(R.MIDI_GetPPQPosFromProjTime(take, pos + math.min(stop, t + every)) + 0.5)
                if first then   -- исходная — до первого перезапуска
                  lout[#lout + 1] = ('%d:%d:%.3f'):format(math.floor(nt.sp + 0.5), nt.pi, nt.ep)
                  R.MIDI_SetNote(take, nt.k, nt.sel, nt.mu, nt.sp, math.max(nt.sp + 1, pp - 1), nt.ch, nt.pi, nt.ve, true)   -- 28 окт: тик зазора — note-off раньше note-on (legato / mono сэмплера иначе не перезапускал)
                  first = false
                end
                local v = math.max(1, math.floor(nt.ve * decay ^ j + 0.5))
                R.MIDI_InsertNote(take, false, nt.mu, pp, math.max(pp + 1, (t + every >= stop) and nt.ep or (pnext - 1)), nt.ch, nt.pi, v, true)
                gout[#gout + 1] = ('%d:%d:%d'):format(math.floor(pp + 0.5), nt.pi, nt.ch)
                t = t + every; j = j + 1
              end
            end
          end
        end
      end
      if #gout > 0 then
        R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_rtg', table.concat(gout, ';'), true)
        R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_rtl', table.concat(lout, ';'), true)
        changed = true
      end
      if changed then R.MIDI_Sort(take) end
    end
    if not C.MIDI_FX then return end
  end
  -- аудио: огибающие тейка; MIDI (1 ноя): огибающие эффектов трека (ReaPitch, Volume/Pan Smoother) на время клипа
  local penv, venv, pconv, vconv
  local T0 = 0
  local pmin, pmax = -3, 3
  if is_midi then
    penv, pconv = C.fx_env(tr, 'pitch', need_pitch)
    venv, vconv = C.fx_env(tr, 'vol', need_vol)
    T0, pmin, pmax = pos, -12, 12
    -- на время клипа — своё; по краям — нейтраль (огибающая трека общая с соседними клипами)
    for _, e in ipairs({ { penv, pconv, 0 }, { venv, vconv, 1 } }) do
      if e[1] then
        R.DeleteEnvelopePointRange(e[1], pos - 1e-4, pos + len + 1e-4)
        if (e[1] == penv and need_pitch) or (e[1] == venv and need_vol) then
          R.InsertEnvelopePoint(e[1], pos - 1e-4, e[2](e[3]), 0, 0, false, true)
          R.InsertEnvelopePoint(e[1], pos + len + 1e-4, e[2](e[3]), 0, 0, false, true)
        end
      end
    end
    if not need_pitch then penv = nil end
    if not need_vol then venv = nil end
  else
    penv = need_pitch and ensure_take_env(it, take, 'Pitch') or R.GetTakeEnvelopeByName(take, 'Pitch')
    venv = need_vol and ensure_take_env(it, take, 'Volume') or R.GetTakeEnvelopeByName(take, 'Volume')
    if penv then clear_env(penv, it, take) end
    if venv then clear_env(venv, it, take) end
    if penv then pmin, pmax = env_range(penv, -3, 3) end
  end
  local function pt(env, t, v, shape)
    if env == penv and pconv then v = pconv(v) elseif env == venv and vconv then v = vconv(v) end
    R.InsertEnvelopePoint(env, T0 + t, v, shape or 0, 0, false, true)
  end
  local function clampp(v) return math.max(pmin, math.min(pmax, v)) end
  local muted = false
  -- 12 окт: команды со своих строк — отрезки (как в Furnace: до следующей того же рода, 00 — стоп)
  local ts = function(off) return (R.TimeMap2_QNToTime(0, qn0 + off) - pos) * rate end   -- время take (источник)
  local rs = row_sec * rate                                                              -- строка во времени take
  if penv then
    local slides = C.segments(C.slide_memory(list), { ['0U'] = true, ['0D'] = true }, ts, tlen)
    local vibs = C.segments(list, { ['0V'] = true }, ts, tlen)
    local arps = C.segments(list, { ['0A'] = true }, ts, tlen)
    local glide
    for _, c in ipairs(list) do if c.cmd == '0G' then glide = c end end
    local from = glide and ((prev_semis or 0) - (head.semis or 0)) or 0
    local gl = glide and math.min(tlen, math.max(1, glide.xx) * rs) or 0
    local function slide_at(t)
      local acc = 0
      for _, sg in ipairs(slides) do
        if t <= sg[1] then break end
        acc = acc + C.slide_semis(sg[3], (math.min(t, sg[2]) - sg[1]) / rs, head.pitch)   -- 30 окт: стиль слайда
      end
      return acc
    end
    local function seg_of(segs, t) for _, sg in ipairs(segs) do if t >= sg[1] - 1e-9 and t < sg[2] - 1e-9 then return sg end end end
    local function value(t)
      local v = slide_at(t)
      local vs = seg_of(vibs, t)
      if vs then
        local c = vs[3]
        local period = (c.x > 0 and 16 / c.x or 4) * rs
        v = v + c.y / 8 * math.sin(2 * math.pi * (t - vs[1]) / period)
      end
      local as = seg_of(arps, t)
      if as then
        local step = rs / 3
        local vals = { 0, as[3].x, as[3].y }
        v = v + vals[math.floor((t - as[1]) / step + 1e-6) % 3 + 1]
      end
      if glide and t < gl then v = v + from * (1 - t / gl) end
      return clampp(v)
    end
    if #slides + #vibs + #arps > 0 or glide then
      local times, seen = {}, {}
      local function add(t) t = math.max(0, math.min(tlen, t)); local k = ('%.6f'):format(t); if not seen[k] then seen[k] = true; times[#times + 1] = t end end
      add(0); add(tlen)
      for _, sg in ipairs(slides) do
        add(sg[1]); add(sg[2]); add(sg[1] - 1e-4)
        if C.MODE == 'pt' then   -- нелинейно — точка на тик
          local n = math.min(64, math.floor((sg[2] - sg[1]) / rs * (C.SPEED - 1) + 0.5))
          for j = 1, n - 1 do add(sg[1] + (sg[2] - sg[1]) * j / n) end
        end
      end
      for _, vs in ipairs(vibs) do
        local period = (vs[3].x > 0 and 16 / vs[3].x or 4) * rs
        local n = math.max(2, math.floor((vs[2] - vs[1]) / period * 8))
        for i = 0, n do add(vs[1] + (vs[2] - vs[1]) * i / n) end
        add(vs[1] - 1e-4); add(vs[2])
      end
      for _, as in ipairs(arps) do
        local t = as[1]
        while t < as[2] do add(t); t = t + rs / 3 end
        add(as[1] - 1e-4); add(as[2])
      end
      if glide then add(gl) end
      table.sort(times)
      for _, t in ipairs(times) do pt(penv, t, value(t), seg_of(arps, t) and 1 or 0) end
    end
  end
  -- 0I / 0O — громкость: накопленный наклон по отрезкам (вверх / вниз), одна огибающая
  local vsegs = C.segments(list, { ['0I'] = true, ['0O'] = true }, ts, tlen)
  local tsegs = C.segments(list, { ['0T'] = true }, ts, tlen)   -- 1 ноя: тремоло 0Txy — скорость x (период 16/x строк), глубина y/16
  if venv and (#vsegs > 0 or #tsegs > 0) then
    local vmin, vmax = 0, 2
    if not is_midi then vmin, vmax = env_range(venv, 0, 2) end
    local function slope_at(t)   -- накопленная громкость 0I / 0O к моменту t
      local acc = 1
      for _, sg in ipairs(vsegs) do
        if t <= sg[1] then break end
        acc = acc + (sg[3].xx / 256) * (sg[3].cmd == '0I' and 1 or -1) / rs * (math.min(t, sg[2]) - sg[1])
      end
      return acc
    end
    local function trem_at(t)
      for _, sg in ipairs(tsegs) do
        if t >= sg[1] - 1e-9 and t < sg[2] - 1e-9 then
          local c = sg[3]
          local period = (c.x > 0 and 16 / c.x or 4) * rs
          return 1 - (c.y / 16) * (0.5 - 0.5 * math.cos(2 * math.pi * (t - sg[1]) / period))
        end
      end
      return 1
    end
    local times, seen = {}, {}
    local function add(t) t = math.max(0, math.min(tlen, t)); local k = ('%.6f'):format(t); if not seen[k] then seen[k] = true; times[#times + 1] = t end end
    add(0); add(tlen)
    for _, sg in ipairs(vsegs) do add(sg[1]); add(sg[2]) end
    for _, sg in ipairs(tsegs) do
      local period = (sg[3].x > 0 and 16 / sg[3].x or 4) * rs
      local n = math.max(2, math.min(256, math.floor((sg[2] - sg[1]) / period * 8)))
      for i = 0, n do add(sg[1] + (sg[2] - sg[1]) * i / n) end
    end
    table.sort(times)
    for _, t in ipairs(times) do pt(venv, t, math.max(vmin, math.min(vmax, slope_at(t) * trem_at(t)))) end
  end
  if is_midi then
    if penv then R.Envelope_SortPoints(penv) end
    if venv then R.Envelope_SortPoints(venv) end
    return
  end
  -- 0R — перезапуск со своей строки: копии каждые y/16 строки до конца отрезка; последняя звучит до конца ноты
  local rsegs = C.segments(list, { ['0R'] = true }, function(off) return R.TimeMap2_QNToTime(0, qn0 + off) - pos end, len)
  if #rsegs > 0 then
    local trig = {}
    for _, sg in ipairs(rsegs) do
      local c = sg[3]
      local every = (c.y > 0 and c.y or 4) / 16 * row_sec
      local decay = 1 - c.x / 16
      local t, j = sg[1], 0
      if t < 1e-6 then t, j = every, 1 end            -- в первой строке нота сама — первый удар
      while t < sg[2] - 1e-6 and #trig < 64 and every > 1e-4 do trig[#trig + 1] = { t = t, v = decay ^ j }; t = t + every; j = j + 1 end
    end
    table.sort(trig, function(p, q) return p.t < q.t end)
    local ok, chunk = R.GetItemStateChunk(it, '', false)
    if ok and #trig > 0 then
      chunk = strip_guids(chunk)
      local v0 = R.GetMediaItemInfo_Value(it, 'D_VOL')
      for k, tg in ipairs(trig) do
        local copy = R.AddMediaItemToTrack(tr)
        R.SetItemStateChunk(copy, chunk, false)
        R.SetMediaItemInfo_Value(copy, 'D_POSITION', pos + tg.t)
        R.SetMediaItemInfo_Value(copy, 'D_LENGTH', ((trig[k + 1] and trig[k + 1].t) or len) - tg.t)
        R.SetMediaItemInfo_Value(copy, 'D_VOL', v0 * tg.v)
        if R.GetMediaTrackInfo_Value(tr, 'I_FREEMODE') == 2 then R.SetMediaItemInfo_Value(copy, 'I_FIXEDLANE', R.GetMediaItemInfo_Value(it, 'I_FIXEDLANE')) end
        R.GetSetMediaItemInfo_String(copy, 'P_EXT:jf_gen', guid, true)
        R.GetSetMediaItemInfo_String(copy, 'P_EXT:jf_cmds', '', true)
      end
      R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_len', ('%.6f'):format(len), true)
      R.SetMediaItemInfo_Value(it, 'D_LENGTH', trig[1].t)
    end
  end
  -- 0Y — вероятность (вся нота); ZT — tempo-маркер на своей строке (времена — в P_EXT:jf_tempo)
  local tempos = {}
  for _, c in ipairs(list) do
    if c.cmd == '0Y' then
      if math.random() > c.xx / 255 then muted = true end
    elseif c.cmd == 'ZT' then
      local bpm = c.xx > 0 and c.xx or 120
      local tt = R.TimeMap2_QNToTime(0, qn0 + c.off)
      R.SetTempoTimeSigMarker(0, -1, tt, -1, -1, bpm, 0, 0, false)
      tempos[#tempos + 1] = ('%.6f'):format(tt)
    end
  end
  if #tempos > 0 then R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_tempo', table.concat(tempos, ';'), true) end
  if penv then R.Envelope_SortPoints(penv) end
  if venv then R.Envelope_SortPoints(venv) end
  local has_p = false
  for _, c in ipairs(list) do if c.cmd == '0Y' then has_p = true end end
  if has_p then R.SetMediaItemInfo_Value(it, 'B_MUTE', muted and 1 or 0) end
end

return C
