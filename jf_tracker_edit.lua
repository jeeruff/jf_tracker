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
    if not model or name ~= model.DEPOT then
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
        if in_seq and not (post[tr] and post[tr][fn] ~= nil) then
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
      if h.kind == 'audio' and h.take then
        audio_set_semis(h, pitch - model.BASE_NOTE)
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
  if cmd == '9' then R.SetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS', xx / 255 * src_len(h))
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
    if #slices > 0 then
      local k = math.max(1, math.min(#slices, xx))
      local rate = R.GetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE')
      local t0 = slices[k]
      local t1 = slices[k + 1] or (base.len or len)
      R.SetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS', (base.offs or 0) + t0 * rate)
      R.SetMediaItemInfo_Value(it, 'D_LENGTH', t1 - t0)
      R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_slice', tostring(k), true)
    else
      R.SetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS', xx / 256 * src_len(h))
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
      end
    else
      R.SetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE', 1)
    end
  end
end

-- таблица слайсов item: { t1, t2, … } (секунды от начала item) и база
-- { offs = D_STARTOFFS при нарезке, len = длина item при нарезке }
function E.item_slices(it)
  local ok, str = R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_slices', '', false)
  local out = {}
  if ok and str and str ~= '' then
    for v in str:gmatch('[^,]+') do out[#out + 1] = tonumber(v) end
  end
  local _, b = R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_slice_base', '', false)
  local base = {}
  if b and b ~= '' then base.offs, base.len = b:match('([^;]+);([^;]+)'); base.offs = tonumber(base.offs); base.len = tonumber(base.len) end
  return out, base
end

-- записать нарезку в item-инструмент (пустая таблица — снять)
function E.set_slices(it, slices)
  run('slices', function()
    local parts = {}
    for _, t in ipairs(slices) do parts[#parts + 1] = ('%.6f'):format(t) end
    R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_slices', table.concat(parts, ','), true)
    local tk = R.GetActiveTake(it)
    local offs = tk and R.GetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS') or 0
    R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_slice_base', #slices > 0 and ('%.6f;%.6f'):format(offs, R.GetMediaItemInfo_Value(it, 'D_LENGTH')) or '', true)
  end)
end

-- команды-огибающие/генераторы (jf_tracker_cmds): хранятся в P_EXT:jf_cmds,
-- пересобираются при каждой правке
E.cmds = nil
E.prev_semis = function(head) return nil end   -- переопределяет main (для Gxx)

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

-- значение команды cmd у головы (из head.fx модели), nil если нет
function E.fx_value(head, cmd)
  for _, f in ipairs(head.fx or {}) do
    if f:sub(1, 1) == cmd then return tonumber(f:sub(2), 16) end
  end
  return nil
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
  local t = row_time(row, lpb, 0)
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
E.xfade = { on = false, len = 0.010 }

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
    if old_ext > 0 then R.GetSetMediaItemInfo_String(prev, 'P_EXT:jf_xfade', '', true) end
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
local function finish_insert(track, lane_idx, it)
  if not it then return end
  if not E.beside and not E.xfade.on then cut_covering(track, lane_idx, R.GetMediaItemInfo_Value(it, 'D_POSITION'), it) end
  xfade_join(track, lane_idx, it)
end

-- вставить слайс k инструмента inst_item на трек: копия chunk, offs/len по таблице
function E.insert_slice(track, lane_idx, lpb, row, inst_item, k)
  local slices, base = E.item_slices(inst_item)
  if #slices == 0 then return end
  k = math.max(1, math.min(#slices, k))
  local t0 = row_time(row, lpb, 0)
  run('insert slice ' .. k, function()
    local ok, chunk = R.GetItemStateChunk(inst_item, '', false)
    if not ok then return end
    local it = insert_chunk(track, lane_idx, t0, strip_guids(chunk))
    R.SetMediaItemInfo_Value(it, 'B_MUTE', 0)
    local tk = R.GetActiveTake(it)
    if tk then
      local rate = R.GetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE')
      local a = slices[k]
      local b = slices[k + 1] or base.len or R.GetMediaItemInfo_Value(inst_item, 'D_LENGTH')
      R.SetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS', (base.offs or 0) + a * rate)
      R.SetMediaItemInfo_Value(it, 'D_LENGTH', b - a)
      R.SetMediaItemTakeInfo_Value(tk, 'D_PITCH', 0)
    end
    R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_slice', tostring(k), true)
    finish_insert(track, lane_idx, it)
  end)
end

-- Выделение сэмпл-модуля [t0, t1) (секунды item) → item на track в строке
-- row: инструмент пула — копия chunk с D_STARTOFFS/D_LENGTH, файл браузера —
-- новый item из источника. pos — явная позиция вместо строки (депо).
function E.insert_span(track, lane_idx, lpb, row, entry, t0, t1, pos)
  if not entry or t1 <= t0 then return end
  local t = pos or row_time(row, lpb, 0)
  local it
  run(('insert span %.2fs'):format(t1 - t0), function()
    if entry.item then
      local ok, chunk = R.GetItemStateChunk(entry.item, '', false)
      if not ok then return end
      it = insert_chunk(track, lane_idx, t, strip_guids(chunk))
      R.SetMediaItemInfo_Value(it, 'B_MUTE', 0)
      local tk = R.GetActiveTake(it)
      if tk then
        local rate = R.GetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE')
        R.SetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS', (entry.offs or 0) + t0 * rate)
        R.SetMediaItemInfo_Value(it, 'D_LENGTH', t1 - t0)
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

-- выделение → депо трека (после =LIB), чтобы потом нарезать как инструмент
function E.depot_span(track, entry, t0, t1)
  local pos = E.ensure_lib()
  for i = 0, R.CountTrackMediaItems(track) - 1 do
    local it = R.GetTrackMediaItem(track, i)
    local e = R.GetMediaItemInfo_Value(it, 'D_POSITION') + R.GetMediaItemInfo_Value(it, 'D_LENGTH')
    if e > pos then pos = e end
  end
  return E.insert_span(track, nil, 4, 0, entry, t0, t1, pos)
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
  local t0 = row_time(row, lpb, 0)
  local t1 = row_time(row + math.max(1, len_rows or 1), lpb, 0)
  run('insert note', function()
    local mit = midi_item_at(track, lane_idx, t0)
    local has_audio = false
    if not mit then
      for i = 0, R.CountTrackMediaItems(track) - 1 do
        local tk = R.GetActiveTake(R.GetTrackMediaItem(track, i))
        if tk and not R.TakeIsMIDI(tk) then has_audio = true; break end
      end
    end
    if mit or (not has_audio and not depot_item) then
      insert_midi(track, lane_idx, t0, t1, pitch, vel, 0, false)
    elseif depot_item then
      local ok, chunk = R.GetItemStateChunk(depot_item, '', false)
      if ok then
        local it = insert_chunk(track, lane_idx, t0, strip_guids(chunk))
        R.SetMediaItemInfo_Value(it, 'B_MUTE', 0)
        local tk = R.GetActiveTake(it)
        if tk then R.SetMediaItemTakeInfo_Value(tk, 'D_PITCH', pitch - model.BASE_NOTE) end
        finish_insert(track, lane_idx, it)
      end
    end
  end)
end

-- ── запись с MIDI-входа (INSERT + R на треке) ───────────────────────────
-- нота всегда MIDI (даже на треке с аудио): в MIDI-item строки или новый на такт
function E.rec_note(track, lane_idx, lpb, row, pitch, vel, len_rows)
  local t0 = row_time(row, lpb, 0)
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
function E.fx_add(track, name, pos)
  run('fx add', function() add_fx(track, name, pos and (-1000 - pos) or -1) end)
  if model then model.invalidate() end
end
function E.fx_remove(track, fx)
  run('fx remove', function() FA(track).Delete(track, fx) end)
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
        if fx >= 0 then R.TrackFX_SetParam(tr, fx, 0, slot) end
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
    if fx >= 0 then R.TrackFX_SetParam(track, fx, 1, slot) end
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

-- добавить файл в трек DEPOT (создаётся заглушённым в конце, если нет);
-- item ставится после последнего в депо, длина = источник. Возвращает item.
-- маркер =LIB: есть — его позиция; нет — ставим на такт после конца проекта
function E.ensure_lib()
  local pos = model.lib_pos()
  local endp = model.marker_pos(model.END_MARKER)
  if pos and not (endp and pos < endp - 1e-6) then return pos end
  if pos then
    -- =LIB раньше =END (2 окт) — не библиотека: перенести маркер за =END
    local qn = R.TimeMap2_timeToQN(0, endp)
    local _, qms, qme = R.TimeMap_QNToMeasures(0, qn)
    local nt = (qms and math.abs(qn - qms) < 1e-6) and endp or R.TimeMap2_QNToTime(0, qme or (qn + 4))
    local i = 0
    while true do
      local ret, isrgn, _, _, nm, _, color = R.EnumProjectMarkers3(0, i)
      if not ret or ret == 0 then break end
      if not isrgn and nm == model.LIB_MARKER then R.SetProjectMarkerByIndex(0, i, false, nt, 0, -1, nm, color or 0); return nt end
      i = i + 1
    end
  end
  local len = R.GetProjectLength(0)
  local qn = R.TimeMap2_timeToQN(0, len)
  local _, _, qme = R.TimeMap_QNToMeasures(0, qn)
  pos = R.TimeMap2_QNToTime(0, (qme or (qn + 4)) + 4)
  local endp = model.marker_pos(model.END_MARKER)
  if endp and pos < endp then pos = endp end                -- библиотека не раньше =END (2 окт)
  R.AddProjectMarker2(0, false, pos, 0, model.LIB_MARKER, -1, 0)
  return pos
end

-- файл → депо трека: item после маркера =LIB (конец зоны библиотеки трека);
-- трек не задан — наследие: трек DEPOT (создаётся)
function E.depot_add(path, track)
  local item
  path = E.media_copy(path)
  run('depot add', function()
    local tr = track
    local pos = 0
    if tr then
      pos = E.ensure_lib()
      for i = 0, R.CountTrackMediaItems(tr) - 1 do
        local it = R.GetTrackMediaItem(tr, i)
        local e = R.GetMediaItemInfo_Value(it, 'D_POSITION') + R.GetMediaItemInfo_Value(it, 'D_LENGTH')
        if e > pos then pos = e end
      end
    else
      for ti = 0, R.CountTracks(0) - 1 do
        local t = R.GetTrack(0, ti)
        local _, name = R.GetTrackName(t)
        if name == model.DEPOT then tr = t; break end
      end
      if not tr then
        R.InsertTrackAtIndex(R.CountTracks(0), false)
        tr = R.GetTrack(0, R.CountTracks(0) - 1)
        R.GetSetMediaTrackInfo_String(tr, 'P_NAME', model.DEPOT, true)
        R.SetMediaTrackInfo_Value(tr, 'B_MUTE', 1)
      end
      for i = 0, R.CountTrackMediaItems(tr) - 1 do
        local it = R.GetTrackMediaItem(tr, i)
        local e = R.GetMediaItemInfo_Value(it, 'D_POSITION') + R.GetMediaItemInfo_Value(it, 'D_LENGTH')
        if e > pos then pos = e end
      end
    end
    local src = R.PCM_Source_CreateFromFile(path)
    if not src then return end
    item = R.AddMediaItemToTrack(tr)
    local tk = R.AddTakeToMediaItem(item)
    R.SetMediaItemTake_Source(tk, src)
    local len = R.GetMediaSourceLength(src)
    R.SetMediaItemInfo_Value(item, 'D_POSITION', pos)
    R.SetMediaItemInfo_Value(item, 'D_LENGTH', len or 1)
    R.GetSetMediaItemTakeInfo_String(tk, 'P_NAME', path:match('([^/]+)%.%w+$') or path, true)
  end)
  return item
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

-- items депо (трек DEPOT) — «инструменты» для аудио-вставки
function E.depot_items()
  local out = {}
  for ti = 0, R.CountTracks(0) - 1 do
    local tr = R.GetTrack(0, ti)
    local _, name = R.GetTrackName(tr)
    if name == model.DEPOT then
      for i = 0, R.CountTrackMediaItems(tr) - 1 do
        local it = R.GetTrackMediaItem(tr, i)
        local tk = R.GetActiveTake(it)
        out[#out + 1] = { item = it, name = tk and R.GetTakeName(tk) or ('#' .. i) }
      end
      break
    end
  end
  return out
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
function E.item_set(it, key, v, desc) run(desc or ('item ' .. key), function() R.SetMediaItemInfo_Value(it, key, v); R.UpdateItemInProject(it) end) end
function E.take_set(take, key, v, desc) run(desc or ('take ' .. key), function() R.SetMediaItemTakeInfo_Value(take, key, v); R.UpdateItemInProject(R.GetMediaItemTake_Item(take)) end) end
function E.track_undo(desc) R.Undo_OnStateChange2(0, 'jf_tracker: ' .. desc) end

-- ── smart quantize (2 окт; принципы jf_transient_stretch_quantize и
-- jf_QuantumCut) ──────────────────────────────────────────────────────────
-- hits = { {t = время от начала item, amp = громкость атаки} } по времени.
-- Сильные (amp ≥ 0.6·max) → ближайшая доля (целый QN), слабые → ближайшая
-- шестнадцатая. Два хита в одну точку — остаётся громкий. Stretch-маркер
-- ставится на исходное место (srcpos считает REAPER), потом двигается только
-- позиция воспроизведения — так растягивается звук. Длина — до целых тактов
-- (сэмпл ≥ ¾ такта) или долей; концевой маркер едет вместе с концом.
-- Возвращает число поставленных маркеров хитов, число оставленных хитов, новую длину.
function E.smart_quantize(item, hits)
  local take = R.GetActiveTake(item)
  if not take or R.TakeIsMIDI(take) then return nil end
  local pos = R.GetMediaItemInfo_Value(item, 'D_POSITION')
  local len = R.GetMediaItemInfo_Value(item, 'D_LENGTH')
  local qn0 = R.TimeMap2_timeToQN(0, pos)
  local maxa = 0
  for _, h in ipairs(hits) do if h.amp > maxa then maxa = h.amp end end
  -- цели в QN, монотонно; коллизия — громкий остаётся
  local kept = {}
  for _, h in ipairs(hits) do
    if h.t > 0.005 and h.t < len - 0.005 then
      local q = R.TimeMap2_timeToQN(0, pos + h.t)
      local strong = maxa > 0 and h.amp >= 0.6 * maxa
      local step = strong and 1 or 0.25
      local tq = math.floor(q / step + 0.5) * step
      if tq <= qn0 + 1e-6 then tq = nil end                  -- на начало item не тянем
      if tq then
        local prev = kept[#kept]
        if prev and tq <= prev.tq + 1e-6 then
          if h.amp > prev.amp then kept[#kept] = { t = h.t, tq = tq, amp = h.amp } end
        else kept[#kept + 1] = { t = h.t, tq = tq, amp = h.amp } end
      end
    end
  end
  -- длина: до целых тактов (если ≥ ¾ такта), иначе до целых долей
  local qe = R.TimeMap2_timeToQN(0, pos + len)
  local _, qms, qme = R.TimeMap_QNToMeasures(0, qn0 + 1e-9)
  local bar = (qms and qme) and (qme - qms) or 4
  local beats = qe - qn0
  local nb = beats >= 0.75 * bar and math.max(bar, math.floor(beats / bar + 0.5) * bar) or math.max(1, math.floor(beats + 0.5))
  local last_tq = kept[#kept] and kept[#kept].tq or qn0
  if qn0 + nb <= last_tq + 1e-6 then nb = math.ceil((last_tq - qn0) + 0.25) end
  local newlen = R.TimeMap2_QNToTime(0, qn0 + nb) - pos
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
      want[#want + 1] = { o = k.t, n = R.TimeMap2_QNToTime(0, k.tq) - pos }
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
          local b = slices[k + 1] or base.len or R.GetMediaItemInfo_Value(o.item, 'D_LENGTH')
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
