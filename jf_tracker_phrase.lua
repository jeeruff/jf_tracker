-- jf_tracker_phrase.lua — фразы (30 окт, PLAN_PHRASES.md): кусок паттерна на многих треках → одна нота.
--
-- Источник — регион `ph:NAME` (паттерн библиотеки после =END): все айтемы, что начинаются в нём, на всех треках.
-- Триггер — MIDI-айтем с тейком `ph:NAME` и одной нотой: позиция — старт, длина — где фраза обрезается,
-- высота — транспонирование от C-4, velocity — громкость (100 = как в источнике). Сам триггер замьючен.
-- Вхождение — независимые копии айтемов источника (не пул: у каждой свои ноты) на их же треках, с метками
-- P_EXT:jf_phrc = GUID триггера. Связь живая через синхронизацию: после каждой правки (edit.run) триггеры,
-- чья подпись (источник + позиция / длина / высота / vel) поменялась, пересобирают копии; копии без своего
-- триггера или вне его — вон. Правка копии руками затирается: править источник.

local PH = {}
local R = reaper
local EPS = 1e-6
PH.BASE = 60        -- C-4: без транспонирования
PH.VEL_BASE = 100   -- velocity триггера 100 = громкость источника

-- имя фразы из имени тейка / региона ('ph:bass' → 'bass')
function PH.name_of(s) return s and s:match('^ph:(.+)$') end
function PH.semis(pitch) return (pitch or PH.BASE) - PH.BASE end
function PH.velf(vel) return (vel or PH.VEL_BASE) / PH.VEL_BASE end
function PH.clamp_pitch(p) return math.max(0, math.min(127, p)) end
function PH.scale_vel(v, f) return math.max(1, math.min(127, math.floor(v * f + 0.5))) end

