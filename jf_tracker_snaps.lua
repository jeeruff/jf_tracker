-- jf_tracker_snaps.lua — 22 окт: быстрые пресеты трека в DSP: 4 снапшота всех параметров FX трека
-- в углах XY-пэда (1 — левый верх, 2 — правый верх, 3 — левый низ, 4 — правый низ), шайба — морф.
-- Снапшот: { [ключ] = значение 0..1 }, ключ — «GUID эффекта|номер параметра». Хранение — одна строка
-- (P_EXT трека jf_snaps). Без reaper.* — тест tests/test_snaps.lua.

local SN = {}

-- веса углов по положению шайбы (x, y в 0..1, y вниз); have[i] — угол заполнен; пустые не участвуют
function SN.weights(x, y, have)
  x, y = math.max(0, math.min(1, x)), math.max(0, math.min(1, y))
  local w = { (1 - x) * (1 - y), x * (1 - y), (1 - x) * y, x * y }
  local sum = 0
  for i = 1, 4 do if not have[i] then w[i] = 0 end; sum = sum + w[i] end
  if sum <= 1e-9 then   -- шайба в пустом углу: ближайший заполненный
    local best, bd
    local cx, cy = { 0, 1, 0, 1 }, { 0, 0, 1, 1 }
    for i = 1, 4 do if have[i] then local d = (cx[i] - x) ^ 2 + (cy[i] - y) ^ 2; if not bd or d < bd then best, bd = i, d end end end
    w = { 0, 0, 0, 0 }; if best then w[best] = 1 end
    return w
  end
  for i = 1, 4 do w[i] = w[i] / sum end
  return w
end

-- смесь: snaps[i] (или nil), w — веса; ключ, которого нет в части углов, — по остальным
function SN.blend(snaps, w, keys)
  local out = {}
  for _, k in ipairs(keys) do
    local s, ws = 0, 0
    for i = 1, 4 do local v = snaps[i] and snaps[i][k]; if v and w[i] > 0 then s = s + v * w[i]; ws = ws + w[i] end end
    if ws > 0 then out[k] = s / ws end
  end
  return out
end

-- ключи, что различаются между заполненными углами (морф пишет только их)
function SN.diff_keys(snaps)
  local seen, out = {}, {}
  for i = 1, 4 do
    for k, v in pairs(snaps[i] or {}) do
      if not seen[k] then
        seen[k] = true
        local lo, hi = v, v
        for j = 1, 4 do local u = snaps[j] and snaps[j][k]; if u then lo, hi = math.min(lo, u), math.max(hi, u) end end
        if hi - lo > 1e-5 then out[#out + 1] = k end
      end
    end
  end
  table.sort(out)
  return out
end

-- строка: «i:ключ=значение;ключ=значение…» по углу на строку
function SN.ser(snaps)
  local lines = {}
  for i = 1, 4 do
    local s = snaps[i]
    if s then
      local parts = {}
      for k, v in pairs(s) do parts[#parts + 1] = ('%s=%.5f'):format(k, v) end
      table.sort(parts)
      lines[#lines + 1] = i .. ':' .. table.concat(parts, ';')
    end
  end
  return table.concat(lines, '\n')
end
function SN.parse(str)
  local snaps = {}
  for line in (str or ''):gmatch('[^\n]+') do
    local i, body = line:match('^(%d):(.*)$')
    i = tonumber(i)
    if i and i >= 1 and i <= 4 then
      local s = {}
      for k, v in body:gmatch('([^;=]+)=([^;]+)') do s[k] = tonumber(v) end
      snaps[i] = s
    end
  end
  return snaps
end

-- 30 окт: компактная строка (XY микшера: тысячи параметров всех треков). Значения, одинаковые во всех заполненных
-- углах, — один раз (строка «c:»), в углах — только отличия; GUID в ключах — короткие номера (строка «g:»).
-- В памяти углы остаются полными: морф и сравнение работают как раньше
local GUIDP = '{%x+%-%x+%-%x+%-%x+%-%x+}'
function SN.ser_compact(snaps)
  local filled = {}
  for i = 1, 4 do if snaps[i] then filled[#filled + 1] = i end end
  if #filled == 0 then return '' end
  local common = {}
  for k, v in pairs(snaps[filled[1]]) do
    local same = true
    for j = 2, #filled do local u = snaps[filled[j]][k]; if not u or math.abs(u - v) > 5e-6 then same = false; break end end
    if same then common[k] = v end
  end
  local gid, glist = {}, {}
  local function short(k)
    return (k:gsub(GUIDP, function(g)
      if not gid[g] then glist[#glist + 1] = g; gid[g] = '#' .. #glist end
      return gid[g]
    end))
  end
  local function body(t, skip)
    local parts = {}
    for k, v in pairs(t) do if not (skip and skip[k]) then parts[#parts + 1] = ('%s=%s'):format(short(k), (('%.5f'):format(v):gsub('0+$', ''):gsub('%.$', ''))) end end
    table.sort(parts)
    return table.concat(parts, ';')
  end
  local lines = { 'c:' .. body(common) }
  for _, i in ipairs(filled) do lines[#lines + 1] = i .. ':' .. body(snaps[i], common) end
  local g = {}
  for n, guid in ipairs(glist) do g[#g + 1] = '#' .. n .. '=' .. guid end
  table.insert(lines, 1, 'g:' .. table.concat(g, ';'))
  return table.concat(lines, '\n')
end
-- читает и компактную, и старую строку
function SN.parse_compact(str)
  if not (str or ''):find('^g:') then return SN.parse(str) end
  local gmap, common, snaps = {}, {}, {}
  local function long(k) return (k:gsub('#%d+', function(t) return gmap[t] or t end)) end
  for line in str:gmatch('[^\n]+') do
    local tag, b = line:match('^(%w):(.*)$')
    if tag == 'g' then for t, guid in b:gmatch('(#%d+)=([^;]+)') do gmap[t] = guid end
    elseif tag == 'c' then for k, v in b:gmatch('([^;=]+)=([^;]+)') do common[long(k)] = tonumber(v) end
    elseif tonumber(tag) and tonumber(tag) >= 1 and tonumber(tag) <= 4 then
      local t = {}
      for k, v in b:gmatch('([^;=]+)=([^;]+)') do t[long(k)] = tonumber(v) end
      snaps[tonumber(tag)] = t
    end
  end
  for i = 1, 4 do local t = snaps[i]; if t then for k, v in pairs(common) do if t[k] == nil then t[k] = v end end end end
  return snaps
end

return SN
