-- jf_tracker_notemod.lua — модуляция, которую запускает нота (12 окт, этап 1).
--
-- Инструмент (сэмпл в lib) несёт слоты: параметр трека + кривая из пула
-- automation items REAPER. Каждая нота инструмента получает на огибающей
-- параметра свой pooled automation item — от начала ноты, длиной в ноту;
-- кривая одна на все ноты (правится в пуле — меняются все). Опции слота:
-- rate — скорость кривой по высоте ноты (C-4 = x1, октава вверх = x2), loop —
-- кривая повторяется до конца ноты (иначе один проход и держит конец).
--
-- Хранение — P_EXT:jf_nmod у самих items: копии ноты делаются из чанка
-- инструмента и уносят слоты с собой. Связи нота → automation item нет:
-- companion — AI того же пула на огибающей слота, начинающийся там же, где нота.
--
-- Сверка (NM.sync) идёт внутри edit.run после каждой правки: ключ = огибающая +
-- пул + позиция; для затронутых ключей (ноты, которые правка создала, сдвинула,
-- удалила, переставила) нужное число AI сравнивается с имеющимся — лишние
-- удаляются, недостающие вставляются, длина / скорость / loop выставляются.
-- Поэтому вставка, копия, сдвиг, растяжка, удаление и undo не требуют своих
-- крючков. Только audio-ноты (MIDI-ноты внутри item — следующий этап).

local NM = {}
local R = reaper
local EXT = 'P_EXT:jf_nmod'
local FLAG = 'nmod'                    -- ProjExtState jf_tracker/nmod = 1: в проекте есть слоты (иначе сверка не идёт)
local DEL = 42086                      -- Envelope: Delete automation items
local E                                -- edit (inst_ref, inst_base, take semis)
local model

function NM.init(e, m) E, model = e, m end

