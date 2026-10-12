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
--   0Uxx / 0Dxx питч вверх/вниз на xx/16 полутона за строку на всю длину
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
  ['0R'] = true, ['0Y'] = true, ZT = true, ZJ = true }
-- ZJxx — прыжок: когда плейхед доходит до строки события, трекер переводит
-- воспроизведение в слот xx последовательности (матрица). Хранится как
-- команда, огибающих не строит — исполняет main в кадре.

function C.init(m) model = m end

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
    if c.cmd == '0I' or c.cmd == '0O' then need_vol = true end
  end
  if is_midi then
    -- MIDI: только 0U/0D через pitchbend (±2 полутона = 8191)
    local _, _, ncc = R.MIDI_CountEvts(take)
    for i = ncc - 1, 0, -1 do
      local _, _, _, ppq, typ = R.MIDI_GetCC(take, i)
      if typ == 0xE0 then
        local tt = R.MIDI_GetProjTimeFromPPQPos(take, ppq)
        if tt >= pos - 1e-6 and tt <= pos + len + 1e-6 then R.MIDI_DeleteCC(take, i) end
      end
    end
    -- 12 окт: отрезки slide (0U / 0D со своих строк), pitchbend ±2 полутона, линейно между границами
    local tq = function(off) return R.TimeMap2_QNToTime(0, qn0 + off) - pos end
    local segs = C.segments(list, { ['0U'] = true, ['0D'] = true }, tq, len)
    if #segs > 0 then
      local function bend_at(semis) return math.max(0, math.min(16383, math.floor(8192 + semis / 2 * 8191 + 0.5))) end
      local acc, pts = 0, { { 0, 0 } }
      for _, sg in ipairs(segs) do
        local slope = (sg[3].xx / 16) * (sg[3].cmd == '0U' and 1 or -1) / row_sec
        pts[#pts + 1] = { sg[1], acc }
        acc = acc + slope * (sg[2] - sg[1])
        pts[#pts + 1] = { sg[2], acc }
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
  local muted = false
  -- 12 окт: команды со своих строк — отрезки (как в Furnace: до следующей того же рода, 00 — стоп)
  local ts = function(off) return (R.TimeMap2_QNToTime(0, qn0 + off) - pos) * rate end   -- время take (источник)
  local rs = row_sec * rate                                                              -- строка во времени take
  if penv then
    local slides = C.segments(list, { ['0U'] = true, ['0D'] = true }, ts, tlen)
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
        local slope = (sg[3].xx / 16) * (sg[3].cmd == '0U' and 1 or -1) / rs
        acc = acc + slope * (math.min(t, sg[2]) - sg[1])
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
      for _, sg in ipairs(slides) do add(sg[1]); add(sg[2]); add(sg[1] - 1e-4) end
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
  if venv and #vsegs > 0 then
    local vmin, vmax = env_range(venv, 0, 2)
    local acc = 1
    pt(venv, 0, 1)
    for _, sg in ipairs(vsegs) do
      local slope = (sg[3].xx / 256) * (sg[3].cmd == '0I' and 1 or -1) / rs
      pt(venv, sg[1], math.max(vmin, math.min(vmax, acc)))
      acc = acc + slope * (sg[2] - sg[1])
      pt(venv, sg[2], math.max(vmin, math.min(vmax, acc)))
    end
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