-- раскладка вхождения (единицы — доли QN): trig = { q0, q1 } — старт и конец триггера, srcq — старт источника,
-- items = { { q0, q1 } } айтемы источника → { { k, q0, q1, cut } } копии: на месте триггера со сдвигом, айтем после
-- конца триггера не входит, торчащий — обрезан (cut)
function PH.place(trig, srcq, items)
  local out = {}
  for k, it in ipairs(items) do
    local a = trig.q0 + (it.q0 - srcq)
    if a < trig.q1 - EPS then
      local b = trig.q0 + (it.q1 - srcq)
      local cut = b > trig.q1 + EPS
      out[#out + 1] = { k = k, q0 = a, q1 = cut and trig.q1 or b, cut = cut }
    end
  end
  return out
end

-- ── REAPER ────────────────────────────────────────────────────────────────
local function ext(it, key, v)
  if v ~= nil then R.GetSetMediaItemInfo_String(it, 'P_EXT:' .. key, v, true); return v end
  local _, s = R.GetSetMediaItemInfo_String(it, 'P_EXT:' .. key, '', false)
  return s or ''
end
local function guid(it) local _, g = R.GetSetMediaItemInfo_String(it, 'GUID', '', false); return g or '' end
local function take_name(it)
  local tk = R.GetActiveTake(it)
  if not tk then return '' end
  local _, nm = R.GetSetMediaItemTakeInfo_String(tk, 'P_NAME', '', false)
  return nm or ''
end
local function qn(t) return R.TimeMap2_timeToQN(0, t) end
local function tm(q) return R.TimeMap2_QNToTime(0, q) end

-- регионы ph:* → { name = { pos, rgnend } }
local function sources()
  local out, i = {}, 0
  while true do
    local ret, isr, pos, rend, nm = R.EnumProjectMarkers3(0, i)
    if not ret or ret == 0 then break end
    local n = isr and PH.name_of(nm)
    if n and not out[n] then out[n] = { pos = pos, rgnend = rend } end
    i = i + 1
  end
  return out
end

-- нота триггера: первая нота тейка → pitch, vel
local function trig_note(it)
  local tk = R.GetActiveTake(it)
  if not (tk and R.TakeIsMIDI(tk)) then return nil end
  local _, nn = R.MIDI_CountEvts(tk)
  if nn < 1 then return nil end
  local _, _, _, _, _, _, pi, ve = R.MIDI_GetNote(tk, 0)
  return pi, ve
end

-- айтемы источника (кроме триггеров и копий фраз — фраза во фразе не поддерживается)
local function src_items(src, trs)
  local out = {}
  for _, tr in ipairs(trs) do
    for i = 0, R.CountTrackMediaItems(tr) - 1 do
      local it = R.GetTrackMediaItem(tr, i)
      local p = R.GetMediaItemInfo_Value(it, 'D_POSITION')
      if p >= src.pos - EPS and p < src.rgnend - EPS and not PH.name_of(take_name(it)) and ext(it, 'jf_phrc') == '' then
        out[#out + 1] = { it = it, tr = tr, p = p, l = R.GetMediaItemInfo_Value(it, 'D_LENGTH') }
      end
    end
  end
  return out
end

-- подпись источника: правка в нём (сдвиг, длина, ноты, высота) → вхождения заново
local function src_sig(list)
  local p = {}
  for _, e in ipairs(list) do
    local tk = R.GetActiveTake(e.it)
    local h = ''
    if tk and R.TakeIsMIDI(tk) then local _, hh = R.MIDI_GetHash(tk, false, ''); h = hh or ''
    elseif tk then h = ('%.4f:%.4f:%.4f'):format(R.GetMediaItemTakeInfo_Value(tk, 'D_PITCH'), R.GetMediaItemTakeInfo_Value(tk, 'D_VOL'), R.GetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS')) end
    p[#p + 1] = ('%s@%.6f+%.6f#%s'):format(tostring(e.tr), e.p, e.l, h)
  end
  return table.concat(p, '|')
end

-- копия одного айтема: независимый чанк (свой пул MIDI, без группы), транспонирование и громкость записаны
local function make_copy(e, at, len, cut, semis, vf, tg)
  local ok, ch = R.GetItemStateChunk(e.it, '', false)
  if not ok then return nil end
  ch = ch:gsub('\n%s*GUID %b{}', ''):gsub('\n%s*IGUID %b{}', '')
  ch = ch:gsub('POOLEDEVTS %b{}', function() return 'POOLEDEVTS ' .. R.genGuid('') end):gsub('\n%s*GROUP %d+', '')
  local it = R.AddMediaItemToTrack(e.tr)
  R.SetItemStateChunk(it, ch, false)
  R.SetMediaItemInfo_Value(it, 'D_POSITION', at)
  if cut then R.SetMediaItemInfo_Value(it, 'D_LENGTH', len) end
  local tk = R.GetActiveTake(it)
  if tk and R.TakeIsMIDI(tk) then
    if semis ~= 0 or math.abs(vf - 1) > 1e-9 then
      local _, nn = R.MIDI_CountEvts(tk)
      for k = 0, nn - 1 do
        local _, sel, mu, sp, ep, c, pi, ve = R.MIDI_GetNote(tk, k)
        R.MIDI_SetNote(tk, k, sel, mu, sp, ep, c, PH.clamp_pitch(pi + semis), PH.scale_vel(ve, vf), true)
      end
      R.MIDI_Sort(tk)
    end
  elseif tk then
    if semis ~= 0 then R.SetMediaItemTakeInfo_Value(tk, 'D_PITCH', R.GetMediaItemTakeInfo_Value(tk, 'D_PITCH') + semis) end
    if math.abs(vf - 1) > 1e-9 then R.SetMediaItemTakeInfo_Value(tk, 'D_VOL', R.GetMediaItemTakeInfo_Value(tk, 'D_VOL') * vf) end
  end
  ext(it, 'jf_phrc', tg)
  return it
end

-- синхронизация всех фраз проекта → число пересобранных триггеров + удалённых копий
function PH.sync()
  local trs = {}
  for ti = 0, R.CountTracks(0) - 1 do trs[#trs + 1] = R.GetTrack(0, ti) end
  local trigs, copies = {}, {}
  for _, tr in ipairs(trs) do
    for i = 0, R.CountTrackMediaItems(tr) - 1 do
      local it = R.GetTrackMediaItem(tr, i)
      local c = ext(it, 'jf_phrc')
      if c ~= '' then copies[#copies + 1] = { it = it, tr = tr, g = c }
      else
        local n = PH.name_of(take_name(it))
        if n then trigs[#trigs + 1] = { it = it, name = n, g = guid(it) } end
      end
    end
  end
  if #trigs == 0 and #copies == 0 then return 0 end
  local srcs = sources()
  local by = {}
  for _, c in ipairs(copies) do by[c.g] = by[c.g] or {}; table.insert(by[c.g], c) end
  local n = 0
  local live = {}
  for _, t in ipairs(trigs) do
    live[t.g] = true
    local src = srcs[t.name]
    local p = R.GetMediaItemInfo_Value(t.it, 'D_POSITION')
    local l = R.GetMediaItemInfo_Value(t.it, 'D_LENGTH')
    local pi, ve = trig_note(t.it)
    local list = src and src_items(src, trs) or {}
    local sig = ('%s|%.6f|%.6f|%s|%s|%s'):format(t.name, p, l, tostring(pi), tostring(ve), src and (('%.6f:%.6f:'):format(src.pos, src.rgnend) .. src_sig(list)) or '-')
    local mine = by[t.g] or {}
    local stray = false   -- копия вне своего триггера (её скопировали вместе с паттерном) — пересобрать
    for _, c in ipairs(mine) do
      local cp = R.GetMediaItemInfo_Value(c.it, 'D_POSITION')
      if cp < p - EPS or cp >= p + l - EPS then stray = true; break end
    end
    if stray or ext(t.it, 'jf_phrs') ~= sig or (#mine == 0 and #list > 0) then
      for _, c in ipairs(mine) do R.DeleteTrackMediaItem(c.tr, c.it) end
      by[t.g] = nil
      if R.GetMediaItemInfo_Value(t.it, 'B_MUTE') ~= 1 then R.SetMediaItemInfo_Value(t.it, 'B_MUTE', 1) end
      if src and pi then
        local qi = {}
        for k, e in ipairs(list) do qi[k] = { q0 = qn(e.p), q1 = qn(e.p + e.l) } end
        for _, pl in ipairs(PH.place({ q0 = qn(p), q1 = qn(p + l) }, qn(src.pos), qi)) do
          local e = list[pl.k]
          local at = tm(pl.q0)
          make_copy(e, at, tm(pl.q1) - at, pl.cut, PH.semis(pi), PH.velf(ve), t.g)
        end
      end
      ext(t.it, 'jf_phrs', sig)
      n = n + 1
    end
  end
  -- сироты: триггер удалён — его копии вон
  for g, list in pairs(by) do
    if not live[g] then for _, c in ipairs(list) do R.DeleteTrackMediaItem(c.tr, c.it); n = n + 1 end end
  end
  return n
end

return PH