-- ── формат: слот;слот, слот = env|pool|flags|label ────────────────────────
-- env: fx:<GUID FX>:<номер параметра> или env:<имя огибающей трека> (Volume, Pan …)
function NM.parse(s)
  local out = {}
  for part in (s or ''):gmatch('[^;]+') do
    local env, pool, flags, label = part:match('^([^|]+)|(%-?%d+)|([%a]*)|?(.*)$')
    if env then out[#out + 1] = { env = env, pool = tonumber(pool), rate = flags:find('r') ~= nil, loop = flags:find('l') ~= nil, label = label ~= '' and label or env } end
  end
  return out
end
function NM.encode(slots)
  local t = {}
  for _, s in ipairs(slots or {}) do
    t[#t + 1] = ('%s|%d|%s%s|%s'):format(s.env, s.pool or -1, s.rate and 'r' or '', s.loop and 'l' or '', (s.label or ''):gsub('[|;]', ' '))
  end
  return table.concat(t, ';')
end

function NM.get(it) local _, v = R.GetSetMediaItemInfo_String(it, EXT, '', false); return v or '' end
function NM.set(it, v) R.GetSetMediaItemInfo_String(it, EXT, v or '', true) end
function NM.slots(it) return NM.parse(NM.get(it)) end
function NM.on() if not R.GetProjExtState then return false end; local _, v = R.GetProjExtState(0, 'jf_tracker', FLAG); return v == '1' end
function NM.mark() R.SetProjExtState(0, 'jf_tracker', FLAG, '1') end

-- огибающая слота на треке (create — создать, если нет)
function NM.env(tr, key, create)
  local guid, param = key:match('^fx:([^:]+):(%d+)$')
  if guid then
    for fx = 0, R.TrackFX_GetCount(tr) - 1 do
      if R.TrackFX_GetFXGUID(tr, fx) == guid then return R.GetFXEnvelope(tr, fx, tonumber(param), create or false) end
    end
    return nil
  end
  local name = key:match('^env:(.+)$')
  return name and R.GetTrackEnvelopeByName(tr, name) or nil
end

-- полутоны ноты от C-4 инструмента (сам инструмент — 0). Новая нота этой же
-- правки в снимке ещё не числится — база берётся у родни по метке (base_of)
local function iid_base(v) return (v or ''):match('^([^#@~]*)') end
local function take_semis(it)
  local tk = R.GetActiveTake(it)
  if not tk or R.TakeIsMIDI(tk) then return nil end
  return model.take_semitones(R.GetMediaItemTakeInfo_Value(tk, 'D_PITCH'), R.GetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE'), R.GetMediaItemTakeInfo_Value(tk, 'B_PPITCH') == 1)
end
local function rel_semis(it, base_of)
  local s = take_semis(it)
  if not s then return 0 end
  local ref = E and E.inst_ref and E.inst_ref(it)
  if ref == it then return 0 end
  if ref then return s - (E.inst_base and E.inst_base(it) or 0) end
  local b = base_of and base_of[iid_base(E.get_iid(it))]
  return b and (s - b) or 0
end

local function pkey(p) return ('%.4f'):format(p) end

-- items со слотами: { [it] = { tr, pos, len, semis, raw } }
function NM.census()
  local out, list, base_of = {}, {}, {}
  for ti = 0, R.CountTracks(0) - 1 do
    local tr = R.GetTrack(0, ti)
    for i = 0, R.CountTrackMediaItems(tr) - 1 do
      local it = R.GetTrackMediaItem(tr, i)
      local raw = NM.get(it)
      if raw ~= '' then
        list[#list + 1] = { it, tr, raw }
        local ref = E and E.inst_ref and E.inst_ref(it)
        if ref and ref ~= it then base_of[iid_base(E.get_iid(it))] = E.inst_base and E.inst_base(it) or 0
        elseif ref == it then base_of[iid_base(E.get_iid(it))] = base_of[iid_base(E.get_iid(it))] or take_semis(it) end
      end
    end
  end
  for _, l in ipairs(list) do
    local it = l[1]
    out[it] = { tr = l[2], pos = R.GetMediaItemInfo_Value(it, 'D_POSITION'), len = R.GetMediaItemInfo_Value(it, 'D_LENGTH'), semis = rel_semis(it, base_of), raw = l[3] }
  end
  return out
end
local function sig(c) return tostring(c.tr) .. ' ' .. pkey(c.pos) .. ' ' .. pkey(c.len) .. ' ' .. ('%.3f'):format(c.semis) .. ' ' .. c.raw end

-- AI пула pool на env, начинающиеся в pos
local function ais_at(env, pool, pos)
  local out = {}
  for k = 0, R.CountAutomationItems(env) - 1 do
    if math.floor(R.GetSetAutomationItemInfo(env, k, 'D_POOL_ID', 0, false) + 0.5) == pool
       and math.abs(R.GetSetAutomationItemInfo(env, k, 'D_POSITION', 0, false) - pos) < 1e-4 then out[#out + 1] = k end
  end
  return out
end

-- сверка после правки: pre — NM.census() до неё. Возвращает число изменённых AI
function NM.sync(pre)
  local post = NM.census()
  -- затронутые ключи: огибающая (трек + слот) + пул + позиция
  local touched, keys = {}, {}
  local function touch(c, s, create)
    local env = NM.env(c.tr, s.env, create)
    if not env then return end
    local k = tostring(env) .. '|' .. s.pool .. '|' .. pkey(c.pos)
    if not touched[k] then touched[k] = { env = env, pool = s.pool, pos = c.pos, want = {} }; keys[#keys + 1] = k end
  end
  for it, c in pairs(pre) do
    local p = post[it]
    if not p or sig(p) ~= sig(c) then for _, s in ipairs(NM.parse(c.raw)) do touch(c, s, false) end end
  end
  for it, c in pairs(post) do
    local p = pre[it]
    if not p or sig(p) ~= sig(c) then for _, s in ipairs(NM.parse(c.raw)) do touch(c, s, true) end end
  end
  if #keys == 0 then return 0 end
  -- кто нужен на каждом затронутом ключе (все items, не только изменённые)
  -- заглушённые тоже: инструмент в lib заглушён, а его AI держит пул
  for _, c in pairs(post) do
    for _, s in ipairs(NM.parse(c.raw)) do
      local env = NM.env(c.tr, s.env, false)
      local t = env and touched[tostring(env) .. '|' .. s.pool .. '|' .. pkey(c.pos)]
      if t then t.want[#t.want + 1] = { c = c, s = s } end
    end
  end
  local n = 0
  -- лишние: выделить и удалить одним действием (API удаления AI нет)
  local dels = {}
  for _, k in ipairs(keys) do
    local t = touched[k]
    local have = ais_at(t.env, t.pool, t.pos)
    for i = #t.want + 1, #have do dels[#dels + 1] = { t.env, have[i] } end
  end
  if #dels > 0 then
    for ti = -1, R.CountTracks(0) - 1 do
      local tr = ti < 0 and R.GetMasterTrack(0) or R.GetTrack(0, ti)
      for e = 0, R.CountTrackEnvelopes(tr) - 1 do
        local env = R.GetTrackEnvelope(tr, e)
        for k = 0, R.CountAutomationItems(env) - 1 do R.GetSetAutomationItemInfo(env, k, 'D_UISEL', 0, true) end
      end
    end
    for _, d in ipairs(dels) do R.GetSetAutomationItemInfo(d[1], d[2], 'D_UISEL', 1, true) end
    R.Main_OnCommand(DEL, 0)
    n = n + #dels
  end
  -- недостающие — вставить; у всех — длина, скорость, loop как у ноты
  for _, k in ipairs(keys) do
    local t = touched[k]
    local have = ais_at(t.env, t.pool, t.pos)
    for i = #have + 1, #t.want do
      local idx = R.InsertAutomationItem(t.env, t.pool, t.pos, t.want[i].c.len)
      if idx and idx >= 0 then have[#have + 1] = idx; n = n + 1 end
    end
    for i, w in ipairs(t.want) do
      local idx = have[i]
      if idx then
        local rate = w.s.rate and 2 ^ (w.c.semis / 12) or 1
        R.GetSetAutomationItemInfo(t.env, idx, 'D_LENGTH', w.c.len, true)
        R.GetSetAutomationItemInfo(t.env, idx, 'D_PLAYRATE', rate, true)
        R.GetSetAutomationItemInfo(t.env, idx, 'D_LOOPSRC', w.s.loop and 1 or 0, true)
      end
    end
  end
  return n
end

-- ── слоты инструмента ─────────────────────────────────────────────────────
-- items инструмента: та же метка jf_iid без суффиксов (#k слайс, @ кусок, ~ уникальная)
function NM.family(it)
  local b = iid_base(E.get_iid(it))
  if b == '' then return { it } end
  local out = {}
  for ti = 0, R.CountTracks(0) - 1 do
    local tr = R.GetTrack(0, ti)
    for i = 0, R.CountTrackMediaItems(tr) - 1 do
      local o = R.GetTrackMediaItem(tr, i)
      if iid_base(E.get_iid(o)) == b then out[#out + 1] = o end
    end
  end
  return out
end
-- записать слоты всем items инструмента (внутри edit.run — сверка расставит AI)
function NM.write(it, slots)
  local raw = NM.encode(slots)
  E.ensure_iid(it)
  for _, o in ipairs(NM.family(it)) do NM.set(o, raw) end
  NM.mark()
end

-- новый пул на огибающей env: кривая-затравка (спад 1 → 0 за долю), AI у
-- самого инструмента на его позиции — он и есть «мать» пула. Возвращает pool id
function NM.new_pool(env, pos)
  local qn = R.TimeMap2_timeToQN(0, pos)
  local len = R.TimeMap2_QNToTime(0, qn + 1) - pos
  local idx = R.InsertAutomationItem(env, -1, pos, len)
  if not idx or idx < 0 then return nil end
  -- точки AI — в времени проекта, индекс AI без флага прохода (как в aiedit)
  R.DeleteEnvelopePointRangeEx(env, idx, pos - 1, pos + len + 1)
  local mode = R.GetEnvelopeScalingMode(env)
  R.InsertEnvelopePointEx(env, idx, pos, R.ScaleToEnvelopeMode(mode, 1), 0, 0, false, true)
  R.InsertEnvelopePointEx(env, idx, pos + len, R.ScaleToEnvelopeMode(mode, 0), 0, 0, false, true)
  R.Envelope_SortPointsEx(env, idx)
  return math.floor(R.GetSetAutomationItemInfo(env, idx, 'D_POOL_ID', 0, false) + 0.5), idx
end

return NM
