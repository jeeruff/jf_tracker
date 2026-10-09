-- jf_tracker_arr.lua — аранжировки (9 окт): фиксированные лейны трека — его
-- версии, аранжировка — именованный набор играющих лейнов всех треков
-- (C_LANEPLAYS). Хранится в проекте: ProjExtState jf_tracker/arr — строка
-- «имя=guid:0102;guid:10|имя=…», текущая — arr_cur (номер). Лейны и items
-- не трогаются — только какие лейны играют. Текущая аранжировка обновляется
-- с живого состояния перед каждым переключением / копией (правишь лейны —
-- правишь её). Чистые функции (без reaper.*) — тест tests/test_arr.lua.

local AR = {}

local function clean(s) return ((s or ''):gsub('[|;:=%c]', ' '):gsub('^%s+', ''):gsub('%s+$', '')) end
AR.clean = clean

function AR.decode(raw)
  local list = {}
  for chunk in (raw or ''):gmatch('[^|]+') do
    local name, body = chunk:match('^([^=]*)=(.*)$')
    if name then
      local lanes = {}
      for g, d in body:gmatch('([^;:]+):([0-2]+)') do
        local t = {}
        for ch in d:gmatch('%d') do t[#t + 1] = tonumber(ch) end
        lanes[g] = t
      end
      list[#list + 1] = { name = clean(name), lanes = lanes }
    end
  end
  return list
end

function AR.encode(list)
  local out = {}
  for _, a in ipairs(list) do
    local gs = {}
    for g in pairs(a.lanes) do gs[#gs + 1] = g end
    table.sort(gs)
    local parts = {}
    for _, g in ipairs(gs) do parts[#parts + 1] = g .. ':' .. table.concat(a.lanes[g]) end
    out[#out + 1] = clean(a.name) .. '=' .. table.concat(parts, ';')
  end
  return table.concat(out, '|')
end

-- имя копии: «verse» → «verse 2», «verse 2» → «verse 3»; занятые пропускаются
function AR.next_name(list, base)
  local taken = {}
  for _, a in ipairs(list) do taken[a.name] = true end
  base = clean(base)
  if base == '' then base = 'arr' end
  if not taken[base] then return base end
  local stem, n = base:match('^(.-)%s+(%d+)$')
  if not stem then stem, n = base, 1 end
  n = tonumber(n)
  repeat n = n + 1 until not taken[stem .. ' ' .. n]
  return stem .. ' ' .. n
end

function AR.copy(lanes)
  local t = {}
  for g, d in pairs(lanes or {}) do local c = {}; for i, v in ipairs(d) do c[i] = v end; t[g] = c end
  return t
end

-- живое состояние: R = reaper (или стаб в тесте)
function AR.capture(R, proj)
  local lanes = {}
  for i = 0, R.CountTracks(proj or 0) - 1 do
    local tr = R.GetTrack(proj or 0, i)
    if R.GetMediaTrackInfo_Value(tr, 'I_FREEMODE') == 2 then
      local n = math.floor(R.GetMediaTrackInfo_Value(tr, 'I_NUMFIXEDLANES'))
      if n > 1 then
        local d = {}
        for k = 0, n - 1 do d[#d + 1] = math.floor(R.GetMediaTrackInfo_Value(tr, 'C_LANEPLAYS:' .. k)) end
        lanes[R.GetTrackGUID(tr)] = d
      end
    end
  end
  return lanes
end

-- применить: сначала гасим, потом включаем (1 — «играет один» гасит соседей)
function AR.apply(R, lanes, proj)
  local n = 0
  for i = 0, R.CountTracks(proj or 0) - 1 do
    local tr = R.GetTrack(proj or 0, i)
    local d = lanes[R.GetTrackGUID(tr)]
    if d and R.GetMediaTrackInfo_Value(tr, 'I_FREEMODE') == 2 then
      local nl = math.floor(R.GetMediaTrackInfo_Value(tr, 'I_NUMFIXEDLANES'))
      for pass = 1, 2 do
        for k = 0, math.min(nl, #d) - 1 do
          local v = d[k + 1]
          if (pass == 1) == (v == 0) then R.SetMediaTrackInfo_Value(tr, 'C_LANEPLAYS:' .. k, v) end
        end
      end
      n = n + 1
    end
  end
  return n
end

return AR
