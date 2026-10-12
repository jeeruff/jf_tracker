-- jf_tracker_sections.lua — коды паттернов и секции (12 окт). Без reaper.* — тест tests/test_sections.lua.
--
-- Код паттерна — буква и номер в начале имени региона: «A1», «D12 verse» (как банки Elektron: буква —
-- семейство вариантов, номер — вариант). Новый паттерн — следующая свободная буква с 1, клон — следующий
-- номер той же буквы, алиас — тот же код.
-- Секция — регион без кода, внутри которого лежит хотя бы один другой регион («verse» поверх A1 A2 A3).
-- Она не слот последовательности: её края держатся за первый и последний паттерн внутри
-- (снимок до правки → census, после → resync). Регион без кода и без вложенных — паттерн, как раньше
-- (старые проекты работают без перевода).

local S = {}
local EPS = 1e-6

-- код в начале имени: 'A', 12, остаток имени ('verse' или '')
function S.code_of(name)
  local l, n, rest = (name or ''):match('^(%u)(%d+)(.*)$')
  if not l then return nil end
  if rest ~= '' and not rest:match('^%s') then return nil end   -- «A1b», «B52s» — не код
  return l, tonumber(n), (rest:gsub('^%s+', ''))
end

local function codes(regions)
  local used = {}
  for _, r in ipairs(regions or {}) do
    local l, n = S.code_of(r.name)
    if l then used[l] = used[l] or {}; used[l][n] = true end
  end
  return used
end

-- следующее семейство: первая буква A..Z без паттернов, номер 1; все заняты — первая с самым малым номером свободна
function S.next_family(regions)
  local used = codes(regions)
  for b = 65, 90 do local l = string.char(b); if not used[l] then return l .. '1' end end
  return S.next_variant(regions, 'Z1')
end

-- следующий вариант той же буквы: наибольший номер + 1 (остаток имени сохраняется)
function S.next_variant(regions, name)
  local l, _, rest = S.code_of(name)
  if not l then return nil end
  local m = 0
  for n in pairs(codes(regions)[l] or {}) do if n > m then m = n end end
  return l .. (m + 1) .. (rest ~= '' and (' ' .. rest) or '')
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
