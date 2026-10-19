-- jf_tracker_sections.lua — коды паттернов и секции (12 окт). Без reaper.* — тест tests/test_sections.lua.
--
-- Код паттерна — буква и вариант в начале имени региона: «A1», «AF», «D12 verse» (как банки Elektron: буква —
-- семейство вариантов, номер — вариант). Новый паттерн — следующая свободная буква с 1, клон — следующий
-- номер той же буквы, алиас — тот же код.
-- Секция — регион без кода, внутри которого лежит хотя бы один другой регион («verse» поверх A1 A2 A3).
-- Она не слот последовательности: её края держатся за первый и последний паттерн внутри
-- (снимок до правки → census, после → resync). Регион без кода и без вложенных — паттерн, как раньше
-- (старые проекты работают без перевода).

local S = {}
local EPS = 1e-6

-- 12 окт: вид кода новых вариантов: 'hex' (умолчание) — две буквы: A1 … A9, AA … AF (вариант — hex-цифра 1..F),
-- после F — десятичный A16; 'dec' — A1 … A9, A10, A11. Распознаются оба: один знак после буквы — hex-цифра,
-- несколько цифр — десятичное число (AB = A вариант 11, A12 = A вариант 12)
S.style = 'hex'

-- код в начале имени: 'A', номер варианта, остаток имени ('verse' или '')
function S.code_of(name)
  local l, v, rest = (name or ''):match('^(%u)([%dA-F]+)(.*)$')
  if not l then return nil end
  if rest ~= '' and not rest:match('^%s') then return nil end   -- «A1b», «B52s» — не код
  local n
  if #v == 1 then n = tonumber(v, 16)
  elseif v:match('^%d+$') then n = tonumber(v)
  else return nil end                                            -- «ADD», «FADE» — слово, не код
  return l, n, (rest:gsub('^%s+', ''))
end

-- код буквы l и варианта n в виде style ('hex' | 'dec')
function S.fmt(l, n, style)
  style = style or S.style
  if style == 'hex' and n >= 0 and n <= 15 then return l .. ('%X'):format(n) end
  return l .. tostring(n)
end

local function codes(regions)
  local used = {}
  for _, r in ipairs(regions or {}) do
    local l, n = S.code_of(r.name)
    if l then used[l] = used[l] or {}; used[l][n] = true end
  end
  return used
end

-- следующее семейство: первая буква A..Z без паттернов, вариант 1; все заняты — следующий вариант Z
function S.next_family(regions)
  local used = codes(regions)
  for b = 65, 90 do local l = string.char(b); if not used[l] then return S.fmt(l, 1) end end
  return S.next_variant(regions, 'Z1')
end

-- следующий вариант той же буквы: наибольший номер + 1 (остаток имени сохраняется)
function S.next_variant(regions, name)
  local l, _, rest = S.code_of(name)
  if not l then return nil end
  local m = 0
  for n in pairs(codes(regions)[l] or {}) do if n > m then m = n end end
  return S.fmt(l, m + 1) .. (rest ~= '' and (' ' .. rest) or '')
end

-- конвертер: новые имена паттернов. how = 'hex' | 'dec' — коды в этот вид (имя после кода остаётся);
-- 'codes' — паттерны без кода получают код: одинаковые имена (алиасы) — один код, старое имя — остатком.
-- → { [старое имя] = новое } (одинаковые имена — один раз)
function S.convert(pats, how)
  local map, taken = {}, {}
  for _, r in ipairs(pats) do if S.code_of(r.name) then taken[#taken + 1] = { name = r.name } end end
  for _, r in ipairs(pats) do
    local nm = r.name
    if nm ~= '' and not nm:match('^=') and map[nm] == nil and not r.lib and not r.session then
      local l, n, rest = S.code_of(nm)
      if how == 'codes' then
        if not l then
          local code = S.next_family(taken)
          taken[#taken + 1] = { name = code }
          map[nm] = code .. ' ' .. nm
        end
      elseif l then
        local nn = S.fmt(l, n, how) .. (rest ~= '' and (' ' .. rest) or '')
        if nn ~= nm then map[nm] = nn end
      end
    end
  end
  return map
end

local function inside(a, b) return a ~= b and a.pos >= b.pos - EPS and a.rgnend <= b.rgnend + EPS and a.rgnend - a.pos < b.rgnend - b.pos - EPS end

-- regions (по pos) → паттерны, секции. Служебные (lib / session / =имена) остаются паттернами как есть.
function S.split(regions)
  local pats, secs = {}, {}
  for _, r in ipairs(regions) do
    local sec = false
    if not r.session and not r.lib and r.name ~= '' and not S.code_of(r.name) and not r.name:match('^=') then
      for _, o in ipairs(regions) do
        if not o.session and inside(o, r) then sec = true; break end
        -- 19 окт: секция ровно в один паттерн (breakdown = C2 по границам) — тоже секция, если внутри паттерн с кодом
        if not o.session and o ~= r and S.code_of(o.name) and o.pos >= r.pos - EPS and o.rgnend <= r.rgnend + EPS then sec = true; break end
      end
    end
    if sec then r.section = true; secs[#secs + 1] = r else pats[#pats + 1] = r end
  end
  return pats, secs
end

-- снимок до правки: у каждой секции — какие паттерны в ней (по idx)
function S.census(pats, secs)
  local out = {}
  for _, s in ipairs(secs or {}) do
    local m = {}
    for _, p in ipairs(pats) do if inside(p, s) then m[#m + 1] = p.idx end end
    if #m > 0 then out[#out + 1] = { idx = s.idx, members = m } end
  end
  return out
end

-- после правки: новые края секций = от начала первого до конца последнего из её паттернов, что остались.
-- → список { idx, pos, rgnend } тех секций, чьи края надо поправить
function S.resync(census, pats, secs)
  local by, sby = {}, {}
  for _, p in ipairs(pats) do by[p.idx] = p end
  for _, s in ipairs(secs or {}) do sby[s.idx] = s end
  local fix = {}
  for _, c in ipairs(census or {}) do
    local a, b
    for _, idx in ipairs(c.members) do
      local p = by[idx]
      if p then a = math.min(a or p.pos, p.pos); b = math.max(b or p.rgnend, p.rgnend) end
    end
    -- секция могла стать «паттерном» (все вложенные ушли из неё) — ищем её и среди паттернов
    local s = sby[c.idx] or by[c.idx]
    if a and s and (math.abs(s.pos - a) > EPS or math.abs(s.rgnend - b) > EPS) then fix[#fix + 1] = { idx = c.idx, pos = a, rgnend = b } end
  end
  return fix
end

return S
