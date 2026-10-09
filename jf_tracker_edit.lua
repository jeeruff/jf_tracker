-- jf_tracker_edit.lua — ВСЕ записи трекера в проект REAPER.
--
-- Единственный модуль, который меняет проект. Каждая операция — свой
-- undo-блок (Undo_BeginBlock2/EndBlock2), чтобы штатный Ctrl+Z (и `u` в
-- нормальном режиме) откатывал её целиком. Данные остаются нативными:
-- удалить событие = удалить item / MIDI-ноту, вставить = скопировать item
-- из трека DEPOT или вставить ноту в MIDI-item, разрезать = SplitMediaItem /
-- две ноты, транспонировать = D_PITCH / pitch ноты.
--
-- Ячейки приходят из модели (jf_tracker_model.lua): голова события —
-- {kind='audio', item, take, …} или {kind='midi', item, take, pitch, ch,
-- row0, delay, …}. MIDI-нота ищется по (ppq старта, pitch, канал), потому
-- что индексы MIDI_GetNote в модели не хранятся.

local E = {}
local R = reaper
local EPS = 1e-6
local model

function E.init(m) model = m end

-- ── связь копий с инструментом (3 окт): метка P_EXT:jf_iid ─────────────
-- Все вставки трекера — копии item-инструмента с его меткой: модель считает
-- их одним инструментом (обрезка следующей нотой, питч, громкость — свойства
-- ноты). Слайс k — метка id#k, кусок — id@offs+len. Видоизменение копии
-- (растяжка, offset) даёт новую метку — копия уникальна (E.make_unique).
local IID = 'P_EXT:jf_iid'
function E.new_iid() return (R.genGuid(''):gsub('[{}%-]', ''):sub(1, 10)) end
function E.get_iid(it) local _, v = R.GetSetMediaItemInfo_String(it, IID, '', false); return v or '' end
function E.set_iid(it, v) R.GetSetMediaItemInfo_String(it, IID, v or '', true) end
-- метка инструмента item (ставит новую, если её нет) — без undo-блока: зовётся внутри run
function E.ensure_iid(it)
  local v = E.get_iid(it)
  if v == '' then v = E.new_iid(); E.set_iid(it, v) end
  return v
end
local function iid_base(v) return (v or ''):match('^([^#@~]*)') end
function E.make_unique(it)
  local v = E.get_iid(it)
  local u = (v ~= '' and v or E.new_iid()) .. '~' .. E.new_iid():sub(1, 6)
  E.set_iid(it, u)
  return v, u
end
-- видоизменённые копии (3 окт): растяжка / offset одной ноты делают её
-- уникальной (по умолчанию); main после правки спрашивает, применить ли то
-- же ко всем связанным (E.propagate). E.modified — { { it =, old = } }.
E.modified = {}
function E.note_modified(it)
  local v = E.get_iid(it)
  if v == '' then return end
  for _, m in ipairs(E.modified) do if m.it == it then return end end
  if #E.items_with_iid(v) < 2 then return end          -- связанных нет — не о чем спрашивать
  E.make_unique(it)
  E.modified[#E.modified + 1] = { it = it, old = v }
end
function E.take_modified() local m = E.modified; E.modified = {}; return m end
-- применить к связанным: offset, rate, сохранение питча и алгоритм — как у
-- изменённой копии; длина каждой — по отношению rate; метка возвращается общая
function E.propagate(mods)
  local n = 0
  E.run('apply to all linked', function()            -- E.run: run объявлен ниже
    for _, m in ipairs(mods) do
      local tk = R.ValidatePtr(m.it, 'MediaItem*') and R.GetActiveTake(m.it)
      if tk then
        local offs = R.GetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS')
        local rate = R.GetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE')
        local pp = R.GetMediaItemTakeInfo_Value(tk, 'B_PPITCH')
        local pm = R.GetMediaItemTakeInfo_Value(tk, 'I_PITCHMODE')
        for _, o in ipairs(E.items_with_iid(m.old)) do
          local ot = R.GetActiveTake(o)
          if ot then
            local r0 = R.GetMediaItemTakeInfo_Value(ot, 'D_PLAYRATE')
            R.SetMediaItemTakeInfo_Value(ot, 'D_STARTOFFS', offs)
            R.SetMediaItemTakeInfo_Value(ot, 'D_PLAYRATE', rate)
            R.SetMediaItemTakeInfo_Value(ot, 'B_PPITCH', pp)
            R.SetMediaItemTakeInfo_Value(ot, 'I_PITCHMODE', pm)
            if r0 > 0 and rate > 0 then R.SetMediaItemInfo_Value(o, 'D_LENGTH', R.GetMediaItemInfo_Value(o, 'D_LENGTH') * r0 / rate) end
            R.UpdateItemInProject(o)
            n = n + 1
          end
        end
        E.set_iid(m.it, m.old)
      end
    end
  end)
  return n
end

-- все items проекта с меткой v (для «применить ко всем связанным»)
function E.items_with_iid(v)
  local out = {}
  if not v or v == '' then return out end
  for ti = 0, R.CountTracks(0) - 1 do
    local tr = R.GetTrack(0, ti)
    for i = 0, R.CountTrackMediaItems(tr) - 1 do
      local it = R.GetTrackMediaItem(tr, i)
      if E.get_iid(it) == v then out[#out + 1] = it end
    end
  end
  return out
end


-- ── undo-обёртка ──────────────────────────────────────────────────────────
-- E.after — хук после каждой правки, ВНУТРИ того же undo-блока (синхронизация
-- алиасов паттернов, jf_tracker_alias.lua). Защита от рекурсии — E.in_after.
E.after = nil

-- ── страховка сэмплов (2 окт) ─────────────────────────────────────────────
-- Инструменты трека живут в его items: удалил последний item с файлом —
-- сэмпл пропал из пула. Внешний run() переписывает аудиофайлы каждого трека
-- до и после правки; файл, который был в последовательности (до =END /
-- вне библиотеки) и исчез с трека совсем, кладётся в библиотеку трека
-- (за =LIB, E.depot_add) в том же undo-шаге. Библиотечный item, удалённый
-- нарочно, не возвращается. E.no_rescue — правка, где файл уходит намеренно
-- (замена сэмпла). E.rescued — список спасённых имён для сообщения.
E.keep_samples = true
E.rescued = nil
local depth = 0
-- имя файла по источнику — кэш на одну правку (census до и после)
local rf_cache
local function root_file(src)
  if rf_cache and src and rf_cache[src] then return rf_cache[src] end
  local key = src
  local p = src and R.GetMediaSourceParent and R.GetMediaSourceParent(src)
  local n = 0
  while p and n < 8 do src = p; p = R.GetMediaSourceParent(src); n = n + 1 end
  local fn = src and R.GetMediaSourceFileName(src, '') or ''
  if rf_cache and key then rf_cache[key] = fn end
  return fn
end
local function census()
  local out = {}
  local lib = model and model.lib_pos and model.lib_pos()
  local endp = model and model.marker_pos and model.marker_pos(model.END_MARKER)
  for ti = 0, R.CountTracks(0) - 1 do
    local tr = R.GetTrack(0, ti)
    local _, name = R.GetTrackName(tr)
    if not model or not model.is_lib_name(name) then
      local set
      for i = 0, R.CountTrackMediaItems(tr) - 1 do
        local it = R.GetTrackMediaItem(tr, i)
        local tk = R.GetActiveTake(it)
        if tk and not R.TakeIsMIDI(tk) then
          local fn = root_file(R.GetMediaItemTake_Source(tk))
          if fn ~= '' then
            local pos = R.GetMediaItemInfo_Value(it, 'D_POSITION')
            local in_lib = lib ~= nil and pos >= lib - 1e-6 and (endp == nil or pos >= endp - 1e-6)
            set = set or {}
            set[fn] = set[fn] or false
            if not in_lib then set[fn] = true end
          end
        end
      end
      if set then out[tr] = set end
    end
  end
  return out
end
local function rescue(pre)
  local post = census()
  local saved = {}
  for tr, set in pairs(pre) do
    if R.ValidatePtr(tr, 'MediaTrack*') then
      for fn, in_seq in pairs(set) do
        if in_seq and not (post[tr] and post[tr][fn] ~= nil) and not E.lib_has(fn, tr) then
          if E.depot_add(fn, tr) then saved[#saved + 1] = fn:match('[^/]+$') or fn end
        end
      end
    end
  end
  if #saved > 0 then E.rescued = saved end
end

E.last_ms, E.last_desc = 0, ''     -- длительность последней внешней правки (пульс hb)
local function run(desc, fn)
  depth = depth + 1
  local pre
  local t_run = R.time_precise and R.time_precise()
  if depth == 1 then
    E.rescued = nil
    rf_cache = {}
    if E.keep_samples and not E.no_rescue then local okc, c = pcall(census); if okc then pre = c end end
  end
  R.Undo_BeginBlock2(0)
  R.PreventUIRefresh(1)
  local ok, err = pcall(fn)
  if ok and E.after and not E.in_after then
    E.in_after = true
    local ok2, err2 = pcall(E.after, desc)
    E.in_after = false
    if not ok2 then err = err2; ok = false end
  end
  if ok and pre then pcall(rescue, pre) end
  depth = depth - 1
  if depth == 0 then E.no_rescue = nil; rf_cache = nil end
  R.PreventUIRefresh(-1)
  R.Undo_EndBlock2(0, 'jf_tracker: ' .. desc, -1)
  R.UpdateArrange()
  if model then model.invalidate() end
  if depth == 0 and t_run then E.last_ms = (R.time_precise() - t_run) * 1000; E.last_desc = desc end
  if not ok then error(err, 0) end
end
E.run = run

-- ── время ─────────────────────────────────────────────────────────────────
local function row_time(row, lpb, delay)
  return R.TimeMap2_QNToTime(0, (row + (delay or 0) / 256) / lpb)
end
E.row_time = row_time
-- свинг (6 окт): глобальный = свинг сетки проекта REAPER (GetSetProjectGrid:
-- swingmode 1, swingamt −1..1), единица — деление сетки g. Как в REAPER,
-- второе деление пары сдвинуто на amt·g (33 % ≈ триоль, MPC 66 %); строки
-- между делениями — кусочно-линейно внутри пары [2kg, 2kg + 2g). Свинг
-- применяется к ВСТАВКЕ и квантизации (точки, ноты, слайсы, item); стоящие
-- события не трогаются. У item флаг swing (P_EXT:jf_noswing, по умолчанию вкл)
E.sw = { on = false, amt = 0, div = 0.25 }        -- div — в QN
function E.swing_read()
  if not R.GetSetProjectGrid then return end
  local _, div, mode, amt = R.GetSetProjectGrid(0, false)
  E.sw.amt = math.max(-1, math.min(1, amt or 0))
  E.sw.on = (mode or 0) == 1 and math.abs(E.sw.amt) > 1e-6
  E.sw.div = (div or 0.0625) * 4
end
-- on / amt (−1..1) / div (доля целой ноты, как у REAPER: 1/16 = 0.0625); nil — как есть
function E.swing_set(on, amt, div)
  if not R.GetSetProjectGrid then return end
  local _, d0, m0, a0 = R.GetSetProjectGrid(0, false)
  if on == nil then on = (m0 or 0) == 1 end
  R.GetSetProjectGrid(0, true, div or d0, on and 1 or 0, math.max(-1, math.min(1, amt or a0 or 0)))
  R.UpdateTimeline()
  E.swing_read()
end
function E.swing_qn(q)
  local s = E.sw
  if not s.on or s.div <= 0 then return q end
  local g = s.div
  local p0 = math.floor(q / (2 * g) + 1e-9) * 2 * g
  local x = q - p0
  local m = g * (1 + math.max(-0.99, math.min(0.99, s.amt)))   -- сдвинутая середина пары
  if x <= g then return p0 + x * m / g end
  return p0 + m + (x - g) * (2 * g - m) / g
end
function E.item_swing(it)
  if not (it and R.ValidatePtr(it, 'MediaItem*')) then return true end
  local _, v = R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_noswing', '', false)
  return v ~= '1'
end
function E.set_item_swing(it, on)
  if it and R.ValidatePtr(it, 'MediaItem*') then R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_noswing', on and '' or '1', true) end
end
-- время строки со свингом; item со свингом off — ровно
function E.swing_time(row, lpb, item)
  if item and not E.item_swing(item) then return row_time(row, lpb, 0) end
  return R.TimeMap2_QNToTime(0, E.swing_qn(row / lpb))
end
-- время → строка и задержка xx/256 (3 окт: точный стык слайсов при шаге auto)
function E.row_of_time(t, lpb)
  local rf = R.TimeMap2_timeToQN(0, t) * lpb
  local row = math.floor(rf + 1e-6)
  local d = math.floor((rf - row) * 256 + 0.5)
  if d >= 256 then row, d = row + 1, 0 end
  return row, d
end
function E.item_end(it) return R.GetMediaItemInfo_Value(it, 'D_POSITION') + R.GetMediaItemInfo_Value(it, 'D_LENGTH') end

-- ── поиск MIDI-ноты по голове ─────────────────────────────────────────────
-- индекс ноты take по (ppq старта ±2, pitch, ch)
local function note_index(take, ppq, pitch, ch)
  local _, n = R.MIDI_CountEvts(take)
  local best, bestd
  for i = 0, n - 1 do
    local _, _, _, sppq, _, chan, p = R.MIDI_GetNote(take, i)
    if p == pitch and chan == ch then
      local d = math.abs(sppq - ppq)
      if d <= 2 and (not bestd or d < bestd) then best, bestd = i, d end
    end
  end
  return best
end

-- ppq старта ноты из головы: время строки + delay → ppq take
local function head_ppq(head, lpb)
  local t = row_time(head.row0, lpb, head.delay)
  return R.MIDI_GetPPQPosFromProjTime(head.take, t)
end

local function midi_note(head, lpb)
  local i = note_index(head.take, head_ppq(head, lpb), head.pitch, head.ch)
  if not i then return nil end
  local _, sel, muted, sppq, eppq, ch, pitch, vel = R.MIDI_GetNote(head.take, i)
  return i, { sel = sel, muted = muted, sppq = sppq, eppq = eppq, ch = ch, pitch = pitch, vel = vel }
end

-- ── удаление ──────────────────────────────────────────────────────────────
function E.delete(heads, lpb)
  if #heads == 0 then return end
  run('delete ' .. #heads, function()
    -- MIDI: удалять с конца индексов, поэтому сначала собрать
    local by_take = {}
    for _, h in ipairs(heads) do
      if h.kind == 'audio' then
        local tr = R.GetMediaItem_Track(h.item)
        if tr then R.DeleteTrackMediaItem(tr, h.item) end
      elseif h.kind == 'midi' then
        local i = midi_note(h, lpb)
        if i then
          by_take[h.take] = by_take[h.take] or {}
          table.insert(by_take[h.take], i)
        end
      end
    end
    for take, idx in pairs(by_take) do
      table.sort(idx, function(a, b) return a > b end)
      R.MIDI_DisableSort(take)
      for _, i in ipairs(idx) do R.MIDI_DeleteNote(take, i) end
      R.MIDI_Sort(take)
    end
  end)
end

-- ── mute ──────────────────────────────────────────────────────────────────
-- flag: true/false — установить, nil — переключить каждое
function E.mute(heads, lpb, flag)
  if #heads == 0 then return end
  run('mute', function()
    for _, h in ipairs(heads) do
      if h.kind == 'audio' then
        local cur = R.GetMediaItemInfo_Value(h.item, 'B_MUTE') == 1
        local v = flag; if v == nil then v = not cur end
        R.SetMediaItemInfo_Value(h.item, 'B_MUTE', v and 1 or 0)
      elseif h.kind == 'midi' then
        local i, n = midi_note(h, lpb)
        if i then
          local v = flag; if v == nil then v = not n.muted end
          R.MIDI_SetNote(h.take, i, n.sel, v, n.sppq, n.eppq, n.ch, n.pitch, n.vel, false)
        end
      end
    end
  end)
end

-- ── транспозиция ──────────────────────────────────────────────────────────
-- Режим питча на трек (E.pitch_mode(head) → 'shift' | 'resample'):
--   shift    — D_PITCH, длина сохраняется (алгоритм I_PITCHMODE);
--   resample — D_PLAYRATE = 2^(semis/12), B_PPITCH = 0, длина item
--              пересчитывается (классика PT2: выше — короче).
E.pitch_mode = function(head) return 'shift' end

local function set_rate(h, rate)
  local old = R.GetMediaItemTakeInfo_Value(h.take, 'D_PLAYRATE')
  local len = R.GetMediaItemInfo_Value(h.item, 'D_LENGTH')
  R.SetMediaItemTakeInfo_Value(h.take, 'D_PLAYRATE', rate)
  R.SetMediaItemTakeInfo_Value(h.take, 'B_PPITCH', 0)
  if old > 0 then R.SetMediaItemInfo_Value(h.item, 'D_LENGTH', len * old / rate) end
end

local function audio_semis(h)
  local pitch = R.GetMediaItemTakeInfo_Value(h.take, 'D_PITCH')
  local rate = R.GetMediaItemTakeInfo_Value(h.take, 'D_PLAYRATE')
  local pp = R.GetMediaItemTakeInfo_Value(h.take, 'B_PPITCH') == 1
  return model.take_semitones(pitch, rate, pp)
end

local function audio_set_semis(h, semis)
  if E.pitch_mode(h) == 'resample' then
    R.SetMediaItemTakeInfo_Value(h.take, 'D_PITCH', 0)
    set_rate(h, 2 ^ (semis / 12))
  else
    R.SetMediaItemTakeInfo_Value(h.take, 'D_PITCH', semis)
  end
end

-- питч ноты-слайса (4 окт, Option + нота): D_PITCH, скорость не трогается —
-- длина и кусок слайса те же
function E.slice_pitch(it, semis)
  local tk = R.GetActiveTake(it)
  local ref = E.inst_ref and E.inst_ref(it)
  local rtk = ref and ref ~= it and R.GetActiveTake(ref)
  local base = rtk and R.GetMediaItemTakeInfo_Value(rtk, 'D_PITCH') or 0   -- transpose инструмента — база (6 окт)
  if tk then R.SetMediaItemTakeInfo_Value(tk, 'D_PITCH', base + semis) end
end
-- полутоны инструмента ноты (его item в lib: D_PITCH / rate); 0 — нет / сам
E.inst_ref = nil                      -- ставит main: item → item-инструмент из снимка
local function inst_base(it)
  local ref = E.inst_ref and E.inst_ref(it)
  local tk = ref and ref ~= it and R.GetActiveTake(ref)
  if not tk then return 0 end
  return model.take_semitones(R.GetMediaItemTakeInfo_Value(tk, 'D_PITCH'), R.GetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE'), R.GetMediaItemTakeInfo_Value(tk, 'B_PPITCH') == 1)
end
E.inst_base = inst_base

function E.transpose(heads, lpb, semis)
  if #heads == 0 or semis == 0 then return end
  run(('transpose %+d'):format(semis), function()
    for _, h in ipairs(heads) do
      if h.kind == 'audio' and h.take then
        audio_set_semis(h, audio_semis(h) + semis)
      elseif h.kind == 'midi' then
        local i, n = midi_note(h, lpb)
        if i then
          local p = math.max(0, math.min(127, n.pitch + semis))
          R.MIDI_SetNote(h.take, i, n.sel, n.muted, n.sppq, n.eppq, n.ch, p, n.vel, false)
        end
      end
    end
  end)
end

-- задать высоту: MIDI — pitch, аудио — D_PITCH = pitch − BASE_NOTE
function E.set_pitch(heads, lpb, pitch)
  if #heads == 0 then return end
  run('pitch', function()
    for _, h in ipairs(heads) do
      local _, slk = h.kind == 'audio' and R.GetSetMediaItemInfo_String(h.item, 'P_EXT:jf_slice', '', false)
      if h.kind == 'audio' and h.take and tonumber(slk) then
        -- слайс (4 окт, вечер): нота — его высота (слайс — Sxx)
        E.slice_pitch(h.item, pitch - model.BASE_NOTE)
      elseif h.kind == 'audio' and h.take then
        audio_set_semis(h, inst_base(h.item) + pitch - model.BASE_NOTE)   -- от транспоза инструмента (6 окт)
      elseif h.kind == 'midi' then
        local i, n = midi_note(h, lpb)
        if i then R.MIDI_SetNote(h.take, i, n.sel, n.muted, n.sppq, n.eppq, n.ch, pitch, n.vel, false) end
      end
    end
  end)
end

-- ── vol / delay ───────────────────────────────────────────────────────────
-- громкость item в dB и нормализация (редактор сэмпла, 1 окт).
-- CalculateNormalization(src, 2 = peak, 0 dB, from, to) отдаёт gain для
-- источника без учёта текущих громкостей → item D_VOL = gain / take D_VOL.
function E.item_vol(it, db)
  run('item volume', function() R.SetMediaItemInfo_Value(it, 'D_VOL', 10 ^ (db / 20)) end)
end
function E.normalize(it)
  local g
  run('normalize item', function()
    local take = R.GetActiveTake(it)
    if not take or not R.CalculateNormalization then return end
    local src = R.GetMediaItemTake_Source(take)
    local offs = R.GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS')
    local span = R.GetMediaItemInfo_Value(it, 'D_LENGTH') * R.GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE')
    g = R.CalculateNormalization(src, 2, 0, offs, offs + span)
    if g and g > 0 then
      local tv = R.GetMediaItemTakeInfo_Value(take, 'D_VOL')
      R.SetMediaItemInfo_Value(it, 'D_VOL', g / (tv ~= 0 and tv or 1))
    end
  end)
  return g
end

-- vol: 0x80 = 0 dB; аудио — D_VOL item, MIDI — velocity (до 7F)
function E.set_vol(heads, lpb, v)
  if #heads == 0 then return end
  v = math.max(0, math.min(255, math.floor(v + 0.5)))
  run('vol', function()
    for _, h in ipairs(heads) do
      if h.kind == 'audio' then R.SetMediaItemInfo_Value(h.item, 'D_VOL', v / 128)
      elseif h.kind == 'midi' then
        local i, n = midi_note(h, lpb)
        if i then R.MIDI_SetNote(h.take, i, n.sel, n.muted, n.sppq, n.eppq, n.ch, n.pitch, math.max(1, math.min(127, v)), false) end
      end
    end
  end)
end

-- delay: сдвиг старта внутри строки, xx/256
function E.set_delay(heads, lpb, d)
  if #heads == 0 then return end
  d = math.max(0, math.min(255, math.floor(d + 0.5)))
  run('delay', function()
    for _, h in ipairs(heads) do
      local t = row_time(h.row0, lpb, d)
      if h.kind == 'audio' then R.SetMediaItemInfo_Value(h.item, 'D_POSITION', t)
      elseif h.kind == 'midi' then
        local i, n = midi_note(h, lpb)
        if i then
          local sp = R.MIDI_GetPPQPosFromProjTime(h.take, t)
          local ep = n.eppq
          if ep <= sp + 1 then ep = sp + (n.eppq - n.sppq) end
          R.MIDI_SetNote(h.take, i, n.sel, n.muted, sp, ep, n.ch, n.pitch, n.vel, false)
        end
      end
    end
  end)
end

-- ── команды (этап 5) ──────────────────────────────────────────────────────
-- Буква + xx (0..255) → свойство item/take. Только аудио; MIDI-CC — потом.
local function src_len(h)
  local src = h.take and R.GetMediaItemTake_Source(h.take)
  if not src then return 0 end
  local len, is_qn = R.GetMediaSourceLength(src)
  if is_qn then return R.TimeMap2_QNToTime(0, len) end
  return len or 0
end

local function apply_fx(h, lpb, cmd, xx)
  if h.kind ~= 'audio' or not h.take then return end
  local it, tk = h.item, h.take
  local pos = R.GetMediaItemInfo_Value(it, 'D_POSITION')
  local len = R.GetMediaItemInfo_Value(it, 'D_LENGTH')
  local qn0 = R.TimeMap2_timeToQN(0, pos)
  if cmd == '9' then R.SetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS', xx / 255 * src_len(h)); E.note_modified(it)
  elseif cmd == '8' then R.SetMediaItemTakeInfo_Value(tk, 'D_PAN', xx / 255 * 2 - 1)
  elseif cmd == 'C' then R.SetMediaItemInfo_Value(it, 'D_VOL', xx / 128)
  elseif cmd == 'I' then R.SetMediaItemInfo_Value(it, 'D_FADEINLEN', R.TimeMap2_QNToTime(0, qn0 + xx / 16 / lpb) - pos)
  elseif cmd == 'O' then
    local qn1 = R.TimeMap2_timeToQN(0, pos + len)
    R.SetMediaItemInfo_Value(it, 'D_FADEOUTLEN', pos + len - R.TimeMap2_QNToTime(0, qn1 - xx / 16 / lpb))
  elseif cmd == 'L' then R.SetMediaItemInfo_Value(it, 'B_LOOPSRC', xx > 0 and 1 or 0)
  elseif cmd == 'M' then R.SetMediaItemTakeInfo_Value(tk, 'I_CHANMODE', math.max(0, math.min(4, xx)))
  elseif cmd == 'P' then R.SetMediaItemTakeInfo_Value(tk, 'D_PITCH', xx - 128)
  elseif cmd == 'S' then
    -- слайс xx нарезанного инструмента (P_EXT:jf_slices у item); без нарезки —
    -- offset xx/256 источника (как Sxx в Renoise)
    local slices, base = E.item_slices(it)
    -- нота-слайс (3 окт): своей таблицы нет — берётся у исходника (та же метка
    -- jf_iid до #), Sxx = слайс xx; исходник с маркерами — кусок без них
    local _, own_k = R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_slice', '', false)
    if #slices == 0 and tonumber(own_k) then
      for _, c in ipairs(E.items_with_iid(iid_base(E.get_iid(it)))) do
        local sl, b0 = E.item_slices(c)
        if #sl > 0 then
          local k = math.max(1, math.min(#sl, xx))
          local rtk = R.GetActiveTake(c)
          local rate = R.GetMediaItemTakeInfo_Value(rtk, 'D_PLAYRATE')
          local a0, b1 = sl[k], sl[k + 1] or b0.len or R.GetMediaItemInfo_Value(c, 'D_LENGTH')
          local pts = E.root_markers(rtk)
          if pts then E.unwarp_piece(it, pts, rate, a0, b1)
          else
            R.SetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE', rate)
            R.SetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS', (b0.offs or 0) + a0 * rate)
            R.SetMediaItemInfo_Value(it, 'D_LENGTH', b1 - a0)
          end
          R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_slice', tostring(k), true)
          E.set_iid(it, iid_base(E.get_iid(c)) .. '#' .. k)
          return
        end
      end
    end
    if #slices > 0 then
      local k = math.max(1, math.min(#slices, xx))
      local bs = E.bsync_of(it)
      if bs then R.SetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE', bs.rate0) end
      local rate = R.GetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE')
      local t0 = slices[k]
      local t1 = (not E.playthru(it) and slices[k + 1]) or (base.len or len)   -- playthru: до конца сэмпла (6 окт)
      R.SetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS', (base.offs or 0) + t0 * rate)
      R.SetMediaItemInfo_Value(it, 'D_LENGTH', t1 - t0)
      R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_slice', tostring(k), true)
      E.set_iid(it, iid_base(E.ensure_iid(it)) .. '#' .. k)
      if bs then E.bsync_fit(it, bs) end
    else
      R.SetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS', xx / 256 * src_len(h))
      E.note_modified(it)                               -- смещение копии — видоизменение (как 9xx)
    end
  elseif cmd == 'T' then
    -- beatsync (как в Renoise): источник от offset растянут ровно на xx строк
    if xx > 0 then
      local target = R.TimeMap2_QNToTime(0, qn0 + xx / lpb) - pos
      local avail = src_len(h) - R.GetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS')
      if target > 0 and avail > 0 then
        R.SetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE', avail / target)
        R.SetMediaItemTakeInfo_Value(tk, 'B_PPITCH', 1)
        R.SetMediaItemInfo_Value(it, 'D_LENGTH', target)
        E.note_modified(it)
      end
    else
      R.SetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE', 1)
    end
  end
end

-- таблица слайсов item: { t1, t2, … } (секунды от начала item) и база
-- { offs = D_STARTOFFS при нарезке, len = длина item при нарезке }
-- 6 окт: слайсы привязаны к ВОЛНЕ, не ко времени item. В P_EXT лежат секунды
-- item при rate нарезки (третье поле базы: offs;len;rate0); читаются в секундах
-- item при ТЕКУЩЕМ rate (beatsync — его исходный rate0): t · rate0 / rate.
-- Позиция в источнике = offs + t · rate — та же точка волны при любом rate
-- (раньше смена rate сдвигала все слайсы). Старая нарезка без rate0: rate0
-- оценивается по длине (rate менялся вместе с длиной item), иначе = текущий
local function slice_rate_now(it)
  local tk = R.GetActiveTake(it)
  local bs = E.bsync_of and E.bsync_of(it)
  if bs and bs.rate0 then return bs.rate0 end
  return tk and R.GetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE') or 1
end
function E.item_slices(it)
  local ok, str = R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_slices', '', false)
  local out = {}
  if ok and str and str ~= '' then
    for v in str:gmatch('[^,]+') do out[#out + 1] = tonumber(v) end
  end
  local _, b = R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_slice_base', '', false)
  local base = {}
  if b and b ~= '' then
    local o, l, r0 = b:match('([^;]+);([^;]+);?([^;]*)')
    base.offs, base.len, base.rate0 = tonumber(o), tonumber(l), tonumber(r0)
  end
  if #out > 0 then
    local rn = slice_rate_now(it)
    local r0 = base.rate0
    if not r0 and base.len and base.len > 0 then
      local ln = R.GetMediaItemInfo_Value(it, 'D_LENGTH')
      r0 = math.abs(ln - base.len) > 1e-3 and (rn * ln / base.len) or rn
      -- старую базу дописать rate0 (6 окт): дальше нарезка не зависит от длины
      R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_slice_base', ('%.6f;%.6f;%.6f'):format(base.offs or 0, base.len, r0), true)
      base.rate0 = r0
    end
    local f = (r0 and rn > 1e-9) and (r0 / rn) or 1
    if math.abs(f - 1) > 1e-9 then
      for i = 1, #out do out[i] = out[i] * f end
      if base.len then base.len = base.len * f end
    end
  end
  return out, base
end

-- записать нарезку в item-инструмент (пустая таблица — снять)
-- Opt+Enter в браузере (7 окт): файл — новым слайсом в конец инструмента.
-- Слайсы — позиции в одном item, поэтому файл ставится вплотную за сэмпл
-- инструмента и они склеиваются нативным glue REAPER (новый файл); слайсы
-- прежние + стык. Возвращает новый item (или nil)
function E.slice_append(it, path)
  if not (it and R.ValidatePtr(it, 'MediaItem*')) then return nil end
  local out
  run('add the file as a slice', function()
    local tr = R.GetMediaItem_Track(it)
    local pos, len = R.GetMediaItemInfo_Value(it, 'D_POSITION'), R.GetMediaItemInfo_Value(it, 'D_LENGTH')
    local old = E.item_slices(it)
    local tk0 = R.GetActiveTake(it)
    local name = ''
    if tk0 then local _, n = R.GetSetMediaItemTakeInfo_String(tk0, 'P_NAME', '', false); name = n or '' end
    local src = R.PCM_Source_CreateFromFile(path)
    if not src then return end
    local slen = R.GetMediaSourceLength(src)
    if not slen or slen <= 0 then return end
    local nit = R.AddMediaItemToTrack(tr)
    local ntk = R.AddTakeToMediaItem(nit)
    R.SetMediaItemTake_Source(ntk, src)
    R.SetMediaItemInfo_Value(nit, 'D_POSITION', pos + len)
    R.SetMediaItemInfo_Value(nit, 'D_LENGTH', slen)
    R.SetMediaItemInfo_Value(nit, 'I_FIXEDLANE', R.GetMediaItemInfo_Value(it, 'I_FIXEDLANE'))
    R.SelectAllMediaItems(0, false)
    R.SetMediaItemSelected(it, true); R.SetMediaItemSelected(nit, true)
    R.Main_OnCommand(41588, 0)                       -- Item: Glue items
    local g = R.GetSelectedMediaItem(0, 0)
    if not g then return end
    local sl = {}
    if #old == 0 then sl[1] = 0 else for _, t in ipairs(old) do sl[#sl + 1] = t end end
    sl[#sl + 1] = len
    local parts = {}
    for _, t in ipairs(sl) do parts[#parts + 1] = ('%.6f'):format(t) end
    R.GetSetMediaItemInfo_String(g, 'P_EXT:jf_slices', table.concat(parts, ','), true)
    local gtk = R.GetActiveTake(g)
    R.GetSetMediaItemInfo_String(g, 'P_EXT:jf_slice_base', ('%.6f;%.6f;%.6f'):format(gtk and R.GetMediaItemTakeInfo_Value(gtk, 'D_STARTOFFS') or 0, R.GetMediaItemInfo_Value(g, 'D_LENGTH'), 1), true)
    if gtk and name and name ~= '' then R.GetSetMediaItemTakeInfo_String(gtk, 'P_NAME', name, true) end
    out = g
  end)
  if model then model.invalidate() end
  return out
end

function E.set_slices(it, slices)
  run('slices', function()
    local parts = {}
    for _, t in ipairs(slices) do parts[#parts + 1] = ('%.6f'):format(t) end
    R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_slices', table.concat(parts, ','), true)
    local tk = R.GetActiveTake(it)
    local offs = tk and R.GetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS') or 0
    R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_slice_base', #slices > 0 and ('%.6f;%.6f;%.6f'):format(offs, R.GetMediaItemInfo_Value(it, 'D_LENGTH'), slice_rate_now(it)) or '', true)
  end)
end

-- команды-огибающие/генераторы (jf_tracker_cmds): хранятся в P_EXT:jf_cmds,
-- пересобираются при каждой правке
E.cmds = nil
E.prev_semis = function(head) return nil end   -- переопределяет main (для Gxx)

-- скрэмбл (4 окт, по мотивам Paketti): ноты-слайсы остаются на местах, а
-- номера слайсов перемешиваются между ними — внутри каждого сэмпла (метка
-- jf_iid до #). Длина ноты — не длиннее прежней (иначе налезет на следующую
-- и уйдёт в новую подколонку). rnd(n) → 1..n (тесты подставляют свой)
function E.scramble(heads, lpb, rnd)
  rnd = rnd or math.random
  local groups, order = {}, {}
  for _, h in ipairs(heads) do
    if h.kind == 'audio' and h.item and R.ValidatePtr(h.item, 'MediaItem*') then
      local _, k = R.GetSetMediaItemInfo_String(h.item, 'P_EXT:jf_slice', '', false)
      k = tonumber(k)
      if k then
        local g = iid_base(E.get_iid(h.item))
        if not groups[g] then groups[g] = {}; order[#order + 1] = g end
        local t = groups[g]
        t[#t + 1] = { h = h, k = k, len = R.GetMediaItemInfo_Value(h.item, 'D_LENGTH') }
      end
    end
  end
  local n = 0
  run('scramble slices', function()
    for _, g in ipairs(order) do
      local t = groups[g]
      if #t >= 2 then
        local ks = {}
        for i, e in ipairs(t) do ks[i] = e.k end
        for i = #ks, 2, -1 do local j = rnd(i); ks[i], ks[j] = ks[j], ks[i] end
        for i, e in ipairs(t) do
          if ks[i] ~= e.k then
            apply_fx(e.h, lpb, 'S', ks[i])
            if R.GetMediaItemInfo_Value(e.h.item, 'D_LENGTH') > e.len then R.SetMediaItemInfo_Value(e.h.item, 'D_LENGTH', e.len) end
            n = n + 1
          end
        end
      end
    end
  end)
  return n
end

-- поменять местами два события (4 окт, gw / :sw): позиции меняются, каждое
-- событие уносит свою длину и звук; только аудио (MIDI-нота — не свой item)
function E.swap_events(a, b)
  if not (a and b and a.item and b.item) or a.item == b.item then return false end
  if a.kind ~= 'audio' or b.kind ~= 'audio' then return false end
  if not (R.ValidatePtr(a.item, 'MediaItem*') and R.ValidatePtr(b.item, 'MediaItem*')) then return false end
  run('swap events', function()
    local pa = R.GetMediaItemInfo_Value(a.item, 'D_POSITION')
    local pb = R.GetMediaItemInfo_Value(b.item, 'D_POSITION')
    R.SetMediaItemInfo_Value(a.item, 'D_POSITION', pb)
    R.SetMediaItemInfo_Value(b.item, 'D_POSITION', pa)
  end)
  return true
end

function E.set_fx(heads, lpb, cmd, xx)
  if #heads == 0 then return end
  run('fx ' .. cmd, function()
    for _, h in ipairs(heads) do
      if E.cmds and E.cmds.LETTERS[cmd] then
        if h.item then E.cmds.put(h.item, cmd, xx); E.cmds.rebuild(h, lpb, E.prev_semis(h)) end
      else
        apply_fx(h, lpb, cmd, xx)
      end
    end
  end)
end

function E.clear_fx(heads, lpb, cmd)
  if E.cmds and E.cmds.LETTERS[cmd] then
    run('fx clear ' .. cmd, function()
      for _, h in ipairs(heads) do if h.item then E.cmds.put(h.item, cmd, nil); E.cmds.rebuild(h, lpb, E.prev_semis(h)) end end
    end)
    return
  end
  local defaults = { ['9'] = 0, ['8'] = 128, C = 128, I = 0, O = 0, L = 1, M = 0, S = 0, T = 0 }
  if defaults[cmd] then E.set_fx(heads, lpb, cmd, defaults[cmd]) end
end

-- ── разрез ────────────────────────────────────────────────────────────────
-- Разрезать события, накрывающие строку row, по её началу.
function E.split(heads, lpb, row)
  if #heads == 0 then return end
  local t = row_time(row, lpb, 0)
  run('split', function()
    for _, h in ipairs(heads) do
      if h.kind == 'audio' then
        local pos = R.GetMediaItemInfo_Value(h.item, 'D_POSITION')
        local len = R.GetMediaItemInfo_Value(h.item, 'D_LENGTH')
        if t > pos + 1e-6 and t < pos + len - 1e-6 then R.SplitMediaItem(h.item, t) end
      elseif h.kind == 'midi' then
        local i, n = midi_note(h, lpb)
        if i then
          local ppq = R.MIDI_GetPPQPosFromProjTime(h.take, t)
          if ppq > n.sppq + 1 and ppq < n.eppq - 1 then
            R.MIDI_SetNote(h.take, i, n.sel, n.muted, n.sppq, ppq, n.ch, n.pitch, n.vel, true)
            R.MIDI_InsertNote(h.take, n.sel, n.muted, ppq, n.eppq, n.ch, n.pitch, n.vel, true)
            R.MIDI_Sort(h.take)
          end
        end
      end
    end
  end)
end

-- ── note-off: укоротить событие до строки ─────────────────────────────────
function E.note_off(heads, lpb, row)
  if #heads == 0 then return end
  local t = row_time(row + (E.OFF_END and 1 or 0), lpb, 0)   -- 8 окт: OFF в конце строки — нота звучит и на ней
  run('note off', function()
    for _, h in ipairs(heads) do
      if h.kind == 'audio' then
        local pos = R.GetMediaItemInfo_Value(h.item, 'D_POSITION')
        if t > pos + 1e-6 then R.SetMediaItemInfo_Value(h.item, 'D_LENGTH', t - pos) end
      elseif h.kind == 'midi' then
        local i, n = midi_note(h, lpb)
        if i then
          local ppq = R.MIDI_GetPPQPosFromProjTime(h.take, t)
          if ppq > n.sppq + 1 then R.MIDI_SetNote(h.take, i, n.sel, n.muted, n.sppq, ppq, n.ch, n.pitch, n.vel, false) end
        end
      end
    end
  end)
end

-- ── регистр: yank / paste ─────────────────────────────────────────────────
-- Регистр не держит указателей: item хранится state chunk'ом без GUID
-- (REAPER выдаст новые), нота — числами. Смещения — в строках от origin.
local function strip_guids(chunk)
  return (chunk:gsub('\n%s*GUID %b{}', ''):gsub('\n%s*IGUID %b{}', ''))
end

function E.yank(heads, lpb, origin_row, origin_fi)
  local reg = { rows = 1, cells = {} }
  local maxrow = origin_row
  for _, h in ipairs(heads) do
    local c = { kind = h.kind, drow = h.row0 - origin_row, dfi = (h.fi or origin_fi) - origin_fi, delay = h.delay }
    if h.kind == 'audio' then
      local ok, chunk = R.GetItemStateChunk(h.item, '', false)
      if ok then c.chunk = strip_guids(chunk) end
      c.len = R.GetMediaItemInfo_Value(h.item, 'D_LENGTH')
      c.name = h.name
    else
      local _, n = midi_note(h, lpb)
      if n then
        c.pitch, c.vel, c.ch, c.muted = n.pitch, n.vel, n.ch, n.muted
        local t0 = R.MIDI_GetProjTimeFromPPQPos(h.take, n.sppq)
        local t1 = R.MIDI_GetProjTimeFromPPQPos(h.take, n.eppq)
        c.len_qn = R.TimeMap2_timeToQN(0, t1) - R.TimeMap2_timeToQN(0, t0)
      else c = nil end
    end
    if c and (c.chunk or c.pitch) then
      reg.cells[#reg.cells + 1] = c
      if h.row0 + (h.rows or 1) - 1 > maxrow then maxrow = h.row0 + (h.rows or 1) - 1 end
    end
  end
  reg.rows = maxrow - origin_row + 1
  return reg
end

-- MIDI-item трека/lane, накрывающий время t (или nil)
local function midi_item_at(track, lane_idx, t)
  for i = 0, R.CountTrackMediaItems(track) - 1 do
    local it = R.GetTrackMediaItem(track, i)
    local tk = R.GetActiveTake(it)
    if tk and R.TakeIsMIDI(tk) then
      local lane = R.GetMediaItemInfo_Value(it, 'I_FIXEDLANE')
      local pos = R.GetMediaItemInfo_Value(it, 'D_POSITION')
      local len = R.GetMediaItemInfo_Value(it, 'D_LENGTH')
      if (lane_idx == nil or lane == lane_idx) and t >= pos - 1e-6 and t < pos + len - 1e-6 then return it, tk end
    end
  end
  return nil
end

-- новый MIDI-item от строки row на bars тактов (по размеру такта в этой точке)
local function new_midi_item(track, lane_idx, t)
  local qn = R.TimeMap2_timeToQN(0, t)
  local _, qms, qme = R.TimeMap_QNToMeasures(0, qn)
  local t0 = R.TimeMap2_QNToTime(0, qms or qn)
  local t1 = R.TimeMap2_QNToTime(0, qme or (qn + 4))
  local it = R.CreateNewMIDIItemInProj(track, t0, t1, false)
  if lane_idx and R.GetMediaTrackInfo_Value(track, 'I_FREEMODE') == 2 then
    R.SetMediaItemInfo_Value(it, 'I_FIXEDLANE', lane_idx)
  end
  return it, R.GetActiveTake(it)
end

local function insert_midi(track, lane_idx, t0, t1, pitch, vel, ch, muted)
  local it, tk = midi_item_at(track, lane_idx, t0)
  if not it then it, tk = new_midi_item(track, lane_idx, t0) end
  local p0 = R.MIDI_GetPPQPosFromProjTime(tk, t0)
  local p1 = R.MIDI_GetPPQPosFromProjTime(tk, t1)
  R.MIDI_InsertNote(tk, false, muted or false, p0, p1, ch or 0, pitch, vel or 100, false)
  return it
end

-- ── x-fade вставленных нот ─────────────────────────────────────────────
-- E.xfade.on: новая нота на стыке с предыдущей (та кончается на её старте или
-- заходит внахлёст) — предыдущая удлиняется на len, её fade-out = len,
-- fade-in новой = len: равномощный кроссфейд REAPER. Выключено — авто-фейды
-- (D_FADE*_AUTO) обоих обнуляются: внахлёст без кроссфейда, как просил
-- пользователь («либо free item positioning, либо без кроссфейда»).
E.xfade = { on = false, len = 0.010, mode = 'vol' }

-- огибающая громкости take (5 окт): нет — включается действием REAPER
-- «Take: Toggle take volume envelope» на одном выделенном item (выделение
-- возвращается). Время точки = (время проекта − позиция) × playrate
local TAKE_VOLENV_CMD
function E.take_vol_env(it)
  local tk = R.GetActiveTake(it)
  if not tk or R.TakeIsMIDI(tk) then return nil end
  local env = R.GetTakeEnvelopeByName(tk, 'Volume')
  if env then return env, tk end
  if not TAKE_VOLENV_CMD then
    for id = 40600, 40800 do
      local t = (R.kbd_getTextFromCmd(id, 0) or ''):lower()
      if t:find('toggle take volume envelope', 1, true) then TAKE_VOLENV_CMD = id; break end
    end
  end
  if not TAKE_VOLENV_CMD then return nil end
  local sel = {}
  for i = 0, R.CountSelectedMediaItems(0) - 1 do sel[#sel + 1] = R.GetSelectedMediaItem(0, i) end
  R.SelectAllMediaItems(0, false); R.SetMediaItemSelected(it, true)
  R.Main_OnCommand(TAKE_VOLENV_CMD, 0)
  R.SetMediaItemSelected(it, false)
  for _, s in ipairs(sel) do if R.ValidatePtr(s, 'MediaItem*') then R.SetMediaItemSelected(s, true) end end
  return R.GetTakeEnvelopeByName(tk, 'Volume'), tk
end

-- точка громкости (амплитуда item-уровня amp: 1 = как сам item) в момент t
-- проекта; точки той же строки [t, t1) заменяются
local function env_vol_point(it, t, amp, t1)
  local env, tk = E.take_vol_env(it)
  if not env then return false end
  local pos = R.GetMediaItemInfo_Value(it, 'D_POSITION')
  local rate = R.GetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE'); if rate <= 0 then rate = 1 end
  local et = (t - pos) * rate
  if t1 then R.DeleteEnvelopePointRange(env, et - 1e-6, (t1 - pos) * rate - 1e-6) end
  local mode = R.GetEnvelopeScalingMode(env)
  R.InsertEnvelopePoint(env, et, R.ScaleToEnvelopeMode(mode, math.max(0, math.min(4, amp))), 0, 0, false, true)
  R.Envelope_SortPoints(env)
  return true
end
E.env_vol_point = env_vol_point

-- vol xx на строке продолжения: точка огибающей, значение — в тех же
-- единицах, что громкость ноты (80 = 1.0 всего item)
function E.cont_vol(it, t, v, t1)
  if not (it and R.ValidatePtr(it, 'MediaItem*')) then return end
  local tk = R.GetActiveTake(it); if not tk then return end
  local base = R.GetMediaItemInfo_Value(it, 'D_VOL') * R.GetMediaItemTakeInfo_Value(tk, 'D_VOL')
  local amp = (math.max(0, math.min(255, v)) / 128) / (base > 1e-9 and base or 1)
  run('vol point', function() env_vol_point(it, t, amp, t1 or (t + 0.001)); R.UpdateItemInProject(it) end)
end

local function same_lane(track, it, lane_idx)
  if R.GetMediaTrackInfo_Value(track, 'I_FREEMODE') ~= 2 then return true end
  return math.floor(R.GetMediaItemInfo_Value(it, 'I_FIXEDLANE')) == (lane_idx or 0)
end

-- аудио-item (не MIDI, не заглушённый) — участник x-fade
local function xf_ok(it)
  local tk = R.GetActiveTake(it)
  if not tk or R.TakeIsMIDI(tk) then return false end
  return R.GetMediaItemInfo_Value(it, 'B_MUTE') ~= 1
end

-- сколько секунд источника осталось за концом item (для удлинения prev);
-- зацикленный источник — без ограничения
local function tail_left(it)
  local tk = R.GetActiveTake(it)
  if not tk then return 0 end
  if R.GetMediaItemInfo_Value(it, 'B_LOOPSRC') == 1 then return math.huge end
  local src = R.GetMediaItemTake_Source(tk)
  local slen = src and (model and model.online_src and R.GetMediaSourceLength(model.online_src(src)) or R.GetMediaSourceLength(src)) or 0
  local rate = R.GetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE')
  local offs = R.GetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS')
  local used = offs + R.GetMediaItemInfo_Value(it, 'D_LENGTH') * rate
  return math.max(0, (slen - used) / (rate > 0 and rate or 1))
end

-- пара prev → nxt.
-- x > 0: prev удлиняется до стыка + x (не дальше остатка источника), её
--   fade-out и fade-in nxt = x; удлинение помечается P_EXT:jf_xfade, чтобы
--   снятие вернуло длину ровно назад.
-- x == 0: без кроссфейда — фейды стыка (ручные и авто) обнуляются; trim —
--   ещё и вернуть удлинение, сделанное x-fade (по метке).
local function join_pair(prev, nxt, x, trim)
  local p = R.GetMediaItemInfo_Value(nxt, 'D_POSITION')
  local pp = R.GetMediaItemInfo_Value(prev, 'D_POSITION')
  local _, tag = R.GetSetMediaItemInfo_String(prev, 'P_EXT:jf_xfade', '', false)
  local old_ext = tonumber(tag) or 0
  if x > 0 then
    local base = p - pp                                   -- длина до стыка
    local cur_end = pp + R.GetMediaItemInfo_Value(prev, 'D_LENGTH')
    local avail = tail_left(prev) + math.max(0, cur_end - p)  -- сколько можно залезть за стык
    local ext = math.min(x, avail)
    R.SetMediaItemInfo_Value(prev, 'D_LENGTH', base + ext)
    local fx = math.max(ext, math.min(x, 0.002))
    if E.xfade.mode == 'vol' then
      -- кроссфейд значениями громкости (5 окт): рампы огибающих take —
      -- уходящий 1 → 0, входящий 0 → 1; фейды item обнуляются
      R.SetMediaItemInfo_Value(prev, 'D_FADEOUTLEN', 0); R.SetMediaItemInfo_Value(prev, 'D_FADEOUTLEN_AUTO', 0)
      R.SetMediaItemInfo_Value(nxt, 'D_FADEINLEN', 0); R.SetMediaItemInfo_Value(nxt, 'D_FADEINLEN_AUTO', 0)
      env_vol_point(prev, p, 1, p + fx); env_vol_point(prev, p + fx, 0)
      env_vol_point(nxt, p, 0, p + fx); env_vol_point(nxt, p + fx, 1)
      R.GetSetMediaItemInfo_String(prev, 'P_EXT:jf_xfade', ('%.6f'):format(ext), true)
      return
    end
    R.SetMediaItemInfo_Value(prev, 'D_FADEOUTLEN', fx)
    R.SetMediaItemInfo_Value(prev, 'D_FADEOUTLEN_AUTO', -1)
    R.SetMediaItemInfo_Value(nxt, 'D_FADEINLEN', fx)
    R.SetMediaItemInfo_Value(nxt, 'D_FADEINLEN_AUTO', -1)
    R.SetMediaItemInfo_Value(prev, 'C_FADEOUTSHAPE', E.xfade.shape or 1)
    R.SetMediaItemInfo_Value(nxt, 'C_FADEINSHAPE', E.xfade.shape or 1)
    R.GetSetMediaItemInfo_String(prev, 'P_EXT:jf_xfade', ('%.6f'):format(ext), true)
  else
    if trim and old_ext > 0 then
      local len = R.GetMediaItemInfo_Value(prev, 'D_LENGTH')
      R.SetMediaItemInfo_Value(prev, 'D_LENGTH', math.max(0.001, math.min(len, (p - pp) + 0) ))
    end
    if old_ext > 0 then
      R.GetSetMediaItemInfo_String(prev, 'P_EXT:jf_xfade', '', true)
      -- рампы громкости этого стыка — тоже долой
      for _, pr in ipairs({ { prev, p }, { nxt, p } }) do
        local tk = R.GetActiveTake(pr[1]); local env = tk and R.GetTakeEnvelopeByName(tk, 'Volume')
        if env then
          local ip = R.GetMediaItemInfo_Value(pr[1], 'D_POSITION')
          local rt = R.GetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE'); if rt <= 0 then rt = 1 end
          R.DeleteEnvelopePointRange(env, (pr[2] - ip) * rt - 1e-6, (pr[2] + old_ext - ip) * rt + 1e-6)
        end
      end
    end
    R.SetMediaItemInfo_Value(prev, 'D_FADEOUTLEN', 0)
    R.SetMediaItemInfo_Value(prev, 'D_FADEOUTLEN_AUTO', 0)
    R.SetMediaItemInfo_Value(nxt, 'D_FADEINLEN', 0)
    R.SetMediaItemInfo_Value(nxt, 'D_FADEINLEN_AUTO', 0)
  end
end

-- новый item it на дорожке. Партнёр слева — item, который КОНЧАЕТСЯ у
-- старта it (стык после note-off или уже скроссфейженный ≤ x); item,
-- который тянется дальше, — полифония (Shift+нота, удержанная нота), его не
-- трогаем. Партнёр справа — item, который начинается внутри it.
local function xfade_join(track, lane_idx, it)
  if not it or not xf_ok(it) then return end
  local p = R.GetMediaItemInfo_Value(it, 'D_POSITION')
  local e = p + R.GetMediaItemInfo_Value(it, 'D_LENGTH')
  local x = E.xfade.on and E.xfade.len or 0
  local prev, prev_pos, nxt, nxt_pos = nil, -math.huge, nil, math.huge
  local slack = math.max(x, 0) + 1e-3
  for i = 0, R.CountTrackMediaItems(track) - 1 do
    local o = R.GetTrackMediaItem(track, i)
    if o ~= it and same_lane(track, o, lane_idx) and xf_ok(o) then
      local op = R.GetMediaItemInfo_Value(o, 'D_POSITION')
      local oe = op + R.GetMediaItemInfo_Value(o, 'D_LENGTH')
      if op < p - slack and oe >= p - 1e-4 and oe <= p + slack and op > prev_pos then prev, prev_pos = o, op end
      if op > p + slack and op <= e + 1e-4 and op < nxt_pos and oe > e - 1e-4 then nxt, nxt_pos = o, op end
    end
  end
  if prev then join_pair(prev, it, x) end
  if nxt then join_pair(it, nxt, x) end
end
E.xfade_join = xfade_join

-- кроссфейд событий сейчас (len > 0) или снятие (len == 0): только настоящие
-- последования одной дорожки — b начинается позже a больше чем на len и
-- позже его конца минус len (стык), b кончается позже a. Аккорды, слои и
-- удержанные ноты не трогаются.
function E.xfade_heads(heads, len)
  len = len or 0
  local by = {}
  for _, h in ipairs(heads) do
    if h.kind == 'audio' and h.item and xf_ok(h.item) then
      local tr = R.GetMediaItem_Track(h.item)
      local key = tostring(tr) .. ':' .. math.floor(R.GetMediaItemInfo_Value(h.item, 'I_FIXEDLANE'))
      by[key] = by[key] or {}
      by[key][#by[key] + 1] = h.item
    end
  end
  local n = 0
  run(len > 0 and ('x-fade %.0f ms'):format(len * 1000) or 'x-fade remove', function()
    for _, list in pairs(by) do
      table.sort(list, function(a, b) return R.GetMediaItemInfo_Value(a, 'D_POSITION') < R.GetMediaItemInfo_Value(b, 'D_POSITION') end)
      for i = 1, #list - 1 do
        local a, b = list[i], list[i + 1]
        local ap = R.GetMediaItemInfo_Value(a, 'D_POSITION')
        local ae = ap + R.GetMediaItemInfo_Value(a, 'D_LENGTH')
        local bp = R.GetMediaItemInfo_Value(b, 'D_POSITION')
        local be = bp + R.GetMediaItemInfo_Value(b, 'D_LENGTH')
        local _, tag = R.GetSetMediaItemInfo_String(a, 'P_EXT:jf_xfade', '', false)
        local reach = math.max(len, tonumber(tag) or 0) + 1e-3
        if bp > ap + math.max(len, 1e-3) and ae >= bp - 1e-3 and ae <= bp + reach and be > ae then
          join_pair(a, b, len, len == 0); n = n + 1
        end
      end
    end
  end)
  return n
end

-- ── beatsync инструмента (3 окт; как в Renoise, но по темпу в месте ноты) ──
-- P_EXT:jf_bsync = "N;span;rate0;pp0": инструмент длиной span секунд
-- источника звучит ровно N долей — в каждой копии по темпу там, где она
-- стоит (TimeMap: смена BPM в проекте учтена). rate0 / pp0 — что вернуть
-- при выключении. Копии несут метку в чанке, слайсы корня — тоже: они идут
-- тем же темпом, что весь сэмпл. Растяжка — с сохранением питча (B_PPITCH).
local BSYNC = 'P_EXT:jf_bsync'
function E.bsync_of(it)
  local _, v = R.GetSetMediaItemInfo_String(it, BSYNC, '', false)
  local n, span, r0, pp0 = (v or ''):match('^([%d%.]+);([%d%.]+);([%d%.]+);(%d)')
  if not n then return nil end
  return { n = tonumber(n), span = tonumber(span), rate0 = tonumber(r0), pp0 = tonumber(pp0) }
end
-- подогнать копию под её место (без undo-блока: внутри run)
function E.bsync_fit(it, b)
  b = b or E.bsync_of(it)
  local tk = it and R.GetActiveTake(it)
  if not (b and tk) or b.n <= 0 or b.span <= 0 then return end
  local pos = R.GetMediaItemInfo_Value(it, 'D_POSITION')
  local dur = R.TimeMap2_QNToTime(0, R.TimeMap2_timeToQN(0, pos) + b.n) - pos
  if dur <= 0 then return end
  local rate = b.span / dur
  local cur = R.GetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE')
  local own = R.GetMediaItemInfo_Value(it, 'D_LENGTH') * cur        -- секунды источника этой копии (обрезка сохраняется)
  R.SetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE', rate)
  R.SetMediaItemTakeInfo_Value(tk, 'B_PPITCH', 1)
  R.SetMediaItemInfo_Value(it, 'D_LENGTH', own / rate)
end
-- предложение N по длине: ближайшая степень двойки долей при темпе в pos
function E.bsync_guess(span, pos)
  local qn0 = R.TimeMap2_timeToQN(0, pos)
  local beats = R.TimeMap2_timeToQN(0, pos + span) - qn0
  if beats <= 0 then return 1 end
  return math.max(1, math.floor(2 ^ math.floor(math.log(beats, 2) + 0.5) + 0.5))
end
-- включить (n > 0) / выключить (n = nil) beatsync у items инструмента;
-- rep — представитель (по нему span и исходный rate)
function E.bsync_set(items, rep, n)
  local tk = rep and R.GetActiveTake(rep)
  if not tk then return end
  run(n and ('beatsync %d beats'):format(n) or 'beatsync off', function()
    local old = E.bsync_of(rep)
    local r0 = old and old.rate0 or R.GetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE')
    local pp0 = old and old.pp0 or math.floor(R.GetMediaItemTakeInfo_Value(tk, 'B_PPITCH'))
    local span = old and old.span or R.GetMediaItemInfo_Value(rep, 'D_LENGTH') * R.GetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE')
    for _, it in ipairs(items) do
      local t = R.ValidatePtr(it, 'MediaItem*') and R.GetActiveTake(it)
      if t then
        if n then
          local b = { n = n, span = span, rate0 = r0, pp0 = pp0 }
          R.GetSetMediaItemInfo_String(it, BSYNC, ('%g;%.6f;%.6f;%d'):format(n, span, r0, pp0), true)
          E.bsync_fit(it, b)
        else
          local cur = R.GetMediaItemTakeInfo_Value(t, 'D_PLAYRATE')
          local own = R.GetMediaItemInfo_Value(it, 'D_LENGTH') * cur
          R.SetMediaItemTakeInfo_Value(t, 'D_PLAYRATE', r0)
          R.SetMediaItemTakeInfo_Value(t, 'B_PPITCH', pp0)
          R.SetMediaItemInfo_Value(it, 'D_LENGTH', own / r0)
          R.GetSetMediaItemInfo_String(it, BSYNC, '', true)
        end
        R.UpdateItemInProject(it)
      end
    end
  end)
end

local function insert_chunk(track, lane_idx, t, chunk)
  local it = R.AddMediaItemToTrack(track)
  R.SetItemStateChunk(it, chunk, false)
  -- копия — уже кусок, нарезка инструмента-родителя ей не принадлежит
  R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_slices', '', true)
  R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_slice_base', '', true)
  R.SetMediaItemInfo_Value(it, 'D_POSITION', t)
  if lane_idx and R.GetMediaTrackInfo_Value(track, 'I_FREEMODE') == 2 then
    R.SetMediaItemInfo_Value(it, 'I_FIXEDLANE', lane_idx)
  end
  return it
end
-- Без x-fade новая нота ОБРУБАЕТ предыдущий item той же дорожки на своей
-- строке (всё, что начинается раньше и тянется через t) — по реальным
-- границам item, а не по ячейке снимка. E.beside = true (Shift+нота) —
-- рядом, не трогая. С x-fade стык делает xfade_join.
E.beside = false
local function cut_covering(track, lane_idx, t, keep)
  for i = R.CountTrackMediaItems(track) - 1, 0, -1 do
    local o = R.GetTrackMediaItem(track, i)
    if o ~= keep and same_lane(track, o, lane_idx) and xf_ok(o) then
      local op = R.GetMediaItemInfo_Value(o, 'D_POSITION')
      local oe = op + R.GetMediaItemInfo_Value(o, 'D_LENGTH')
      if op < t - 1e-4 and oe > t + 1e-4 then R.SetMediaItemInfo_Value(o, 'D_LENGTH', t - op) end
    end
  end
end
-- вставка ноты/слайса/куска: после того как длина и offset выставлены
-- ── повтор паттерна над курсором (4 окт, из Paketti — Esa Ruoho) ───────────
-- Ctrl+Opt+J / ↓: то, что на треке стоит в строках [r0, rc) (от начала региона
-- до курсора), повторяется от курсора rc вниз до r1 (конец региона), последний
-- повтор — обрезан по r1. Что было в [rc, r1), заменяется. Аудио — копии item
-- (строки → время через темп в каждом месте), MIDI — ноты в MIDI-item.
-- В одном undo-блоке со всеми треками (вызывающий). Возвращает копий.
local function qn_time(rf, lpb) return R.TimeMap2_QNToTime(0, rf / lpb) end
local function time_row(t, lpb) return R.TimeMap2_timeToQN(0, t) * lpb end
function E.repeat_above(track, lpb, r0, rc, r1)
  local L = rc - r0
  if L <= 0 or r1 <= rc then return 0 end
  local tc, t1 = qn_time(rc, lpb), qn_time(r1, lpb)
  local t0 = qn_time(r0, lpb)
  local n = 0
  local lanes_on = R.GetMediaTrackInfo_Value(track, 'I_FREEMODE') == 2
  -- исходник: аудио-item с началом в [t0, tc) и MIDI-ноты там же
  local audio, notes = {}, {}
  for i = 0, R.CountTrackMediaItems(track) - 1 do
    local it = R.GetTrackMediaItem(track, i)
    local tk = R.GetActiveTake(it)
    local pos = R.GetMediaItemInfo_Value(it, 'D_POSITION')
    local len = R.GetMediaItemInfo_Value(it, 'D_LENGTH')
    local lane = lanes_on and math.floor(R.GetMediaItemInfo_Value(it, 'I_FIXEDLANE')) or nil
    if tk and R.TakeIsMIDI(tk) then
      local _, nn = R.MIDI_CountEvts(tk)
      for k = 0, nn - 1 do
        local _, sel, mu, sp, ep, ch, pitch, vel = R.MIDI_GetNote(tk, k)
        local ns, ne = R.MIDI_GetProjTimeFromPPQPos(tk, sp), R.MIDI_GetProjTimeFromPPQPos(tk, ep)
        if ns >= t0 - 1e-6 and ns < tc - 1e-6 then
          notes[#notes + 1] = { rs = time_row(ns, lpb), rl = time_row(ne, lpb) - time_row(ns, lpb), pitch = pitch, vel = vel, ch = ch, mu = mu, lane = lane }
        end
      end
    elseif tk and pos >= t0 - 1e-6 and pos < tc - 1e-6 then
      local ok, ch = R.GetItemStateChunk(it, '', false)
      if ok then audio[#audio + 1] = { chunk = strip_guids(ch), rs = time_row(pos, lpb), rl = time_row(pos + len, lpb) - time_row(pos, lpb), lane = lane } end
    end
  end
  -- чистка [tc, t1): аудио — удалить начинающиеся там, накрывающие — обрезать
  -- по tc; MIDI-ноты с началом там — удалить
  for i = R.CountTrackMediaItems(track) - 1, 0, -1 do
    local it = R.GetTrackMediaItem(track, i)
    local tk = R.GetActiveTake(it)
    local pos = R.GetMediaItemInfo_Value(it, 'D_POSITION')
    local len = R.GetMediaItemInfo_Value(it, 'D_LENGTH')
    if tk and R.TakeIsMIDI(tk) then
      local _, nn = R.MIDI_CountEvts(tk)
      for k = nn - 1, 0, -1 do
        local _, _, _, sp = R.MIDI_GetNote(tk, k)
        local ns = R.MIDI_GetProjTimeFromPPQPos(tk, sp)
        if ns >= tc - 1e-6 and ns < t1 - 1e-6 then R.MIDI_DeleteNote(tk, k) end
      end
    elseif tk then
      if pos >= tc - 1e-6 and pos < t1 - 1e-6 then R.DeleteTrackMediaItem(track, it)
      elseif pos < tc - 1e-6 and pos + len > tc + 1e-6 then R.SetMediaItemInfo_Value(it, 'D_LENGTH', tc - pos) end
    end
  end
  -- копии: k-й повтор сдвинут на k·L строк; длина — не дальше r1
  local k = 1
  while rc + (k - 1) * L < r1 and k < 4096 do
    local sh = k * L
    for _, a in ipairs(audio) do
      local rs = a.rs + sh
      if rs < r1 - 1e-6 then
        local re = math.min(rs + a.rl, r1)
        local t = qn_time(rs, lpb)
        local it = insert_chunk(track, a.lane, t, a.chunk)
        if it then R.SetMediaItemInfo_Value(it, 'D_LENGTH', qn_time(re, lpb) - t); n = n + 1 end
      end
    end
    for _, m in ipairs(notes) do
      local rs = m.rs + sh
      if rs < r1 - 1e-6 then
        local re = math.min(rs + m.rl, r1)
        insert_midi(track, m.lane, qn_time(rs, lpb), qn_time(re, lpb), m.pitch, m.vel, m.ch, m.mu)
        n = n + 1
      end
    end
    k = k + 1
  end
  for i = 0, R.CountTrackMediaItems(track) - 1 do
    local tk = R.GetActiveTake(R.GetTrackMediaItem(track, i))
    if tk and R.TakeIsMIDI(tk) then R.MIDI_Sort(tk) end
  end
  return n
end

-- ── легато (3 окт, :legato) ───────────────────────────────────────────────
-- Аудио-нота тянется до начала следующей ноты своей лейн (без зазора):
-- длина = следующий старт − позиция, скорость — чтобы её кусок источника
-- уложился ровно в эту длину, высота сохраняется. Ноты стоят по сетке, так
-- что медленный темп — промежуток длиннее — растяжка больше, быстрый — меньше.
-- Своя длина / скорость ноты — в P_EXT:jf_nat («len;rate;ppitch»): повтор не
-- копит растяжку, off — возврат. Последняя нота лейн — своя длина.
-- t0 / t1 — диапазон позиций (nil — весь трек). Возвращает число нот.
local NAT = 'P_EXT:jf_nat'
local function nat_of(it, tk)
  local _, v = R.GetSetMediaItemInfo_String(it, NAT, '', false)
  local l, r, p = v:match('^([^;]+);([^;]+);([^;]+)$')
  if l then return tonumber(l), tonumber(r), tonumber(p) end
  return R.GetMediaItemInfo_Value(it, 'D_LENGTH'), R.GetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE'), R.GetMediaItemTakeInfo_Value(tk, 'B_PPITCH')
end
function E.legato(track, lane_idx, t0, t1, off)
  local list = {}
  for i = 0, R.CountTrackMediaItems(track) - 1 do
    local it = R.GetTrackMediaItem(track, i)
    local tk = R.GetActiveTake(it)
    if tk and not R.TakeIsMIDI(tk) and (lane_idx == nil or math.floor(R.GetMediaItemInfo_Value(it, 'I_FIXEDLANE')) == lane_idx) then
      list[#list + 1] = { it = it, tk = tk, pos = R.GetMediaItemInfo_Value(it, 'D_POSITION') }
    end
  end
  table.sort(list, function(a, b) return a.pos < b.pos end)
  local n = 0
  run(off and 'legato off' or 'legato', function()
    for k, e in ipairs(list) do
      if (not t0 or e.pos >= t0 - 1e-6) and (not t1 or e.pos < t1 - 1e-6) then
        local nl, nr, np = nat_of(e.it, e.tk)
        local nxt
        for j = k + 1, #list do if list[j].pos > e.pos + 1e-4 then nxt = list[j].pos; break end end
        if off or not nxt then
          R.SetMediaItemInfo_Value(e.it, 'D_LENGTH', nl)
          R.SetMediaItemTakeInfo_Value(e.tk, 'D_PLAYRATE', nr)
          R.SetMediaItemTakeInfo_Value(e.tk, 'B_PPITCH', np)
          R.GetSetMediaItemInfo_String(e.it, NAT, '', true)
        else
          local _, had = R.GetSetMediaItemInfo_String(e.it, NAT, '', false)
          if had == '' then R.GetSetMediaItemInfo_String(e.it, NAT, ('%.9f;%.9f;%d'):format(nl, nr, math.floor(np)), true) end
          local len = nxt - e.pos
          R.SetMediaItemInfo_Value(e.it, 'D_LENGTH', len)
          R.SetMediaItemTakeInfo_Value(e.tk, 'D_PLAYRATE', nr * nl / len)
          if math.abs(len - nl) > 1e-6 then R.SetMediaItemTakeInfo_Value(e.tk, 'B_PPITCH', 1) end
        end
        n = n + 1
      end
    end
  end)
  return n
end
function E.legato_auto(track, on)
  if on == nil then local _, v = R.GetSetMediaTrackInfo_String(track, 'P_EXT:jf_legato', '', false); return v == '1' end
  R.GetSetMediaTrackInfo_String(track, 'P_EXT:jf_legato', on and '1' or '', true)
end

local function finish_insert(track, lane_idx, it)
  if not it then return end
  E.bsync_fit(it)                                     -- beatsync инструмента: под темп в этом месте
  if not E.beside and not E.xfade.on then cut_covering(track, lane_idx, R.GetMediaItemInfo_Value(it, 'D_POSITION'), it) end
  xfade_join(track, lane_idx, it)
  if E.legato_auto(track) then E.legato(track, lane_idx) end   -- трек в легато: держится при вставке
end

-- вставить слайс k инструмента inst_item на трек: копия chunk, offs/len по таблице
-- кусок [a, b) секунд item-корня с stretch-маркерами (3 окт, баг: все слайсы
-- звучали началом брейка). Позиция маркера в источнике у REAPER — от начала
-- файла, в долях при playrate (конец 2.667 при rate 1.5 = 4.0 с файла), и
-- D_STARTOFFS копии её не сдвигает: копия с маркерами корня играла с начала.
-- Копия получает свой кусок источника без маркеров: смещение = карта(a)·rate,
-- скорость — чтобы карта(b)−карта(a) уложилась в b − a; высота сохраняется.
-- pts — маркеры корня { pos, src }, rate — playrate корня. true — пересчитано.
local function smap_at(pts, t)
  if t <= pts[1].pos then return pts[1].src - (pts[1].pos - t) end
  for i = 1, #pts - 1 do
    local p, q = pts[i], pts[i + 1]
    if t <= q.pos then local d = q.pos - p.pos; return d > 1e-9 and (p.src + (t - p.pos) / d * (q.src - p.src)) or p.src end
  end
  local z = pts[#pts]
  return z.src + (t - z.pos)
end
function E.root_markers(take)
  local n = take and R.GetTakeNumStretchMarkers and R.GetTakeNumStretchMarkers(take) or 0
  if n == 0 then return nil end
  local pts = {}
  for i = 0, n - 1 do local _, pos, src = R.GetTakeStretchMarker(take, i); if pos and src then pts[#pts + 1] = { pos = pos, src = src } end end
  table.sort(pts, function(x, y) return x.pos < y.pos end)
  return #pts > 0 and pts or nil
end
function E.unwarp_piece(it, pts, rate, a, b)
  local tk = R.GetActiveTake(it)
  if not (tk and pts and b > a) then return false end
  local sa, sb = smap_at(pts, a), smap_at(pts, b)
  local n = R.GetTakeNumStretchMarkers(tk)
  if n > 0 then R.DeleteTakeStretchMarkers(tk, 0, n) end
  local eff = math.max(0.01, (sb - sa) * rate / (b - a))
  R.SetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS', math.max(0, sa * rate))
  R.SetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE', eff)
  if math.abs(eff - rate) > 1e-6 then R.SetMediaItemTakeInfo_Value(tk, 'B_PPITCH', 1) end
  R.SetMediaItemInfo_Value(it, 'D_LENGTH', b - a)
  return true
end

-- PT-mode (3 окт, :pt new): треки CH1..CH4, которых нет (have — имя → индекс);
-- в конце проекта, один undo. Возвращает число новых
function E.pt_tracks(have)
  local n = 0
  run('PT channels', function()
    for k = 1, 4 do
      local nm = 'CH' .. k
      if not have[nm] then
        R.InsertTrackAtIndex(R.CountTracks(0), true)
        local tr = R.GetTrack(0, R.CountTracks(0) - 1)
        R.GetSetMediaTrackInfo_String(tr, 'P_NAME', nm, true)
        n = n + 1
      end
    end
    R.TrackList_AdjustWindows(false)
  end)
  return n
end

-- порядок исходников в lib (3 окт, перетаскивание / J K): items — item-представители
-- исходников в новом порядке; метка P_EXT:jf_ord = номер ставится на все копии
-- исходника (та же jf_iid), новые ноты наследуют её через чанк. Один undo.
function E.lib_order(items)
  run('lib order', function()
    for k, it in ipairs(items) do
      if R.ValidatePtr(it, 'MediaItem*') then
        local copies = E.items_with_iid(E.ensure_iid(it))
        if #copies == 0 then copies = { it } end
        for _, c in ipairs(copies) do R.GetSetMediaItemInfo_String(c, 'P_EXT:jf_ord', tostring(k), true) end
      end
    end
  end)
end

-- swap (3 окт): звук инструмента — другой файл во всех его нотах (исходник,
-- копии, слайсы: все item с той же меткой jf_iid до # / @ / ~). Прежний файл
-- запоминается в P_EXT:jf_swap — повторный swap возвращает его. Смещения,
-- длины и нарезка остаются (как замена сэмпла в Renoise). Один undo.
function E.items_with_base(base)
  local out = {}
  if not base or base == '' then return out end
  for ti = 0, R.CountTracks(0) - 1 do
    local tr = R.GetTrack(0, ti)
    for ii = 0, R.CountTrackMediaItems(tr) - 1 do
      local it = R.GetTrackMediaItem(tr, ii)
      if iid_base(E.get_iid(it)) == base then out[#out + 1] = it end
    end
  end
  return out
end
function E.swap_source(root, path)
  local base = iid_base(E.ensure_iid(root))
  local items = E.items_with_base(base)
  if #items == 0 then items = { root } end
  local n = 0
  run(path and 'swap sample' or 'swap back', function()
    for _, it in ipairs(items) do
      local tk = R.GetActiveTake(it)
      if tk then
        local _, prev = R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_swap', '', false)
        local target = path or (prev ~= '' and prev or nil)
        if target then
          local src = R.PCM_Source_CreateFromFile(target)
          if src then
            if path and prev == '' then
              local old = R.GetMediaItemTake_Source(tk)
              R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_swap', old and R.GetMediaSourceFileName(old, '') or '', true)
            elseif not path then R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_swap', '', true) end
            R.SetMediaItemTake_Source(tk, src)
            n = n + 1
          end
        end
      end
    end
    R.Main_OnCommand(40047, 0)                           -- Peaks: build any missing peak files
  end)
  return n
end
function E.swapped(root)
  local _, prev = R.GetSetMediaItemInfo_String(root, 'P_EXT:jf_swap', '', false)
  return prev ~= '' and prev or nil
end

-- починка уже вставленных слайсов (:fixslices, 3 окт): нота слайса k с
-- маркерами, скопированными от растянутого корня, получает свой кусок
-- источника. Возвращает число исправленных
function E.fix_slices()
  local n = 0
  run('fix slices', function()
    local roots = {}
    for ti = 0, R.CountTracks(0) - 1 do
      local tr = R.GetTrack(0, ti)
      for ii = 0, R.CountTrackMediaItems(tr) - 1 do
        local it = R.GetTrackMediaItem(tr, ii)
        local _, k = R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_slice', '', false)
        k = tonumber(k)
        local tk = R.GetActiveTake(it)
        if k and tk and R.GetTakeNumStretchMarkers(tk) > 0 then
          local base = iid_base(E.get_iid(it))
          local root = roots[base]
          if root == nil then
            root = false
            for _, c in ipairs(E.items_with_iid(base)) do if #E.item_slices(c) > 0 then root = c; break end end
            roots[base] = root
          end
          if root then
            local sl, b0 = E.item_slices(root)
            local rtk = R.GetActiveTake(root)
            local pts = E.root_markers(rtk)
            local a = sl[k]
            local b = sl[k + 1] or b0.len or R.GetMediaItemInfo_Value(root, 'D_LENGTH')
            if pts and a and b > a then
              local cut = R.GetMediaItemInfo_Value(it, 'D_LENGTH')   -- обрезанная нота сохраняет свою длину
              if E.unwarp_piece(it, pts, R.GetMediaItemTakeInfo_Value(rtk, 'D_PLAYRATE'), a, b) then
                if cut < b - a - 1e-6 then R.SetMediaItemInfo_Value(it, 'D_LENGTH', cut) end
                n = n + 1
              end
            end
          end
        end
      end
    end
  end)
  return n
end

-- slice playthru (6 окт): свойство инструмента — слайс играет от своей метки
-- до КОНЦА сэмпла (не до следующей метки); следующая нота колонки его режет
-- (cut_covering), уже стоящая позже — ограничивает. P_EXT:jf_playthru у корня
function E.playthru(it)
  if not (it and R.ValidatePtr(it, 'MediaItem*')) then return false end
  local _, v = R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_playthru', '', false)
  return v == '1'
end
-- начало ближайшего item той же колонки после t (nil — нет)
local function next_start(track, lane_idx, t, keep)
  local best
  for i = 0, R.CountTrackMediaItems(track) - 1 do
    local o = R.GetTrackMediaItem(track, i)
    if o ~= keep and same_lane(track, o, lane_idx) then
      local op = R.GetMediaItemInfo_Value(o, 'D_POSITION')
      if op > t + 1e-4 and (not best or op < best) then best = op end
    end
  end
  return best
end
-- длина слайса k: до следующей метки или (playthru) до конца сэмпла,
-- но не дальше следующей ноты колонки
function E.slice_len(inst_item, slices, base, k, track, lane_idx, pos, keep)
  local a = slices[k]
  local full = base.len or R.GetMediaItemInfo_Value(inst_item, 'D_LENGTH')
  local b = E.playthru(inst_item) and full or (slices[k + 1] or full)
  local len = b - a
  if E.playthru(inst_item) and track then
    local nx = next_start(track, lane_idx, pos, keep)
    if nx then len = math.min(len, nx - pos) end
  end
  return math.max(0.001, len), b
end
-- переключить playthru у инструмента: флаг на корне и копиях, длины уже
-- стоящих нот-слайсов пересчитаны (один undo)
function E.set_playthru(root, items, on)
  local slices, base = E.item_slices(root)
  run('slice playthru ' .. (on and 'on' or 'off'), function()
    for _, it in ipairs(items) do
      if R.ValidatePtr(it, 'MediaItem*') then
        R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_playthru', on and '1' or '', true)
        local _, ks = R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_slice', '', false)
        local k = tonumber(ks)
        if k and it ~= root and slices[k] then
          local tr = R.GetMediaItem_Track(it)
          local lane = math.floor(R.GetMediaItemInfo_Value(it, 'I_FIXEDLANE'))
          local pos = R.GetMediaItemInfo_Value(it, 'D_POSITION')
          local len = E.slice_len(root, slices, base, k, tr, lane, pos, it)
          R.SetMediaItemInfo_Value(it, 'D_LENGTH', len)
        end
      end
    end
  end)
end

function E.insert_slice(track, lane_idx, lpb, row, inst_item, k, t_exact)
  local slices, base = E.item_slices(inst_item)
  if #slices == 0 then return end
  k = math.max(1, math.min(#slices, k))
  local t0 = t_exact or E.swing_time(row, lpb)           -- t_exact: стык с концом предыдущего слайса; свинг (6 окт)
  local made
  run('insert slice ' .. k, function()
    local root = iid_base(E.ensure_iid(inst_item))
    local ok, chunk = R.GetItemStateChunk(inst_item, '', false)
    if not ok then return end
    local it = insert_chunk(track, lane_idx, t0, strip_guids(chunk))
    R.SetMediaItemInfo_Value(it, 'B_MUTE', 0)
    local tk = R.GetActiveTake(it)
    if tk then
      -- таблица слайсов — в секундах item при исходном rate (beatsync корня его меняет)
      local bs = E.bsync_of(it)
      if bs then R.SetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE', bs.rate0) end
      local rate = R.GetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE')
      local a = slices[k]
      local len, b = E.slice_len(inst_item, slices, base, k, track, lane_idx, t0, it)   -- playthru: до конца сэмпла (6 окт)
      R.SetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS', (base.offs or 0) + a * rate)
      R.SetMediaItemInfo_Value(it, 'D_LENGTH', len)
      R.SetMediaItemTakeInfo_Value(tk, 'D_PITCH', 0)
      -- корень растянут маркерами (smart quantize): свой кусок источника
      local rtk = R.GetActiveTake(inst_item)
      local pts = E.root_markers(rtk)
      if pts then E.unwarp_piece(it, pts, R.GetMediaItemTakeInfo_Value(rtk, 'D_PLAYRATE'), a, b) end
    end
    R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_slice', tostring(k), true)
    E.set_iid(it, root .. '#' .. k)                      -- все ноты слайса k — один инструмент
    finish_insert(track, lane_idx, it)
    made = it
  end)
  return made
end

-- Выделение сэмпл-модуля [t0, t1) (секунды item) → item на track в строке
-- row: инструмент пула — копия chunk с D_STARTOFFS/D_LENGTH, файл браузера —
-- новый item из источника. pos — явная позиция вместо строки (депо).
function E.insert_span(track, lane_idx, lpb, row, entry, t0, t1, pos)
  if not entry or t1 <= t0 then return end
  local t = pos or E.swing_time(row, lpb)
  local it
  run(('insert span %.2fs'):format(t1 - t0), function()
    if entry.item then
      local root = iid_base(E.ensure_iid(entry.item))
      local ok, chunk = R.GetItemStateChunk(entry.item, '', false)
      if not ok then return end
      it = insert_chunk(track, lane_idx, t, strip_guids(chunk))
      R.SetMediaItemInfo_Value(it, 'B_MUTE', 0)
      local tk = R.GetActiveTake(it)
      if tk then
        local rate = R.GetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE')
        local offs = (entry.offs or 0) + t0 * rate
        R.SetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS', offs)
        R.SetMediaItemInfo_Value(it, 'D_LENGTH', t1 - t0)
        local pts = E.root_markers(R.GetActiveTake(entry.item))
        if pts then E.unwarp_piece(it, pts, rate, t0, t1) end
        -- тот же кусок, вставленный ещё раз, — тот же инструмент
        E.set_iid(it, ('%s@%.3f+%.3f'):format(root, offs, (t1 - t0) * rate))
      end
    elseif entry.path then
      local src = R.PCM_Source_CreateFromFile(E.media_copy(entry.path))
      if not src then return end
      it = R.AddMediaItemToTrack(track)
      local tk = R.AddTakeToMediaItem(it)
      R.SetMediaItemTake_Source(tk, src)
      R.SetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS', t0)
      R.SetMediaItemInfo_Value(it, 'D_POSITION', t)
      R.SetMediaItemInfo_Value(it, 'D_LENGTH', t1 - t0)
      R.GetSetMediaItemTakeInfo_String(tk, 'P_NAME', (entry.name or entry.path:match('[^/]+$') or 'sample'), true)
      if lane_idx and R.GetMediaTrackInfo_Value(track, 'I_FREEMODE') == 2 then R.SetMediaItemInfo_Value(it, 'I_FIXEDLANE', lane_idx) end
    end
    if it and not pos then finish_insert(track, lane_idx, it) end
  end)
  return it
end

-- конец библиотеки паттернов (8 окт): регионы после =END; маркера =LIB
-- нет, семплы — на треке LIB и с паттернами больше не пересекаются
function E.lib_tail(lib)
  local t = lib or model.marker_pos(model.END_MARKER) or R.GetProjectLength(0)
  local i = 0
  while true do
    local ret, isrgn, p, e, nm = R.EnumProjectMarkers3(0, i)
    if not ret or ret == 0 then break end
    if isrgn and p >= t - 1e-6 and nm ~= '=SESSION' then t = math.max(t, e) end
    i = i + 1
  end
  return t
end

-- выделение → библиотека трека (трек LIB, свой лейн) — потом нарезать как инструмент
function E.depot_span(track, entry, t0, t1)
  local it
  run('lib span', function()
    local tr, lane = E.lib_slot()
    it = E.insert_span(tr, lane, 4, 0, entry, t0, t1, 0)
    E.lib_mark(it, track, lane)
  end)
  return it
end

-- targets(dfi) → {track=, lane_idx=} — колонка для смещения dfi от курсора
function E.paste(reg, lpb, row, targets)
  if not reg or #reg.cells == 0 then return end
  run('paste', function()
    for _, c in ipairs(reg.cells) do
      local tg = targets(c.dfi)
      if tg then
        local t = row_time(row + c.drow, lpb, c.delay)
        if c.kind == 'audio' and c.chunk then
          xfade_join(tg.track, tg.lane_idx, insert_chunk(tg.track, tg.lane_idx, t, c.chunk))
        elseif c.kind == 'midi' then
          local qn = R.TimeMap2_timeToQN(0, t)
          local t1 = R.TimeMap2_QNToTime(0, qn + c.len_qn)
          insert_midi(tg.track, tg.lane_idx, t, t1, c.pitch, c.vel, c.ch, c.muted)
        end
      end
    end
  end)
end

-- ── вставка ноты (insert mode) ────────────────────────────────────────────
-- Колонка MIDI (есть MIDI-item на строке или трек без аудио) → нота длиной
-- len_rows. Иначе — копия item из DEPOT (instrument = item депо) с
-- D_PITCH = pitch − BASE_NOTE; длина item — как у образца.
function E.insert_note(track, lane_idx, lpb, row, pitch, vel, len_rows, depot_item)
  local force_midi = depot_item == 'midi'                 -- 9 окт: выбран плагин-инструмент — нота MIDI
  if force_midi then depot_item = nil end
  local t0 = E.swing_time(row, lpb)                       -- свинг (6 окт)
  local t1 = row_time(row + math.max(1, len_rows or 1), lpb, 0)
  local made
  run('insert note', function()
    local mit = midi_item_at(track, lane_idx, t0)
    if mit and not E.item_swing(mit) then t0 = row_time(row, lpb, 0) end   -- у MIDI item свинг выключен (6 окт)
    local has_audio = false
    if not mit then
      for i = 0, R.CountTrackMediaItems(track) - 1 do
        local tk = R.GetActiveTake(R.GetTrackMediaItem(track, i))
        if tk and not R.TakeIsMIDI(tk) then has_audio = true; break end
      end
    end
    local dtk = depot_item and R.GetActiveTake(depot_item)
    if dtk and R.TakeIsMIDI(dtk) then
      -- MIDI-клип из lib (9 окт): копия клипа в строку, нота — транспонирование
      -- (C-4 — как есть); пул MIDI у копии снят — оригинал не меняется
      E.ensure_iid(depot_item)
      local ok, chunk = R.GetItemStateChunk(depot_item, '', false)
      if ok then
        chunk = strip_guids(chunk):gsub('\n%s*POOLEDEVTS %b{}', '')
        local it = insert_chunk(track, lane_idx, t0, chunk)
        R.SetMediaItemInfo_Value(it, 'B_MUTE', 0)
        local tk = R.GetActiveTake(it)
        local d = pitch - model.BASE_NOTE
        if tk and d ~= 0 then
          local _, nn = R.MIDI_CountEvts(tk)
          for k = 0, nn - 1 do
            local _, sel, mu, sp, ep, ch, p, v = R.MIDI_GetNote(tk, k)
            R.MIDI_SetNote(tk, k, sel, mu, sp, ep, ch, math.max(0, math.min(127, p + d)), v, true)
          end
          R.MIDI_Sort(tk)
        end
        finish_insert(track, lane_idx, it)
        made = it
      end
    elseif mit or force_midi or (not has_audio and not depot_item) then
      insert_midi(track, lane_idx, t0, t1, pitch, vel, 0, false)
    elseif depot_item then
      E.ensure_iid(depot_item)                          -- копия унесёт метку в чанке
      local ok, chunk = R.GetItemStateChunk(depot_item, '', false)
      if ok then
        local it = insert_chunk(track, lane_idx, t0, strip_guids(chunk))
        R.SetMediaItemInfo_Value(it, 'B_MUTE', 0)
        local tk = R.GetActiveTake(it)
        -- копия несёт transpose инструмента (D_PITCH / rate чанка) — нота поверх него (6 окт)
        if tk then local h = { item = it, take = tk }; audio_set_semis(h, audio_semis(h) + pitch - model.BASE_NOTE) end
        if tk then E.humanize(it, tk) end
        finish_insert(track, lane_idx, it)
        made = it
      end
    end
  end)
  return made
end

-- human (9 окт, экспериментально, опция human %): каждая вставленная
-- нота-слайс — чуть другая, как живой удар: питч ±8 центов, громкость
-- ±1 dB, скорость ±0.3 % (при 100 %); 0 — выкл. E.human ставит main
E.human = 0
function E.humanize(it, tk)
  local h = (E.human or 0) / 100
  if h <= 0 then return end
  local function r() return (math.random() * 2 - 1) * h end
  R.SetMediaItemTakeInfo_Value(tk, 'D_PITCH', R.GetMediaItemTakeInfo_Value(tk, 'D_PITCH') + r() * 0.08)
  R.SetMediaItemInfo_Value(it, 'D_VOL', R.GetMediaItemInfo_Value(it, 'D_VOL') * 10 ^ (r() * 1.0 / 20))
  R.SetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE', R.GetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE') * (1 + r() * 0.003))
end

-- ── арпеджиатор (3 окт, :arp) ─────────────────────────────────────────────
-- Аккорд на строке row (heads — ноты, начинающиеся в ней: MIDI и аудио) →
-- арпеджио на всю длину аккорда: шаг opt.step строк, порядок opt.order
-- (up / down / updown / random / played — как стоят в подколонках), opt.oct
-- октав, opt.gate — доля шага (длина ноты). Аудио: копия своего item с питчем
-- ноты; MIDI — нота в MIDI-item строки. Аккорд удаляется. Один undo.
-- Возвращает число нот арпеджио.
function E.arp_order(pitches, order, oct, seed)
  local base = {}
  for _, p in ipairs(pitches) do base[#base + 1] = p end
  if order ~= 'played' then table.sort(base) end
  local seq = {}
  for o = 0, math.max(1, oct or 1) - 1 do for _, p in ipairs(base) do seq[#seq + 1] = p + 12 * o end end
  if order == 'down' then
    local r = {}; for i = #seq, 1, -1 do r[#r + 1] = seq[i] end; seq = r
  elseif order == 'updown' and #seq > 2 then
    for i = #seq - 1, 2, -1 do seq[#seq + 1] = seq[i] end
  elseif order == 'random' then
    local x = seed or 12345
    for i = #seq, 2, -1 do x = (x * 1103515245 + 12345) % 2147483648; local j = x % i + 1; seq[i], seq[j] = seq[j], seq[i] end
  end
  return seq
end

function E.arpeggiate(track, lane_idx, lpb, row, heads, opt)
  if #heads == 0 then return 0 end
  opt = opt or {}
  local step = math.max(1, math.floor(opt.step or 1))
  local gate = math.max(0.05, math.min(1, opt.gate or 1))
  local notes, total = {}, 1
  for _, h in ipairs(heads) do
    local p, vel, chunk = h.pitch, h.vel, nil
    if h.kind == 'audio' and h.take then
      p = model.BASE_NOTE + model.take_semitones(R.GetMediaItemTakeInfo_Value(h.take, 'D_PITCH'), R.GetMediaItemTakeInfo_Value(h.take, 'D_PLAYRATE'), R.GetMediaItemTakeInfo_Value(h.take, 'B_PPITCH') == 1)
      local ok, c = R.GetItemStateChunk(h.item, '', false)
      chunk = ok and c or nil
    end
    if p then notes[#notes + 1] = { pitch = math.floor(p + 0.5), vel = vel or 100, chunk = chunk, kind = h.kind } end
    total = math.max(total, math.floor((h.rows_f or h.rows or 1) + 0.5))
  end
  if #notes == 0 then return 0 end
  local by_pitch = {}
  local pitches = {}
  for _, n in ipairs(notes) do pitches[#pitches + 1] = n.pitch; by_pitch[n.pitch] = by_pitch[n.pitch] or n end
  local seq = E.arp_order(pitches, opt.order or 'up', opt.oct, opt.seed)
  local count = math.max(1, total // step)
  local made = 0
  run('arpeggio', function()
    E.delete(heads, lpb)
    local lowest = by_pitch[math.min(table.unpack(pitches))]
    for k = 0, count - 1 do
      local p = seq[k % #seq + 1]
      -- шаблон — нота аккорда той же ступени (октавные копии), иначе нижняя
      local src = by_pitch[p]
      if not src then for _, q in ipairs(pitches) do if (p - q) % 12 == 0 then src = by_pitch[q]; break end end end
      src = src or lowest
      local r0 = row + k * step
      local t0 = row_time(r0, lpb, 0)
      local t1 = row_time(r0 + step, lpb, 0)
      local dur = (t1 - t0) * gate
      if src.chunk then
        local it = insert_chunk(track, lane_idx, t0, strip_guids(src.chunk))
        R.SetMediaItemInfo_Value(it, 'B_MUTE', 0)
        local tk = R.GetActiveTake(it)
        if tk then
          local ppitch = R.GetMediaItemTakeInfo_Value(tk, 'B_PPITCH') == 1
          local rate = R.GetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE')
          local rate_semis = (not ppitch and rate > 0) and 12 * math.log(rate, 2) or 0
          R.SetMediaItemTakeInfo_Value(tk, 'D_PITCH', p - model.BASE_NOTE - rate_semis)
        end
        if R.GetMediaItemInfo_Value(it, 'D_LENGTH') > dur then R.SetMediaItemInfo_Value(it, 'D_LENGTH', dur) end
        finish_insert(track, lane_idx, it)
      else
        insert_midi(track, lane_idx, t0, t0 + dur, p, src.vel, 0, false)
      end
      made = made + 1
    end
  end)
  return made
end

-- ── нота с удержанием (3 окт, Cmd+нота): длина = сколько держали ──────────
-- rows — строк; аудио: без stretch — item обрезается до этой длины (длиннее
-- сэмпла не тянется), stretch (Cmd+Shift) — сэмпл растягивается ровно на неё
-- с сохранением питча и становится уникальным (своя метка). MIDI — нота rows.
function E.hold_insert(spec)
  local made
  run(spec.stretch and 'hold note (stretch)' or 'hold note', function()
    -- поверх события в строке — перезапись (как обычная нота)
    local rc = spec.replace
    if rc and rc.kind == 'cont' and rc.of then E.note_off({ rc.of }, spec.lpb, spec.row)
    elseif rc and (rc.kind == 'audio' or rc.kind == 'midi') and rc.item and R.ValidatePtr(rc.item, 'MediaItem*') then E.delete({ rc }, spec.lpb) end
    local it
    if spec.slice then it = E.insert_slice(spec.track, spec.lane_idx, spec.lpb, spec.row, spec.item, spec.slice)
    else it = E.insert_note(spec.track, spec.lane_idx, spec.lpb, spec.row, spec.pitch, spec.vel, spec.rows, spec.item) end
    if it then
      local dur = row_time(spec.row + spec.rows, spec.lpb, 0) - row_time(spec.row, spec.lpb, 0)
      local tk = R.GetActiveTake(it)
      local len = R.GetMediaItemInfo_Value(it, 'D_LENGTH')
      if tk and spec.stretch and dur > 0 and len > 0 then
        local rate = R.GetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE')
        R.SetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE', rate * len / dur)
        R.SetMediaItemTakeInfo_Value(tk, 'B_PPITCH', 1)
        R.SetMediaItemInfo_Value(it, 'D_LENGTH', dur)
        E.make_unique(it)
      elseif dur > 0 and dur < len then
        R.SetMediaItemInfo_Value(it, 'D_LENGTH', dur)
      end
      made = it
    end
  end)
  return made
end

-- ── запись с MIDI-входа (INSERT + R на треке) ───────────────────────────
-- нота всегда MIDI (даже на треке с аудио): в MIDI-item строки или новый на такт
function E.rec_note(track, lane_idx, lpb, row, pitch, vel, len_rows)
  local t0 = E.swing_time(row, lpb)
  local t1 = row_time(row + math.max(1, len_rows or 1), lpb, 0)
  run('rec note', function() insert_midi(track, lane_idx, t0, t1, pitch, vel, 0, false) end)
end
-- CC / aftertouch в MIDI-item, покрывающий t (status: 0xA0 poly AT, 0xD0 channel AT, 0xB0 CC)
function E.rec_cc(track, lane_idx, t, status, chan, d1, d2)
  local it, tk = midi_item_at(track, lane_idx, t)
  if not tk then return end
  local ppq = R.MIDI_GetPPQPosFromProjTime(tk, t)
  R.MIDI_InsertCC(tk, false, false, ppq, status, chan or 0, d1 or 0, d2 or 0)
end

-- ── огибающие: точки ─────────────────────────────────────────────────────
-- Значение 0..1 от диапазона огибающей (e.min..e.max — как BR_EnvGetProperties).
-- Точка в пределах tol секунд от t правится, иначе вставляется новая.
local function env_point_at(env, t, tol)
  local idx = R.GetEnvelopePointByTime(env, t + tol)
  if idx and idx >= 0 then
    local ok, pt = R.GetEnvelopePoint(env, idx)
    if ok and math.abs(pt - t) <= tol then return idx end
  end
  return nil
end

function E.env_set(e, t, v, tol)
  v = math.max(0, math.min(1, v))
  local raw = e.min + v * (e.max - e.min)
  run('envelope ' .. e.name, function()
    local idx = env_point_at(e.env, t, tol or 0.001)
    if idx then R.SetEnvelopePoint(e.env, idx, t, raw, nil, nil, nil, true)
    else R.InsertEnvelopePoint(e.env, t, raw, 0, 0, false, true) end
    R.Envelope_SortPoints(e.env)
  end)
end

-- значение огибающей в t (0..1 от min/max)
function E.env_value(e, t)
  local _, raw = R.Envelope_Evaluate(e.env, t, 0, 0)
  local span = e.max - e.min
  local v = span > 0 and ((raw or 0) - e.min) / span or 0
  return math.max(0, math.min(1, v))
end

-- пандус: точка v0 в t0 (nil = текущее значение) и v1 в t1, промежуточные
-- точки убираются — между ними REAPER интерполирует линейно. Один undo-блок.
function E.env_ramp(e, t0, t1, v0, v1, tol)
  if t1 <= t0 then return end
  v0 = v0 or E.env_value(e, t0)
  local function raw(v) return e.min + math.max(0, math.min(1, v)) * (e.max - e.min) end
  run('envelope ramp ' .. e.name, function()
    local eps = tol or 0.001
    R.DeleteEnvelopePointRange(e.env, t0 + eps, t1 - eps)
    for _, pt in ipairs({ { t0, v0 }, { t1, v1 } }) do
      local idx = env_point_at(e.env, pt[1], eps)
      if idx then R.SetEnvelopePoint(e.env, idx, pt[1], raw(pt[2]), 0, 0, false, true)
      else R.InsertEnvelopePoint(e.env, pt[1], raw(pt[2]), 0, 0, false, true) end
    end
    R.Envelope_SortPoints(e.env)
  end)
end

-- точки огибающей в [t0, t1): { {t, v (сырое), shape, tension} … } (2 окт:
-- операторы Vim на колонке огибающей — d y c p)
function E.env_points(e, t0, t1)
  local out = {}
  for i = 0, R.CountEnvelopePoints(e.env) - 1 do
    local ok, t, v, shp, ten = R.GetEnvelopePoint(e.env, i)
    if ok and t >= t0 - 1e-9 and t < t1 - 1e-9 then out[#out + 1] = { t = t, v = v, shape = shp, tension = ten } end
  end
  return out
end
function E.env_del_range(e, t0, t1)
  local n = #E.env_points(e, t0, t1)
  if n == 0 then return 0 end
  run('envelope delete points', function() R.DeleteEnvelopePointRange(e.env, t0 - 1e-9, t1 - 1e-9) end)
  return n
end
-- вставка точек (замена в своём диапазоне): pts уже со временами цели
function E.env_put_points(e, t0, t1, pts)
  run('envelope paste points', function()
    R.DeleteEnvelopePointRange(e.env, t0 - 1e-9, t1 - 1e-9)
    for _, p in ipairs(pts) do R.InsertEnvelopePoint(e.env, p.t, p.v, p.shape or 0, p.tension or 0, false, true) end
    R.Envelope_SortPoints(e.env)
  end)
end

-- удалить огибающую целиком (родное «Envelope: Clear or remove envelope», 40065)
function E.env_remove(env)
  run('remove envelope', function()
    R.SetCursorContext(2, env)
    R.Main_OnCommand(40065, 0)
  end)
  if model then model.invalidate() end
end
function E.env_clear(env)
  run('clear envelope points', function() R.DeleteEnvelopePointRange(env, -1e9, 1e9) end)
  if model then model.invalidate() end
end
-- automation item на огибающей в [pos, pos + len) (только огибающие трека)
function E.auto_item(env, pos, len)
  local idx
  run('insert automation item', function() idx = R.InsertAutomationItem(env, -1, pos, len) end)
  if model then model.invalidate() end
  return idx
end

function E.env_del(e, t, tol)
  local idx = env_point_at(e.env, t, tol or 0.001)
  if not idx then return false end
  run('envelope del ' .. e.name, function() R.DeleteEnvelopePointEx(e.env, -1, idx) end)
  return true
end

-- сдвинуть точку у t на delta (0..1); нет точки — вставить со значением огибающей
-- форма сегмента точки в t (±tol): 0 lin 1 sqr 2 slo 3 fas 4 fae 5 bez (2 окт)
-- точка строки — по тому же правилу, что показывает модель (env_values):
-- последняя точка до начала следующей строки, если она не раньше начала этой
local function row_point(e, t0, t1)
  local idx = R.GetEnvelopePointByTime(e.env, t1 - 1e-6)
  if not idx or idx < 0 then return nil end
  local ok, pt, _, shp = R.GetEnvelopePoint(e.env, idx)
  if not ok or pt < t0 - 1e-6 then return nil end
  return idx, shp
end
function E.env_shape(e, t0, t1, shape)
  local idx = row_point(e, t0, t1)
  if not idx then return false end
  run('envelope shape', function()
    R.SetEnvelopePoint(e.env, idx, nil, nil, shape, nil, nil, true)
    R.Envelope_SortPoints(e.env)
  end)
  return true
end
function E.env_get_shape(e, t0, t1)
  local _, shp = row_point(e, t0, t1)
  return shp
end
function E.env_nudge(e, t, delta, tol)
  local idx = env_point_at(e.env, t, tol or 0.001)
  local raw
  if idx then local _, _, v = R.GetEnvelopePoint(e.env, idx); raw = v
  else local _, v = R.Envelope_Evaluate(e.env, t, 0, 0); raw = v end
  local span = e.max - e.min
  local v01 = span > 0 and (raw - e.min) / span or 0
  E.env_set(e, t, v01 + delta, tol)
end

-- ── модуляция параметра FX: переключить LFO / ACS / plink ─────────────────
function E.mod_toggle(track, m, what)
  run('mod ' .. what, function()
    local key = ('param.%d.%s.active'):format(m.param, what)
    local _, cur = R.TrackFX_GetNamedConfigParm(track, m.fx, key)
    R.TrackFX_SetNamedConfigParm(track, m.fx, key, cur == '1' and '0' or '1')
    R.TrackFX_SetNamedConfigParm(track, m.fx, ('param.%d.mod.active'):format(m.param), '1')
  end)
end

-- поле модуляции параметра (модуляционная матрица): param.N.<key> = val;
-- включение группы (lfo/acs/plink.active = 1) включает и mod.active
function E.mod_field(track, fx, param, key, val)
  run('mod ' .. key, function()
    R.TrackFX_SetNamedConfigParm(track, fx, ('param.%d.%s'):format(param, key), tostring(val))
    if key:match('%.active$') and key ~= 'mod.active' and tonumber(val) == 1 then
      R.TrackFX_SetNamedConfigParm(track, fx, ('param.%d.mod.active'):format(param), '1')
    end
  end)
  if model then model.invalidate() end
end

-- снять модуляцию параметра целиком
function E.mod_remove(track, fx, param)
  run('mod remove', function()
    for _, k in ipairs({ 'lfo.active', 'acs.active', 'plink.active', 'mod.active' }) do
      R.TrackFX_SetNamedConfigParm(track, fx, ('param.%d.%s'):format(param, k), '0')
    end
  end)
  if model then model.invalidate() end
end

-- модуляция параметра из DSP-панели: what = 'lfo' | 'acs' | 'plink';
-- on = nil — переключить; для plink нужны src_fx/src_param (источник)
function E.mod_set(track, fx, param, what, on, src_fx, src_param)
  run('mod ' .. what, function()
    local key = ('param.%d.%s.active'):format(param, what)
    if on == nil then local _, cur = R.TrackFX_GetNamedConfigParm(track, fx, key); on = cur ~= '1' end
    if what == 'plink' and on and src_fx then
      R.TrackFX_SetNamedConfigParm(track, fx, ('param.%d.plink.effect'):format(param), tostring(src_fx))
      R.TrackFX_SetNamedConfigParm(track, fx, ('param.%d.plink.param'):format(param), tostring(src_param or 0))
    end
    R.TrackFX_SetNamedConfigParm(track, fx, key, on and '1' or '0')
    R.TrackFX_SetNamedConfigParm(track, fx, ('param.%d.mod.active'):format(param), '1')
  end)
  if model then model.invalidate() end
end

-- ── DSP-панель: параметры и bypass FX ────────────────────────────────────
-- Все правки FX принимают obj = MediaTrack* или MediaItem_Take* (take FX
-- инструмента, 2 окт); функции API выбирает model.fxapi.
local function FA(obj) return model.fxapi(obj), model.is_take(obj) end
-- копия / перенос между любыми объектами (трек ↔ take)
local function copy_fx(src, si, dst, di, move)
  local st, dt = model.is_take(src), model.is_take(dst)
  if st and dt then R.TakeFX_CopyToTake(src, si, dst, di, move)
  elseif st then R.TakeFX_CopyToTrack(src, si, dst, di, move)
  elseif dt then R.TrackFX_CopyToTake(src, si, dst, di, move)
  else R.TrackFX_CopyToTrack(src, si, dst, di, move) end
end
local function add_fx(obj, name, inst)
  if model.is_take(obj) then return R.TakeFX_AddByName(obj, name, inst) end
  return R.TrackFX_AddByName(obj, name, false, inst)
end

function E.fx_param(track, fx, param, v01)
  local A = FA(track)
  A.SetParamNormalized(track, fx, param, math.max(0, math.min(1, v01)))
  if model then model.invalidate() end
end
-- значение по умолчанию (7 окт, двойной клик по параметру DSP): у REAPER
-- нет API «default», поэтому один раз на тип плагина ставится свежий
-- экземпляр в конец цепочки, его значения запоминаются, экземпляр удаляется
-- (окно скрыто, всё в одном undo-блоке с самим сбросом). Кэш — по исходному
-- имени плагина (original_name не меняется при переименовании)
E.fx_defaults = {}
function E.fx_param_default(track, fx, param)
  local A = FA(track)
  -- 8 окт: у REAPER 7 есть param.X.default_value — сначала оно (без временного экземпляра)
  local okd, dv = A.GetNamedConfigParm(track, fx, ('param.%d.default_value'):format(param))
  dv = okd and tonumber(dv)
  if dv then run('fx param default', function() A.SetParamNormalized(track, fx, param, dv) end); if model then model.invalidate() end; return dv end
  local okn, orig = A.GetNamedConfigParm(track, fx, 'original_name')
  if not okn or orig == '' then local _, nm = A.GetFXName(track, fx, ''); orig = nm end
  if not orig or orig == '' then return nil end
  local done
  run('fx param default', function()
    local d = E.fx_defaults[orig]
    if not d then
      local tmp = add_fx(track, orig, -1)
      if not tmp or tmp < 0 then return end
      A.Show(track, tmp, 2)
      d = {}
      for i = 0, A.GetNumParams(track, tmp) - 1 do d[i] = A.GetParamNormalized(track, tmp, i) end
      A.Delete(track, tmp)
      E.fx_defaults[orig] = d
    end
    if d[param] then A.SetParamNormalized(track, fx, param, d[param]); done = d[param] end
  end)
  if model then model.invalidate() end
  return done
end
-- переставить FX: src → позиция dst (как drag в цепи REAPER; в трекере слева направо)
function E.fx_move(track, src, dst)
  if src == dst then return end
  run('fx move', function() copy_fx(track, src, track, dst, true) end)
  if model then model.invalidate() end
end
-- ── контейнеры (2 окт): упаковать / распаковать, копия эффекта ───────────
-- Адрес ребёнка контейнера c (верхний уровень, с 0) на позиции k (с 0):
-- 0x2000000 + (k + 1) * (GetCount + 1) + (c + 1) — схема REAPER 7.
local function child_addr(obj, c, k)
  return 0x2000000 + (k + 1) * (FA(obj).GetCount(obj) + 1) + (c + 1)
end
-- эффекты верхнего уровня i0..i1 (индексы REAPER) → в новый контейнер на месте i0
function E.fx_pack(track, i0, i1)
  local n = i1 - i0 + 1
  if n < 1 then return false end
  local ok = false
  run('fx pack into container', function()
    local c = add_fx(track, 'Container', -1000 - i0)
    if not c or c < 0 then return end
    for k = 0, n - 1 do
      -- после каждого переноса следующий эффект встаёт сразу за контейнером
      copy_fx(track, c + 1, track, child_addr(track, c, k), true)
    end
    ok = true
  end)
  if model then model.invalidate() end
  return ok
end
-- бросок в контейнер (6 окт): новый эффект / эффект верхнего уровня — в конец
-- контейнера c. Перенос — копия внутрь + удаление оригинала: копия внутрь не
-- сдвигает индексы верхнего уровня, поэтому src остаётся верным при любом
-- порядке src / c (у move внутрь со сдвигом такой гарантии нет)
local function cont_count(obj, c)
  local ok, n = FA(obj).GetNamedConfigParm(obj, c, 'container_count')
  return ok and tonumber(n) or nil
end
-- par (6 окт): 1 — параллельно предыдущему (named parm 'parallel'), иначе за ним
local function set_par(track, addr, par)
  if par and par > 0 then FA(track).SetNamedConfigParm(track, addr, 'parallel', tostring(par)) end
end
function E.fx_add_into(track, c, name, par)
  local ok = false
  run('fx add into container', function()
    local k = cont_count(track, c); if not k then return end
    local addr = child_addr(track, c, k)
    local idx = add_fx(track, name, -1000 - addr)
    ok = idx ~= nil and idx >= 0
    if ok then set_par(track, addr, par) end
    if ok and E.open_on_add then FA(track).Show(track, idx, 3) end
  end)
  if model then model.invalidate() end
  return ok
end
function E.fx_move_into(track, src, c, par)
  if src == c then return false end
  local ok = false
  run('fx move into container', function()
    local k = cont_count(track, c); if not k then return end
    local addr = child_addr(track, c, k)
    copy_fx(track, src, track, addr, false)
    -- parallel — до удаления оригинала: адрес считан при нынешнем GetCount
    if (cont_count(track, c) or k) > k then set_par(track, addr, par); FA(track).Delete(track, src); ok = true end
  end)
  if model then model.invalidate() end
  return ok
end
-- меню контейнера (6 окт): маршрутизация ребёнка, вынос наружу, имя
function E.fx_parallel(track, addr, v)
  run('fx parallel', function() FA(track).SetNamedConfigParm(track, addr, 'parallel', tostring(v or 0)) end)
  if model then model.fx_gen = (model.fx_gen or 0) + 1; model.invalidate() end
end
-- ребёнок addr контейнера c → на верхний уровень сразу за контейнером
-- (перенос со сдвигом, как в fx_unpack — REAPER сам пересчитывает адрес)
function E.fx_move_out(track, addr, c)
  run('fx move out of container', function() copy_fx(track, addr, track, c + 1, true) end)
  if model then model.invalidate() end
end
function E.fx_rename(track, addr, name)
  run('fx rename', function() FA(track).SetNamedConfigParm(track, addr, 'renamed_name', name or '') end)
  if model then model.fx_gen = (model.fx_gen or 0) + 1; model.invalidate() end
end
-- контейнер c (верхний уровень) → его дети в цепочку сразу за ним, контейнер долой
function E.fx_unpack(track, c)
  local ok = false
  local A = FA(track)
  run('fx unpack container', function()
    local okc, cnt = A.GetNamedConfigParm(track, c, 'container_count')
    cnt = okc and tonumber(cnt) or nil
    if not cnt then return end
    for j = 0, cnt - 1 do
      local ok2, id = A.GetNamedConfigParm(track, c, 'container_item.0')
      id = ok2 and tonumber(id)
      if not id then break end
      copy_fx(track, id, track, c + 1 + j, true)
    end
    A.Delete(track, c)
    ok = true
  end)
  if model then model.invalidate() end
  return ok
end
-- копия эффекта (с объекта src, индекс si) на объект dst в позицию di
function E.fx_copy(src, si, dst, di)
  run('fx copy', function() copy_fx(src, si, dst, di, false) end)
  if model then model.invalidate() end
end
-- огибающая параметра (автоматизация): создать и показать
function E.fx_envelope(track, fx, param)
  local env
  run('show fx envelope', function()
    if model.is_take(track) then env = R.TakeFX_GetEnvelope(track, fx, param, true)
    else env = R.GetFXEnvelope(track, fx, param, true) end
  end)
  if model then model.invalidate() end
  return env
end
function E.fx_bypass(track, fx)
  local A = FA(track)
  run('fx bypass', function() A.SetEnabled(track, fx, not A.GetEnabled(track, fx)) end)
end
function E.fx_show(track, fx) FA(track).Show(track, fx, 3) end
-- параметр в track controls REAPER (8 окт): API на запись нет — правка chunk
-- трека: строка PARM_TCP после FXID эффекта (« N[:…]» на параметр; формат
-- REAPER — число и необязательный хвост). on = nil — переключить
function E.fx_param_tcp(track, fx, param, on)
  local guid = R.TrackFX_GetFXGUID(track, fx)
  if not guid then return false end
  local ok, chunk = R.GetTrackStateChunk(track, '', false)
  if not ok then return false end
  local lines, out, done, state = {}, {}, false, nil
  for ln in (chunk .. '\n'):gmatch('(.-)\n') do lines[#lines + 1] = ln end
  local i = 1
  while i <= #lines do
    local ln = lines[i]
    out[#out + 1] = ln
    local g = ln:match('^%s*FXID%s+(%b{})')
    if g and g == guid and not done then
      done = true
      local ind = ln:match('^(%s*)') or ''
      local nxt = lines[i + 1] or ''
      local rest = nxt:match('^%s*PARM_TCP%s+(.*)$')
      local toks, has = {}, false
      if rest then
        for tok in rest:gmatch('%S+') do
          if tonumber(tok:match('^(%d+)')) == param then has = true else toks[#toks + 1] = tok end
        end
        i = i + 1
      end
      local want = on; if want == nil then want = not has end
      if want then toks[#toks + 1] = tostring(param) end
      if #toks > 0 then out[#out + 1] = ind .. 'PARM_TCP ' .. table.concat(toks, ' ') end
      state = want
    end
    i = i + 1
  end
  if not done then return false end
  run('fx param in track controls', function() R.SetTrackStateChunk(track, table.concat(out, '\n'), false) end)
  return true, state
end
-- delta solo (4 окт): нативный параметр :delta эффекта (REAPER 7) — слышна
-- разница сухого и обработанного; nil — у эффекта нет :delta
function E.fx_delta_idx(obj, fx)
  local A = FA(obj)
  if not A.GetParamFromIdent then return nil end
  local i = A.GetParamFromIdent(obj, fx, ':delta')
  return (i and i >= 0) and i or nil
end
function E.fx_delta(obj, fx)
  local i = E.fx_delta_idx(obj, fx)
  if not i then return nil end
  local A = FA(obj)
  local on = A.GetParamNormalized(obj, fx, i) >= 0.5
  run('fx delta solo', function() A.SetParamNormalized(obj, fx, i, on and 0 or 1) end)
  if model then model.invalidate() end
  return not on
end

-- компенсация громкости цепочки (4 окт): нативной у REAPER нет — стоковый
-- JS: Volume Adjustment последним в цепи, переименован в «gain comp»;
-- трекер подводит его так, чтобы выход цепи (до фейдера) = вход до эффектов
E.COMP_NAME = 'gain comp'
function E.comp_find(tr)
  for i = 0, R.TrackFX_GetCount(tr) - 1 do
    local ok, nm = R.TrackFX_GetNamedConfigParm(tr, i, 'renamed_name')
    if ok and nm == E.COMP_NAME then return i end
  end
end
function E.comp_db(tr)
  local i = E.comp_find(tr)
  return i and R.TrackFX_GetParam(tr, i, 0) or nil, i
end
-- без undo на каждый шаг подстройки (идёт за кадрами); undo — на вкл / выкл
function E.comp_set(tr, db)
  local i = E.comp_find(tr)
  if i then R.TrackFX_SetParam(tr, i, 0, math.max(-24, math.min(24, db))) end
end
function E.comp_add(tr)
  local i = E.comp_find(tr)
  if i then
    -- держать последним в цепи: после него добавили эффекты — перенести в конец
    local n = R.TrackFX_GetCount(tr)
    if i ~= n - 1 then R.TrackFX_CopyToTrack(tr, i, tr, n - 1, true); i = n - 1 end
    return i
  end
  run('gain comp on', function()
    i = R.TrackFX_AddByName(tr, 'JS: Volume Adjustment', false, -1)
    if i and i >= 0 then
      R.TrackFX_SetNamedConfigParm(tr, i, 'renamed_name', E.COMP_NAME)
      R.TrackFX_SetParam(tr, i, 0, 0)
      R.TrackFX_SetParam(tr, i, 1, 150)     -- потолок клипа выключен
      R.TrackFX_Show(tr, i, 2)
    end
  end)
  if model then model.invalidate() end
  return i
end
function E.comp_remove(tr)
  local i = E.comp_find(tr)
  if not i then return false end
  run('gain comp off', function() R.TrackFX_Delete(tr, i) end)
  if model then model.invalidate() end
  return true
end
-- окно цепочки take (и пустой): выделить item и «show FX chain for item take»
function E.take_chain_window(take)
  local it = R.GetMediaItemTake_Item(take)
  if not it then return end
  if R.TakeFX_GetCount(take) > 0 then R.TakeFX_Show(take, 0, 1); return end
  R.SelectAllMediaItems(0, false)
  R.SetMediaItemSelected(it, true)
  R.SetActiveTake(take)
  R.Main_OnCommand(40638, 0)                 -- Item: Show FX chain for item take
end
-- pos — место в цепочке (0 = первым), nil — в конец
-- окно FX после добавления (5 окт, галочка в меню DSP): false — закрыть
-- (параметры и так в блоке DSP), true — открыть; REAPER сам может открыть
E.open_on_add = false
function E.fx_add(track, name, pos)
  run('fx add', function()
    local idx = add_fx(track, name, pos and (-1000 - pos) or -1)
    if idx and idx >= 0 then FA(track).Show(track, idx, E.open_on_add and 3 or 2) end
  end)
  if model then model.invalidate() end
end
-- unpar (7 окт, DSP big): адрес следующего звена — снять у него parallel
-- до удаления, иначе оно прилипнет к прошлому ряду
function E.fx_remove(track, fx, unpar)
  run('fx remove', function()
    if unpar then FA(track).SetNamedConfigParm(track, unpar, 'parallel', '0') end
    FA(track).Delete(track, fx)
  end)
  if model and unpar then model.fx_gen = (model.fx_gen or 0) + 1; model.invalidate() end
end
function E.fx_set_enabled(track, fx, on)
  run(on and 'fx on' or 'fx bypass', function() FA(track).SetEnabled(track, fx, on and true or false) end)
end
-- вставка в позицию pos (7 окт, DSP big): c = nil — верх цепочки, иначе
-- индекс контейнера верхнего уровня; par 1 — в ряд к предыдущему
function E.fx_insert(track, c, pos, name, par)
  local ok = false
  run('fx insert', function()
    local addr = c and child_addr(track, c, pos) or pos
    local idx = add_fx(track, name, -1000 - addr)
    ok = idx ~= nil and idx >= 0
    if ok then set_par(track, addr, par) end
    if ok and E.open_on_add then FA(track).Show(track, idx, 3) end
  end)
  if model then model.fx_gen = (model.fx_gen or 0) + 1; model.invalidate() end
  return ok
end

-- ── осциллоскопы: JSFX-мост jf_tracker_scope на треках ───────────────────
-- on: find-or-add (instantiate −1 — не плодить копии), slider1 = слот;
-- off: удалить все экземпляры. Трек DEPOT не трогаем.
E.MASTER_SCOPE_SLOT = 31
function E.scopes(cols, on)
  run(on and 'scopes on' or 'scopes off', function()
    local function put(tr, slot)
      local fx = R.TrackFX_GetByName(tr, 'jf_tracker_scope', false)
      if on then
        if fx < 0 then fx = R.TrackFX_AddByName(tr, 'jf_tracker_scope', false, -1) end
        -- окно мост открывать не должен (4 окт): REAPER показывает FX при
        -- добавлении — сразу закрыть (и у уже стоящих)
        if fx >= 0 then R.TrackFX_SetParam(tr, fx, 0, slot); R.TrackFX_Show(tr, fx, 2) end
      else
        while fx >= 0 do R.TrackFX_Delete(tr, fx); fx = R.TrackFX_GetByName(tr, 'jf_tracker_scope', false) end
      end
    end
    for i, col in ipairs(cols) do put(col.track, (i - 1) % 31) end
    if R.GetMasterTrack then put(R.GetMasterTrack(0), E.MASTER_SCOPE_SLOT) end   -- вкладка master
  end)
end

-- ретро-буфер jf_rec на треке: добавить со свободным слотом (0..63)
function E.retro_add(track, cols)
  local used = {}
  for _, c in ipairs(cols or {}) do if c.rec_slot then used[c.rec_slot] = true end end
  local slot = 0
  while used[slot] and slot < 63 do slot = slot + 1 end
  local fx
  run('retro: add jf_rec', function()
    fx = R.TrackFX_GetByName(track, 'jf_rec', false)
    if fx < 0 then fx = R.TrackFX_AddByName(track, 'jf_rec', false, -1) end
    if fx >= 0 then R.TrackFX_SetParam(track, fx, 1, slot); R.TrackFX_Show(track, fx, 2) end   -- без плавающего окна
  end)
  return fx and fx >= 0, slot
end

-- ── время внутри региона: удалить / вставить (Backspace / Insert) ────────
-- Всё, что начинается в [t1, limit), едет на dt влево (delete) или вправо
-- (insert); дальше limit (конец региона) ничего не трогаем — паттерны жёсткие.
-- Items, попавшие под нож, режутся; автоматизация — точки и automation items
-- всех огибающих трека. tracks — список MediaTrack.
local function env_shift(tr, t0, t1, dt, limit, mode)
  if not R.CountTrackEnvelopes then return end
  for ei = 0, R.CountTrackEnvelopes(tr) - 1 do
    local env = R.GetTrackEnvelope(tr, ei)
    for pi = R.CountEnvelopePoints(env) - 1, 0, -1 do
      local ok, t, v, shape, tens, sel = R.GetEnvelopePoint(env, pi)
      if ok then
        if mode == 'del' then
          if t >= t0 - EPS and t < t1 - EPS then R.DeleteEnvelopePointEx(env, -1, pi)
          elseif t >= t1 - EPS and t < limit - EPS then R.SetEnvelopePoint(env, pi, t - dt, v, shape, tens, sel, true) end
        else
          if t >= t0 - EPS and t < limit - EPS then
            if t + dt >= limit - EPS then R.DeleteEnvelopePointEx(env, -1, pi)
            else R.SetEnvelopePoint(env, pi, t + dt, v, shape, tens, sel, true) end
          end
        end
      end
    end
    if R.CountAutomationItems then
      for ai = R.CountAutomationItems(env) - 1, 0, -1 do
        local pos = R.GetSetAutomationItemInfo(env, ai, 'D_POSITION', 0, false)
        if mode == 'del' then
          if pos >= t1 - EPS and pos < limit - EPS then R.GetSetAutomationItemInfo(env, ai, 'D_POSITION', pos - dt, true) end
        elseif pos >= t0 - EPS and pos < limit - EPS then
          R.GetSetAutomationItemInfo(env, ai, 'D_POSITION', pos + dt, true)
        end
      end
    end
    R.Envelope_SortPoints(env)
  end
end

function E.time_delete(tracks, t0, t1, limit)
  local dt = t1 - t0
  if dt <= 0 then return end
  run(('delete time %.3fs'):format(dt), function()
    for _, tr in ipairs(tracks) do
      for i = R.CountTrackMediaItems(tr) - 1, 0, -1 do
        local it = R.GetTrackMediaItem(tr, i)
        local pos = R.GetMediaItemInfo_Value(it, 'D_POSITION')
        local fin = pos + R.GetMediaItemInfo_Value(it, 'D_LENGTH')
        if pos < limit - EPS and fin > t0 + EPS then
          if pos >= t1 - EPS then R.SetMediaItemInfo_Value(it, 'D_POSITION', pos - dt)
          elseif pos < t0 - EPS and fin > t1 + EPS then
            local right = R.SplitMediaItem(it, t1)
            local mid = R.SplitMediaItem(it, t0)
            if mid then R.DeleteTrackMediaItem(tr, mid) end
            if right then R.SetMediaItemInfo_Value(right, 'D_POSITION', t1 - dt) end
          elseif pos < t0 - EPS then R.SetMediaItemInfo_Value(it, 'D_LENGTH', t0 - pos)
          elseif fin > t1 + EPS then
            local right = R.SplitMediaItem(it, t1)
            R.DeleteTrackMediaItem(tr, it)
            if right then R.SetMediaItemInfo_Value(right, 'D_POSITION', t1 - dt) end
          else R.DeleteTrackMediaItem(tr, it) end
        end
      end
      env_shift(tr, t0, t1, dt, limit, 'del')
    end
  end)
end

function E.time_insert(tracks, t0, dt, limit)
  if dt <= 0 then return end
  run(('insert time %.3fs'):format(dt), function()
    for _, tr in ipairs(tracks) do
      for i = R.CountTrackMediaItems(tr) - 1, 0, -1 do
        local it = R.GetTrackMediaItem(tr, i)
        local pos = R.GetMediaItemInfo_Value(it, 'D_POSITION')
        local fin = pos + R.GetMediaItemInfo_Value(it, 'D_LENGTH')
        if pos < limit - EPS and fin > t0 + EPS then
          local target = it
          if pos < t0 - EPS then target = R.SplitMediaItem(it, t0) end   -- правая часть едет
          if target then
            local np = R.GetMediaItemInfo_Value(target, 'D_POSITION') + dt
            local len = R.GetMediaItemInfo_Value(target, 'D_LENGTH')
            if np >= limit - EPS then R.DeleteTrackMediaItem(tr, target)
            else
              R.SetMediaItemInfo_Value(target, 'D_POSITION', np)
              if np + len > limit + EPS then R.SetMediaItemInfo_Value(target, 'D_LENGTH', limit - np) end
            end
          end
        end
      end
      env_shift(tr, t0, nil, dt, limit, 'ins')
    end
  end)
end

-- ── beatsync «дотянуть до границы» (быстрая клавиша B / :beatsync) ────────
-- Конец события тянется (stretch, B_PPITCH сохраняет питч) к ближайшей
-- границе сетки: unit = 'beat' (доля), 'bar' (такт) или число строк. MIDI —
-- длина ноты до той же границы. heads — события курсора / выделения.
function E.beatsync(heads, lpb, unit)
  if #heads == 0 then return 0 end
  local n = 0
  run('beatsync ' .. tostring(unit), function()
    for _, h in ipairs(heads) do
      local pos, fin
      if h.kind == 'audio' and h.item then
        pos = R.GetMediaItemInfo_Value(h.item, 'D_POSITION'); fin = pos + R.GetMediaItemInfo_Value(h.item, 'D_LENGTH')
      elseif h.kind == 'midi' then
        local i, nt = midi_note(h, lpb)
        if i then pos = R.MIDI_GetProjTimeFromPPQPos(h.take, nt.sppq); fin = R.MIDI_GetProjTimeFromPPQPos(h.take, nt.eppq) end
      end
      if pos then
        local q1 = R.TimeMap2_timeToQN(0, fin)
        local q0 = R.TimeMap2_timeToQN(0, pos)
        local step
        if unit == 'bar' then local _, qms, qme = R.TimeMap_QNToMeasures(0, q1); step = (qme and qms) and (qme - qms) or 4
        elseif unit == 'beat' or unit == nil then step = 1
        else step = tonumber(unit) / lpb end
        -- ближайшая граница от начала события, не короче одного шага
        local k = math.max(1, math.floor((q1 - q0) / step + 0.5))
        local target_qn = q0 + k * step
        local target = R.TimeMap2_QNToTime(0, target_qn)
        if h.kind == 'audio' then
          local tk = R.GetActiveTake(h.item)
          local len_t = target - pos
          local cur = fin - pos
          if tk and len_t > 0.001 and math.abs(len_t - cur) > 1e-4 then
            local rate = R.GetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE')
            R.SetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE', rate * cur / len_t)
            R.SetMediaItemTakeInfo_Value(tk, 'B_PPITCH', 1)
            R.SetMediaItemInfo_Value(h.item, 'D_LENGTH', len_t)
            E.note_modified(h.item)
            n = n + 1
          end
        else
          local i, nt = midi_note(h, lpb)
          if i then
            local eppq = R.MIDI_GetPPQPosFromProjTime(h.take, target)
            if eppq > nt.sppq + 1 then R.MIDI_SetNote(h.take, i, nt.sel, nt.muted, nt.sppq, eppq, nt.ch, nt.pitch, nt.vel, false); n = n + 1 end
          end
        end
      end
    end
  end)
  return n
end

-- ── мышь: растянуть / сжать / сдвинуть item (как в аранжировке REAPER) ──
-- Жест = один undo-блок: begin при нажатии, end при отпускании.
local drag_open = false
function E.item_drag_begin(desc)
  if drag_open then return end
  R.Undo_BeginBlock2(0); drag_open = desc or 'item drag'
end
function E.item_drag_end()
  if not drag_open then return end
  R.Undo_EndBlock2(0, 'jf_tracker: ' .. tostring(drag_open), -1)
  drag_open = false
  if model then model.invalidate() end
  if E.after and not E.in_after then E.in_after = true; pcall(E.after, 'item drag'); E.in_after = false end
end
-- edge: 'end' — конец в t; 'start' — начало в t (offset источника едет
-- следом, как trim в REAPER); 'move' — сдвиг начала в t с той же длиной
-- stretch = { len0 =, rate0 = } — Option на краю: растяжение (playrate), как
-- Alt+край в REAPER; высота — по настройке take (preserve pitch), 2 окт
function E.item_drag_to(item, edge, t, min_len, stretch)
  local pos = R.GetMediaItemInfo_Value(item, 'D_POSITION')
  local len = R.GetMediaItemInfo_Value(item, 'D_LENGTH')
  min_len = min_len or 0.01
  local tk = stretch and R.GetActiveTake(item)
  if tk and (edge == 'end' or edge == 'start') then
    local fin = pos + len
    local nlen = edge == 'end' and math.max(min_len, t - pos) or math.max(min_len, fin - math.max(0, t))
    R.SetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE', math.max(0.01, stretch.rate0 * stretch.len0 / nlen))
    if edge == 'start' then R.SetMediaItemInfo_Value(item, 'D_POSITION', fin - nlen) end
    R.SetMediaItemInfo_Value(item, 'D_LENGTH', nlen)
    R.UpdateItemInProject(item)
    return
  end
  if edge == 'end' then
    R.SetMediaItemInfo_Value(item, 'D_LENGTH', math.max(min_len, t - pos))
  elseif edge == 'start' then
    local fin = pos + len
    t = math.max(0, math.min(t, fin - min_len))
    local tk = R.GetActiveTake(item)
    if tk then
      local rate = R.GetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE')
      local offs = R.GetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS')
      R.SetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS', math.max(0, offs + (t - pos) * rate))
    end
    R.SetMediaItemInfo_Value(item, 'D_POSITION', t)
    R.SetMediaItemInfo_Value(item, 'D_LENGTH', fin - t)
  else
    R.SetMediaItemInfo_Value(item, 'D_POSITION', math.max(0, t))
  end
  R.UpdateItemInProject(item)
end

-- ── прочее ────────────────────────────────────────────────────────────────
function E.undo() R.Main_OnCommand(40029, 0); if model then model.invalidate() end end
function E.redo() R.Main_OnCommand(40030, 0); if model then model.invalidate() end end
function E.save() R.Main_SaveProject(0, false) end
function E.play_stop() R.Main_OnCommand(40044, 0) end
function E.cursor_to(t) R.SetEditCurPos(t, false, false) end

-- mute всех items трека внутри [t0, t1) — для матрицы
function E.mute_span(track, t0, t1, flag)
  run('matrix mute', function()
    for i = 0, R.CountTrackMediaItems(track) - 1 do
      local it = R.GetTrackMediaItem(track, i)
      local pos = R.GetMediaItemInfo_Value(it, 'D_POSITION')
      local len = R.GetMediaItemInfo_Value(it, 'D_LENGTH')
      if pos < t1 and pos + len > t0 then
        local v = flag
        if v == nil then v = R.GetMediaItemInfo_Value(it, 'B_MUTE') ~= 1 end
        R.SetMediaItemInfo_Value(it, 'B_MUTE', v and 1 or 0)
      end
    end
  end)
end

-- ── библиотека — трек LIB (8 окт) ─────────────────────────────────────────
-- Заглушённый трек LIB в конце: fixed lanes, каждый инструмент — свой лейн,
-- item с позиции 0 (не наслаиваются и не удлиняют проект, в мастер-рендер
-- не попадают); лейн подписан именем инструмента; P_EXT:jf_home — GUID
-- трека-владельца (lib показывает семпл под ним). Маркера =LIB больше нет.
function E.lib_track(create)
  for ti = 0, R.CountTracks(0) - 1 do
    local t = R.GetTrack(0, ti)
    local _, name = R.GetTrackName(t)
    if model.is_lib_name(name) then return t end
  end
  if not create then return nil end
  R.InsertTrackAtIndex(R.CountTracks(0), false)
  local tr = R.GetTrack(0, R.CountTracks(0) - 1)
  R.GetSetMediaTrackInfo_String(tr, 'P_NAME', model.DEPOT, true)
  R.SetMediaTrackInfo_Value(tr, 'B_MUTE', 1)
  R.SetMediaTrackInfo_Value(tr, 'I_FREEMODE', 2)
  R.SetMediaTrackInfo_Value(tr, 'I_NUMFIXEDLANES', 1)
  return tr
end
-- место под новый инструмент: трек LIB, свободный лейн (первый пустой или
-- новый в конце); возвращает трек, номер лейна, позицию 0
function E.lib_slot()
  local tr = E.lib_track(true)
  local n = math.max(1, math.floor(R.GetMediaTrackInfo_Value(tr, 'I_NUMFIXEDLANES')))
  local used = {}
  for i = 0, R.CountTrackMediaItems(tr) - 1 do used[math.floor(R.GetMediaItemInfo_Value(R.GetTrackMediaItem(tr, i), 'I_FIXEDLANE'))] = true end
  for l = 0, n - 1 do if not used[l] then return tr, l, 0 end end
  R.SetMediaTrackInfo_Value(tr, 'I_NUMFIXEDLANES', n + 1)
  return tr, n, 0
end
-- item в LIB: лейн, владелец, имя лейна = имя take
function E.lib_mark(it, home, lane)
  if not (it and R.ValidatePtr(it, 'MediaItem*')) then return end
  local tr = R.GetMediaItem_Track(it)
  R.SetMediaItemInfo_Value(it, 'D_POSITION', 0)
  if lane then R.SetMediaItemInfo_Value(it, 'I_FIXEDLANE', lane) end
  if home and R.ValidatePtr(home, 'MediaTrack*') then R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_home', model.track_guid(home), true) end
  local tk = R.GetActiveTake(it)
  if tr and lane and tk then R.GetSetMediaTrackInfo_String(tr, 'P_LANENAME:' .. lane, R.GetTakeName(tk), true) end
end
-- есть ли файл fn у владельца tr в LIB (страховка сэмплов не дублирует)
function E.lib_has(fn, home)
  local tr = E.lib_track(false)
  if not tr then return false end
  local g = model.track_guid(home)
  for i = 0, R.CountTrackMediaItems(tr) - 1 do
    local it = R.GetTrackMediaItem(tr, i)
    local _, h = R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_home', '', false)
    local tk = R.GetActiveTake(it)
    if h == g and tk and root_file(R.GetMediaItemTake_Source(tk)) == fn then return true end
  end
  return false
end

-- файл → библиотека трека track (трек LIB, свой лейн). Возвращает item
function E.depot_add(path, track)
  local item
  path = E.media_copy(path)
  run('lib add', function()
    local src = R.PCM_Source_CreateFromFile(path)
    if not src then return end
    local tr, lane = E.lib_slot()
    item = R.AddMediaItemToTrack(tr)
    local tk = R.AddTakeToMediaItem(item)
    R.SetMediaItemTake_Source(tk, src)
    R.SetMediaItemInfo_Value(item, 'D_LENGTH', R.GetMediaSourceLength(src) or 1)
    R.GetSetMediaItemTakeInfo_String(tk, 'P_NAME', path:match('([^/]+)%.%w+$') or path, true)
    E.lib_mark(item, track, lane)
  end)
  return item
end

-- файл → депо трека: item после маркера =LIB (конец зоны библиотеки трека);
-- трек не задан — наследие: трек DEPOT (создаётся)
-- ── наборы lib (4 окт): шаблон трека REAPER ───────────────────────────────
-- Набор = сэмплы lib (item с нарезкой, метками, take FX) в родном формате
-- REAPER — шаблоне трека TrackTemplates/jf_kits/<имя>.RTrackTemplate: его
-- открывает и сам REAPER (Insert track from template). items — item сэмплов.
function E.kit_dir() return R.GetResourcePath() .. '/TrackTemplates/jf_kits' end
local function set_chunk_pos(chunk, pos)
  return (chunk:gsub('\nPOSITION [^\n]*', '\nPOSITION ' .. ('%.10f'):format(pos), 1))
end
function E.kit_save(items, name)
  local dir = E.kit_dir()
  R.RecursiveCreateDirectory(dir, 0)
  local parts, pos = { '<TRACK', '  NAME "' .. name:gsub('"', "'") .. '"' }, 0
  for _, it in ipairs(items) do
    if R.ValidatePtr(it, 'MediaItem*') then
      local ok, ch = R.GetItemStateChunk(it, '', false)
      if ok then
        parts[#parts + 1] = set_chunk_pos(strip_guids(ch), pos):gsub('\n$', '')
        pos = pos + R.GetMediaItemInfo_Value(it, 'D_LENGTH') + 1
      end
    end
  end
  parts[#parts + 1] = '>'
  local path = dir .. '/' .. name:gsub('[/\\:]', '_') .. '.RTrackTemplate'
  local f = io.open(path, 'w')
  if not f then return nil end
  f:write(table.concat(parts, '\n'), '\n'); f:close()
  return path, #parts - 3
end
-- блоки <ITEM …> шаблона (по глубине строк: в именах файлов бывают скобки)
function E.kit_items(text)
  local out, cur, depth = {}, nil, 0
  for line in (text .. '\n'):gmatch('([^\n]*)\n') do
    local t = line:match('^%s*(.-)%s*$')
    if not cur and t:match('^<ITEM') then cur, depth = { line }, 1
    elseif cur then
      cur[#cur + 1] = line
      if t:sub(1, 1) == '<' then depth = depth + 1 elseif t == '>' then depth = depth - 1 end
      if depth == 0 then out[#out + 1] = table.concat(cur, '\n'); cur = nil end
    end
  end
  return out
end
-- набор → lib трека track (за =LIB, после последнего item); число сэмплов
function E.kit_load(path, track)
  local f = io.open(path, 'r'); if not f then return 0 end
  local text = f:read('*a'); f:close()
  local chunks = E.kit_items(text)
  local n = 0
  run('kit load', function()
    for _, ch in ipairs(chunks) do                 -- 8 окт: каждый сэмпл — свой лейн трека LIB
      local tr, lane = E.lib_slot()
      local it = R.AddMediaItemToTrack(tr)
      if R.SetItemStateChunk(it, set_chunk_pos(ch, 0), false) then E.lib_mark(it, track, lane); n = n + 1
      else R.DeleteTrackMediaItem(tr, it) end
    end
  end)
  return n
end


-- ── инструменты как объекты Vim (2 окт): dd / yy / p в модуле инструментов ──
-- Снимок инструмента: чанк его item без GUID и имя take (нарезка P_EXT
-- остаётся в чанке — дубль нарезанного сэмпла тоже нарезан).
function E.inst_snapshot(item)
  local ok, chunk = R.GetItemStateChunk(item, '', false)
  if not ok then return nil end
  local tk = R.GetActiveTake(item)
  return { chunk = strip_guids(chunk), name = tk and R.GetTakeName(tk) or '' }
end

-- вырезать: все items инструмента (события и библиотека) одним undo-шагом;
-- страховка сэмплов выключена — сэмпл уходит нарочно (он в регистре)
function E.inst_delete(items)
  local n = 0
  E.no_rescue = true
  run('instrument cut', function()
    for _, it in ipairs(items) do
      if R.ValidatePtr(it, 'MediaItem*') then
        local tr = R.GetMediaItem_Track(it)
        if tr and R.DeleteTrackMediaItem(tr, it) then n = n + 1 end
      end
    end
  end)
  return n
end

-- положить снимки в библиотеку трека (за =LIB, после последнего item);
-- names[k] — имя take копии (новое, иначе пул склеит её с оригиналом).
-- Возвращает новые items.
function E.inst_put(track, snaps, names)
  local out = {}
  run('instrument put', function()
    for k, sn in ipairs(snaps) do                  -- 8 окт: в трек LIB, свой лейн
      local tr, lane = E.lib_slot()
      local it = R.AddMediaItemToTrack(tr)
      R.SetItemStateChunk(it, sn.chunk, false)
      local tk = R.GetActiveTake(it)
      if tk and names and names[k] then R.GetSetMediaItemTakeInfo_String(tk, 'P_NAME', names[k], true) end
      E.lib_mark(it, track, lane)
      out[#out + 1] = it
    end
  end)
  return out
end

-- ── копия файла в папку проекта (2 окт) ───────────────────────────────────
-- Файл из браузера (drop, вставка, замена, депо) копируется в папку медиа
-- проекта (GetProjectPath), если проект сохранён и опция E.copy_media
-- включена; иначе — путь как есть. Уже лежащий в проекте файл не копируется;
-- одноимённый другого размера получает суффикс « 2».
E.copy_media = true
local function fsize(p) local f = io.open(p, 'rb'); if not f then return nil end; local n = f:seek('end'); f:close(); return n end
function E.media_copy(path)
  if not (E.copy_media and path and path ~= '') then return path end
  if path:lower():match('%.rpp$') then return path end
  local _, proj = R.EnumProjects(-1, '')
  if not proj or proj == '' then return path end           -- несохранённый проект: папки нет
  local dir = R.GetProjectPath()
  if not dir or dir == '' then return path end
  if path:sub(1, #dir + 1) == dir .. '/' then return path end
  local projdir = proj:match('^(.*)/[^/]+$')
  if projdir and path:sub(1, #projdir + 1) == projdir .. '/' then return path end
  local name = path:match('[^/]+$')
  local size = fsize(path)
  if not size then return path end
  R.RecursiveCreateDirectory(dir, 0)
  local base, ext = name:match('^(.*)(%.[^.]+)$')
  base, ext = base or name, ext or ''
  local dst, k = dir .. '/' .. name, 2
  while true do
    local ds = fsize(dst)
    if not ds then break end
    if ds == size then return dst end                          -- уже скопирован
    dst = ('%s/%s %d%s'):format(dir, base, k, ext); k = k + 1
  end
  local fi = io.open(path, 'rb'); if not fi then return path end
  local fo = io.open(dst, 'wb'); if not fo then fi:close(); return path end
  while true do local chunk = fi:read(1048576); if not chunk then break end; fo:write(chunk) end
  fi:close(); fo:close()
  E.copied = dst
  return dst
end

-- drag & drop из браузера: файл → item на треке в строке row (lane по
-- фиксированным дорожкам); .rpp → сабпроект (InsertMedia, как jf_pm)
function E.drop(track, lane_idx, lpb, row, path)
  local t = row_time(row, lpb, 0)
  path = E.media_copy(path)
  local item
  run('drop ' .. (path:match('[^/]+$') or path), function()
    if path:lower():match('%.rpp$') then
      R.Main_OnCommand(40289, 0)                       -- unselect items: InsertMedia выделит свой
      R.SetOnlyTrackSelected(track)
      local cur = R.GetCursorPosition()
      R.SetEditCurPos(t, false, false)
      R.InsertMedia(path, 0)
      R.SetEditCurPos(cur, false, false)
      item = R.GetSelectedMediaItem(0, 0)
    else
      local src = R.PCM_Source_CreateFromFile(path)
      if not src then return end
      item = R.AddMediaItemToTrack(track)
      local tk = R.AddTakeToMediaItem(item)
      R.SetMediaItemTake_Source(tk, src)
      local len = R.GetMediaSourceLength(src)
      R.SetMediaItemInfo_Value(item, 'D_POSITION', t)
      R.SetMediaItemInfo_Value(item, 'D_LENGTH', len or 1)
      R.GetSetMediaItemTakeInfo_String(tk, 'P_NAME', path:match('([^/]+)%.%w+$') or path, true)
    end
    if item and lane_idx and R.GetMediaTrackInfo_Value(track, 'I_FREEMODE') == 2 then
      R.SetMediaItemInfo_Value(item, 'I_FIXEDLANE', lane_idx)
    end
    if item and not path:lower():match('%.rpp$') then xfade_join(track, lane_idx, item) end
  end)
  return item
end

-- трек из другого проекта (chunk с абсолютными FILE) — после after_track или в конец
function E.insert_track_chunk(chunk, name, after_track)
  local tr
  run('insert track ' .. (name or ''), function()
    local idx = R.CountTracks(0)
    if after_track then idx = math.floor(R.GetMediaTrackInfo_Value(after_track, 'IP_TRACKNUMBER')) end
    R.InsertTrackAtIndex(idx, false)
    tr = R.GetTrack(0, idx)
    if tr then R.SetTrackStateChunk(tr, chunk, false) end
  end)
  if model then model.invalidate() end
  return tr
end

-- сабпроект, обрезанный по региону источника (как в jf_pm): после E.drop
function E.drop_region(track, lane_idx, lpb, row, path, region)
  local it = E.drop(track, lane_idx, lpb, row, path)
  if it and region then
    run('trim subproject to region', function()
      R.SetMediaItemInfo_Value(it, 'D_LENGTH', region.fin - region.pos)
      local tk = R.GetActiveTake(it)
      if tk then R.SetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS', region.pos) end
    end)
  end
  return it
end

-- ── лупы в регионах (F1, 2 окт) ──────────────────────────────────────────
-- Полиметрия: item лупится своей длиной внутри региона. Период аудио-лупа =
-- длина источника / rate, поэтому «луп N шагов» делает SECTION-источник
-- (API не умеет ставить секцию иначе, чем через чанк item).
--
-- Блок <SOURCE …> активного take в чанке item: построчный разбор со счётчиком
-- глубины (не %b<>: в именах файлов бывают скобки). Источник take — прямой
-- ребёнок <ITEM (глубина 2); у SECTION внутри вложенный <SOURCE файла>.
local function source_block(chunk)
  local lines = {}
  for l in (chunk .. '\n'):gmatch('([^\n]*)\n') do lines[#lines + 1] = l end
  local depth, s, e, kind = 0, nil, nil, nil
  for i, l in ipairs(lines) do
    if l:match('^%s*<') then
      depth = depth + 1
      if not s and depth == 2 and l:match('^%s*<SOURCE%s') then s = i; kind = l:match('^%s*<SOURCE%s+(%S+)') end
    elseif l:match('^%s*>%s*$') then
      if s and not e and depth == 2 then e = i end
      depth = depth - 1
    end
    if e then break end
  end
  if not s or not e then return nil end
  local info = { s = s, e = e, kind = kind, lines = lines, startpos = 0, length = 0 }
  if kind == 'SECTION' then
    local d2, is, ie = 0, nil, nil
    for i = s + 1, e - 1 do
      local l = lines[i]
      if d2 == 0 then
        local sp = l:match('^%s*STARTPOS%s+([%d%.%-eE]+)'); if sp then info.startpos = tonumber(sp) or 0 end
        local ln = l:match('^%s*LENGTH%s+([%d%.%-eE]+)'); if ln then info.length = tonumber(ln) or 0 end
      end
      if l:match('^%s*<') then d2 = d2 + 1; if d2 == 1 and not is then is = i end
      elseif l:match('^%s*>%s*$') then if d2 == 1 and is and not ie then ie = i end; d2 = d2 - 1 end
    end
    if is and ie then info.inner = table.concat(lines, '\n', is, ie) end
  else
    info.inner = table.concat(lines, '\n', s, e)
  end
  return info
end

-- Источник активного take → SECTION [start, start+len) исходного файла.
-- Уже секцию разворачиваем (STARTPOS складывается), вложенности нет.
-- Без своего undo — зовётся внутри run(). Multi-take не поддерживаем.
-- стык лупа item тянется (2 окт): mode 'len' — длина периода источника
-- (аудио — SECTION, MIDI — длина источника, длина item та же), 'rate' —
-- растяжение (playrate). v — новая длина в секундах / новый playrate.
function E.loop_period(item, mode, v)
  local tk = R.GetActiveTake(item)
  if not tk then return false end
  local ok = true
  run(mode == 'rate' and 'loop stretch' or 'loop length', function()
    if mode == 'rate' then
      R.SetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE', math.max(0.05, math.min(20, v)))
    elseif R.TakeIsMIDI(tk) then
      local pos = R.GetMediaItemInfo_Value(item, 'D_POSITION')
      local len = R.GetMediaItemInfo_Value(item, 'D_LENGTH')
      local q0 = R.TimeMap2_timeToQN(0, pos)
      R.MIDI_SetItemExtents(item, q0, R.TimeMap2_timeToQN(0, pos + math.max(0.01, v)))
      R.SetMediaItemInfo_Value(item, 'D_POSITION', pos)
      R.SetMediaItemInfo_Value(item, 'D_LENGTH', len)
      R.SetMediaItemInfo_Value(item, 'B_LOOPSRC', 1)
    else
      local okk, why = E.set_section(item, 0, math.max(0.01, v))
      ok = okk ~= false
      if not ok then E.loop_err = why end
    end
    R.UpdateItemInProject(item)
  end)
  if model then model.invalidate() end
  return ok
end

function E.set_section(item, start, len)
  if R.CountTakes(item) > 1 then return false, 'multi-take item' end
  local ok, chunk = R.GetItemStateChunk(item, '', false)
  if not ok then return false, 'no chunk' end
  local sb = source_block(chunk)
  if not sb or not sb.inner then return false, 'no source block' end
  local base = sb.kind == 'SECTION' and sb.startpos or 0
  local new = ('<SOURCE SECTION\n  LENGTH %.10f\n  STARTPOS %.10f\n%s\n>'):format(len, base + start, sb.inner)
  local out = {}
  for i = 1, sb.s - 1 do out[#out + 1] = sb.lines[i] end
  out[#out + 1] = new
  for i = sb.e + 1, #sb.lines do out[#out + 1] = sb.lines[i] end
  R.SetItemStateChunk(item, table.concat(out, '\n'), false)
  R.UpdateItemInProject(item)
  return true
end

-- Луп items до конца региона rgnend; nsteps = период ровно N шагов
-- (аудио — секция от текущего offset; MIDI — MIDI_SetItemExtents задаёт длину
-- источника). Без nsteps аудио с offset > 0 тоже получает секцию [offs, конец):
-- иначе REAPER зациклит с начала файла. Возвращает число items и предупреждение.
function E.loop_items(items, lpb, rgnend, nsteps)
  local n, warn = 0, nil
  run(nsteps and ('loop %d rows'):format(nsteps) or 'loop to region end', function()
    for _, it in ipairs(items) do
      local take = R.GetActiveTake(it)
      local pos = R.GetMediaItemInfo_Value(it, 'D_POSITION')
      if take and pos < rgnend - EPS then
        local qn0 = R.TimeMap2_timeToQN(0, pos)
        if R.TakeIsMIDI(take) then
          if nsteps then
            R.MIDI_SetItemExtents(it, qn0, qn0 + nsteps / lpb)
            R.SetMediaItemInfo_Value(it, 'D_POSITION', pos)
          end
        else
          local rate = R.GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE')
          if rate <= 0 then rate = 1 end
          local offs = R.GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS')
          if nsteps then
            local t_per = R.TimeMap2_QNToTime(0, qn0 + nsteps / lpb) - pos
            local ok, err = E.set_section(it, offs, t_per * rate)
            if ok then R.SetMediaItemTakeInfo_Value(take, 'D_STARTOFFS', 0) else warn = err end
          elseif offs > EPS then
            local src = R.GetMediaItemTake_Source(take)
            local slen = src and R.GetMediaSourceLength(src) or 0
            if slen > offs + EPS and E.set_section(it, offs, slen - offs) then
              R.SetMediaItemTakeInfo_Value(take, 'D_STARTOFFS', 0)
            end
          end
        end
        R.SetMediaItemInfo_Value(it, 'B_LOOPSRC', 1)
        R.SetMediaItemInfo_Value(it, 'D_LENGTH', rgnend - pos)
        n = n + 1
      end
    end
  end)
  return n, warn
end

function E.loop_to_region(heads, lpb, rg, nsteps)
  local items, seen = {}, {}
  for _, h in ipairs(heads) do
    if h.item and not seen[h.item] then seen[h.item] = true; items[#items + 1] = h.item end
  end
  if #items == 0 then return 0 end
  return E.loop_items(items, lpb, rg.rgnend, nsteps)
end

-- ── громкость / панорама трека из шапки (2 окт) ──────────────────────────
-- Во время протяжки — без undo (каждый кадр), точка undo — на отпускании.
function E.track_value(tr, key, v) R.SetMediaTrackInfo_Value(tr, key, v) end
-- свойства сэмпла из панели (undo на каждое изменение)
-- свойство инструмента (3 окт): правка в панели item идёт во ВСЕ его копии.
-- rep — представитель (по нему считается новое значение v); остальные:
-- how = 'abs' — то же значение (фейды, луп, режим растяжки), 'add' — та же
-- разница (питч, панорама: у нот свои), 'mul' — то же отношение (громкость:
-- у нот своя). key 'take:X' — свойство take, иначе item. D_PLAYRATE —
-- отношением, длина каждой копии пересчитывается (выше rate — короче).
function E.inst_prop(items, rep, key, v, how, desc)
  local tkey = key:match('^take:(.+)')
  local function get(it)
    if tkey then local tk = R.GetActiveTake(it); return tk and R.GetMediaItemTakeInfo_Value(tk, tkey) end
    return R.GetMediaItemInfo_Value(it, key)
  end
  local old = get(rep)
  if not old then return end
  run(desc or ('instrument ' .. key), function()
    for _, it in ipairs(items) do
      if R.ValidatePtr(it, 'MediaItem*') then
        local cur = get(it)
        if cur then
          local nv = v
          if it ~= rep then
            if how == 'add' then nv = cur + (v - old)
            elseif how == 'mul' then nv = old ~= 0 and cur * v / old or v end
          end
          if tkey then
            local tk = R.GetActiveTake(it)
            R.SetMediaItemTakeInfo_Value(tk, tkey, nv)
            if tkey == 'D_PLAYRATE' and nv > 0 and cur > 0 then
              R.SetMediaItemInfo_Value(it, 'D_LENGTH', R.GetMediaItemInfo_Value(it, 'D_LENGTH') * cur / nv)
            end
          else R.SetMediaItemInfo_Value(it, key, nv) end
          R.UpdateItemInProject(it)
        end
      end
    end
  end)
end
function E.track_undo(desc) R.Undo_OnStateChange2(0, 'jf_tracker: ' .. desc) end

-- ── smart quantize (2 окт; принципы jf_transient_stretch_quantize и
-- jf_QuantumCut) ──────────────────────────────────────────────────────────
-- hits = { {t = время от начала item, amp = громкость атаки} } по времени.
-- Каждый удар → ближайшая шестнадцатая (5 окт; далёкие от сетки и резкие
-- растяжения пропускаются). Два хита в одну точку — остаётся громкий. Stretch-маркер
-- ставится на исходное место (srcpos считает REAPER), потом двигается только
-- позиция воспроизведения — так растягивается звук. Длина — до целых тактов
-- (сэмпл ≥ ¾ такта) или долей; концевой маркер едет вместе с концом.
-- Возвращает число поставленных маркеров хитов, число оставленных хитов, новую длину.
-- план квантайза (5 окт): что пойманно и куда поедет — для превью на волне
-- и для применения. prm = { step = QN шага сетки (0.25 = 1/16), window = доля
-- шага, дальше которой удар не трогаем, maxr = предел растяжения куска
-- (1.25 → 0.8..1.25), strength = 0..1 — насколько тянуть к сетке }.
-- Возвращает { kept = { {t, tq, n, amp} }, skipped = { {t, why} }, newlen, qn0 }
function E.quant_plan(item, hits, prm)
  prm = prm or {}
  local step, window, maxr, strength = prm.step or 0.25, prm.window or (1 / 3), prm.maxr or 1.25, prm.strength or 1
  local pos = R.GetMediaItemInfo_Value(item, 'D_POSITION')
  local len = R.GetMediaItemInfo_Value(item, 'D_LENGTH')
  local qn0 = R.TimeMap2_timeToQN(0, pos)
  local kept, skipped = {}, {}
  for _, h in ipairs(hits) do
    if h.t > 0.005 and h.t < len - 0.005 then
      local q = R.TimeMap2_timeToQN(0, pos + h.t)
      local tq = math.floor(q / step + 0.5) * step
      if E.item_swing(item) then tq = E.swing_qn(tq) end          -- свинг сетки проекта (6 окт)
      if tq <= qn0 + 1e-6 then skipped[#skipped + 1] = { t = h.t, why = 'start' }; tq = nil
      elseif math.abs(tq - q) > step * window then skipped[#skipped + 1] = { t = h.t, why = 'far' }; tq = nil end
      if tq then
        tq = q + (tq - q) * strength
        local prev = kept[#kept]
        local p_t, p_q = prev and prev.t or 0, prev and prev.tq or qn0
        local src_d = h.t - p_t
        local dst_d = R.TimeMap2_QNToTime(0, tq) - R.TimeMap2_QNToTime(0, p_q)
        local ratio = src_d > 0 and dst_d / src_d or 0
        if prev and tq <= prev.tq + 1e-6 then
          if h.amp > prev.amp then skipped[#skipped + 1] = { t = prev.t, why = 'twin' }; kept[#kept] = { t = h.t, tq = tq, amp = h.amp }
          else skipped[#skipped + 1] = { t = h.t, why = 'twin' } end
        elseif ratio >= 1 / maxr and ratio <= maxr then kept[#kept + 1] = { t = h.t, tq = tq, amp = h.amp }
        else skipped[#skipped + 1] = { t = h.t, why = 'stretch' } end
      end
    end
  end
  for _, k in ipairs(kept) do k.n = R.TimeMap2_QNToTime(0, k.tq) - pos end
  -- длина: до целых тактов (если ≥ ¾ такта), иначе до целых долей
  local qe = R.TimeMap2_timeToQN(0, pos + len)
  local _, qms, qme = R.TimeMap_QNToMeasures(0, qn0 + 1e-9)
  local bar = (qms and qme) and (qme - qms) or 4
  local beats = qe - qn0
  local nb = beats >= 0.75 * bar and math.max(bar, math.floor(beats / bar + 0.5) * bar) or math.max(1, math.floor(beats + 0.5))
  local last_tq = kept[#kept] and kept[#kept].tq or qn0
  if qn0 + nb <= last_tq + 1e-6 then nb = math.ceil((last_tq - qn0) + 0.25) end
  return { kept = kept, skipped = skipped, newlen = R.TimeMap2_QNToTime(0, qn0 + nb) - pos, qn0 = qn0, len = len }
end

function E.smart_quantize(item, hits, prm)
  local take = R.GetActiveTake(item)
  if not take or R.TakeIsMIDI(take) then return nil end
  local len = R.GetMediaItemInfo_Value(item, 'D_LENGTH')
  local plan = E.quant_plan(item, hits, prm)
  local kept, newlen = plan.kept, plan.newlen
  local placed = 0
  run('smart quantize', function()
    local nm = R.GetTakeNumStretchMarkers(take)
    if nm > 0 then R.DeleteTakeStretchMarkers(take, 0, nm) end
    R.SetMediaItemTakeInfo_Value(take, 'B_PPITCH', 1)          -- растяжение без смены высоты
    R.SetMediaItemInfo_Value(item, 'D_LENGTH', math.max(len, newlen))
    -- маркеры на исходных местах: начало, хиты, конец (srcpos — сам REAPER)
    local want = { { o = 0, n = 0 } }
    R.SetTakeStretchMarker(take, -1, 0)
    for _, k in ipairs(kept) do
      R.SetTakeStretchMarker(take, -1, k.t)
      want[#want + 1] = { o = k.t, n = k.n }
    end
    R.SetTakeStretchMarker(take, -1, len)
    want[#want + 1] = { o = len, n = newlen }
    -- двигаем только позицию воспроизведения; несколько проходов, потому что
    -- REAPER ограничивает маркер соседями
    for _ = 1, 4 do
      for i = 0, R.GetTakeNumStretchMarkers(take) - 1 do
        local _, p = R.GetTakeStretchMarker(take, i)
        local w = want[i + 1]
        if w and math.abs(p - w.n) > 1e-6 then R.SetTakeStretchMarker(take, i, w.n) end
      end
    end
    R.SetMediaItemInfo_Value(item, 'D_LENGTH', newlen)
    R.UpdateItemInProject(item)
    placed = #kept
  end)
  return placed, #kept, newlen
end

-- ── переименование (2 окт) ───────────────────────────────────────────────
function E.track_name(tr, name) run('rename track', function() R.GetSetMediaTrackInfo_String(tr, 'P_NAME', name, true) end) end
function E.take_names(items, name)
  local n = 0
  run('rename instrument', function()
    for _, it in ipairs(items) do
      local tk = R.ValidatePtr(it, 'MediaItem*') and R.GetActiveTake(it)
      if tk then R.GetSetMediaItemTakeInfo_String(tk, 'P_NAME', name, true); n = n + 1 end
    end
  end)
  return n
end

-- ── замена сэмпла инструмента файлом из браузера (Cmd+Enter, 2 окт) ──────
-- Все items инструмента получают новый источник; позиция и длина нот те же,
-- offset в начало файла, имя take = имя файла, старая нарезка снимается.
function E.replace_source(items, path)
  local n = 0
  local name = path:match('([^/]+)%.[^.]+$') or path:match('[^/]+$') or path
  path = E.media_copy(path)
  E.no_rescue = true                      -- прежний сэмпл уходит намеренно
  run('replace sample: ' .. name, function()
    for _, it in ipairs(items) do
      local take = R.ValidatePtr(it, 'MediaItem*') and R.GetActiveTake(it)
      if take and not R.TakeIsMIDI(take) then
        local src = R.PCM_Source_CreateFromFile(path)
        if src then
          local old = R.GetMediaItemTake_Source(take)
          R.SetMediaItemTake_Source(take, src)
          if old then pcall(R.PCM_Source_Destroy, old) end
          R.SetMediaItemTakeInfo_Value(take, 'D_STARTOFFS', 0)
          R.GetSetMediaItemTakeInfo_String(take, 'P_NAME', name, true)
          R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_slices', '', true)
          R.UpdateItemInProject(it)
          n = n + 1
        end
      end
    end
  end)
  return n
end

-- ── Garden: посадка событий Orca (F2, 2 окт) ─────────────────────────────
-- Посаженное помечено P_EXT:jf_garden = тег (регион); пишется БЕЗ undo-блоков
-- (решение пользователя: сотни точек в минуту похоронили бы историю).
-- MIDI никогда не пишется в пользовательский item: свой тегированный item на
-- регион (span t0..t1). Возвращает созданный item.
E.GARDEN_EXT = 'P_EXT:jf_garden'
local function garden_tag(it)
  local _, v = R.GetSetMediaItemInfo_String(it, E.GARDEN_EXT, '', false)
  return v ~= '' and v or nil
end
E.garden_tag = garden_tag

function E.plant(o)
  -- o = { track, lane_idx, lpb, row, pitch, vel, len, item (инструмент или nil), slice (k или nil), tag, span = {t0, t1} }
  local t0 = row_time(o.row, o.lpb, 0)
  local t1 = row_time(o.row + math.max(1, o.len or 1), o.lpb, 0)
  if o.item then
    local ok, chunk = R.GetItemStateChunk(o.item, '', false)
    if not ok then return nil end
    local it = insert_chunk(o.track, o.lane_idx, t0, strip_guids(chunk))
    R.SetMediaItemInfo_Value(it, 'B_MUTE', 0)
    local tk = R.GetActiveTake(it)
    if tk then
      if o.slice then
        local slices, base = E.item_slices(o.item)
        local k = math.max(1, math.min(#slices, o.slice))
        if #slices > 0 then
          local rate = R.GetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE')
          local a = slices[k]
          local b = (not E.playthru(it) and slices[k + 1]) or base.len or R.GetMediaItemInfo_Value(o.item, 'D_LENGTH')   -- playthru (6 окт)
          R.SetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS', (base.offs or 0) + a * rate)
          R.SetMediaItemInfo_Value(it, 'D_LENGTH', b - a)
        end
        R.SetMediaItemTakeInfo_Value(tk, 'D_PITCH', 0)
      else
        R.SetMediaItemTakeInfo_Value(tk, 'D_PITCH', (o.pitch or model.BASE_NOTE) - model.BASE_NOTE)
      end
      if o.vel then R.SetMediaItemInfo_Value(it, 'D_VOL', math.max(0.01, o.vel / 100)) end
    end
    R.GetSetMediaItemInfo_String(it, E.GARDEN_EXT, tostring(o.tag), true)
    local was = E.beside; E.beside = true
    finish_insert(o.track, o.lane_idx, it)
    E.beside = was
    return it
  end
  -- MIDI: тегированный item этого тега, накрывающий t0, иначе новый на span
  local mit, mtk
  for i = 0, R.CountTrackMediaItems(o.track) - 1 do
    local it = R.GetTrackMediaItem(o.track, i)
    local tk = R.GetActiveTake(it)
    if tk and R.TakeIsMIDI(tk) and garden_tag(it) == tostring(o.tag) then
      local p = R.GetMediaItemInfo_Value(it, 'D_POSITION')
      if t0 >= p - 1e-6 and t0 < p + R.GetMediaItemInfo_Value(it, 'D_LENGTH') - 1e-6 then mit, mtk = it, tk; break end
    end
  end
  if not mit then
    local a, b = (o.span and o.span[1]) or t0, (o.span and o.span[2]) or t1
    if b <= t0 then b = t1 end
    mit = R.CreateNewMIDIItemInProj(o.track, a, b, false)
    if not mit then return nil end
    if o.lane_idx then R.SetMediaItemInfo_Value(mit, 'I_FIXEDLANE', o.lane_idx) end
    R.GetSetMediaItemInfo_String(mit, E.GARDEN_EXT, tostring(o.tag), true)
    mtk = R.GetActiveTake(mit)
  end
  local p0 = R.MIDI_GetPPQPosFromProjTime(mtk, t0)
  local p1 = R.MIDI_GetPPQPosFromProjTime(mtk, t1)
  R.MIDI_InsertNote(mtk, false, false, p0, p1, 0, o.pitch or 60, math.max(1, math.min(127, o.vel or 100)), false)
  return mit
end

-- снести посаженное: тег (nil = все теги); keep0..keep1 — сохранить items,
-- начинающиеся в этом окне (посаженные на текущую строку). Без undo.
function E.garden_clear(tag, keep0, keep1)
  local n = 0
  for ti = 0, R.CountTracks(0) - 1 do
    local tr = R.GetTrack(0, ti)
    for i = R.CountTrackMediaItems(tr) - 1, 0, -1 do
      local it = R.GetTrackMediaItem(tr, i)
      local g = garden_tag(it)
      if g and (tag == nil or g == tostring(tag)) then
        local p = R.GetMediaItemInfo_Value(it, 'D_POSITION')
        if not (keep0 and p >= keep0 and p < keep1) then R.DeleteTrackMediaItem(tr, it); n = n + 1 end
      end
    end
  end
  if n > 0 then R.UpdateArrange() end
  return n
end

-- закрепить: снять тег (items становятся обычными — «урожай»). Undo-правка.
function E.garden_pin(tag)
  local n = 0
  run('garden pin', function()
    for ti = 0, R.CountTracks(0) - 1 do
      local tr = R.GetTrack(0, ti)
      for i = 0, R.CountTrackMediaItems(tr) - 1 do
        local it = R.GetTrackMediaItem(tr, i)
        local g = garden_tag(it)
        if g and (tag == nil or g == tostring(tag)) then R.GetSetMediaItemInfo_String(it, E.GARDEN_EXT, '', true); n = n + 1 end
      end
    end
  end)
  return n
end

return E
