-- jf_tracker_playlist.lua — playlist матрицы (18 окт): порядок паттернов текстом, как region playlist.
--
-- Текст — слова через пробел (или , ; |):  intro A1 A1x2 B1:16 C1+8 D1/2 verse x4 4
--   имя паттерна (A1) или секции (verse — все её паттерны по порядку), число — регион REAPER с этим номером;
--   xN / *N — повторить N раз; :N — играть первые N строк (сокращение); /N — первую 1/N часть;
--   -N — пропустить первые N строк (проскок); +N — после паттерна доиграть ещё раз его первые N строк.
--   Можно вместе: A1-8:8x2, B1+8.
-- Плейлисты именованные, хранятся в проекте; играются (бесшовно на целых паттернах) или пишутся после песни.
-- Без reaper.* — тест tests/test_playlist.lua.

local PL = { lists = {}, cur = 1 }

local MOD = '[x%*:/%+%-]'

-- слово → ссылка и модификаторы; nil, ошибка — если модификаторы не разобрать
function PL.word(tok)
  local ref, mods = tok:match('^(.-)(' .. MOD .. '%d.*)$')
  if not ref or ref == '' then ref, mods = tok, '' end
  local m = {}
  local rest = mods:gsub('(' .. MOD .. ')(%d+)', function(op, n)
    n = tonumber(n)
    if op == 'x' or op == '*' then m.rep = n elseif op == ':' then m.len = n elseif op == '/' then m.div = n elseif op == '-' then m.skip = n else m.add = n end
    return ''
  end)
  if rest ~= '' then return nil, ('"%s": what is "%s"? (xN :N /N -N +N)'):format(tok, rest) end
  return ref, m
end

-- текст → шаги { rg, from, len, tok }, слова { s, e, text, err }, ошибки.
-- find(ref) → список паттернов { { rg =, rows = } … } (секция — несколько) или nil
function PL.parse(text, find)
  local steps, toks, errs = {}, {}, {}
  for s, tok, e in (text or ''):gmatch('()([^%s,;|]+)()') do
    local t = { s = s, e = e - 1, text = tok }
    toks[#toks + 1] = t
    local ref, m = PL.word(tok)
    local pats = ref and find(ref)
    if not ref then t.err = m
    elseif not pats or #pats == 0 then t.err = ('"%s": no such pattern / section / region number'):format(ref)
    elseif (m.rep or 1) < 1 or (m.div or 1) < 1 or (m.len and m.len < 1) then t.err = ('"%s": zero?'):format(tok) end
    if t.err then errs[#errs + 1] = t.err
    else
      for _ = 1, math.min(64, m.rep or 1) do
        for _, p in ipairs(pats) do
          local rows = math.max(1, p.rows)
          local from = math.min(rows - 1, m.skip or 0)
          local len = m.len or (m.div and math.max(1, math.floor(rows / m.div))) or (rows - from)
          len = math.max(1, math.min(len, rows - from))
          steps[#steps + 1] = { rg = p.rg, rows = rows, from = from, len = len, tok = #toks }
          -- +N: хвост — первые N строк того же паттерна ещё раз
          if m.add and m.add > 0 then steps[#steps + 1] = { rg = p.rg, rows = rows, from = 0, len = math.min(rows, m.add), tok = #toks } end
        end
      end
    end
  end
  return steps, toks, errs
end

-- шаг целиком (с начала до конца паттерна) — прыжок к нему и от него бесшовный (GoToRegion)
function PL.whole(st) return st.from == 0 and st.from + st.len == st.rows end

-- автодополнение последнего слова: имена, начинающиеся с основы (без регистра), по алфавиту
function PL.complete(stem, words)
  local out, seen, lo = {}, {}, (stem or ''):lower()
  for _, w in ipairs(words or {}) do
    if w ~= '' and not seen[w] and w:lower():sub(1, #lo) == lo then seen[w] = true; out[#out + 1] = w end
  end
  table.sort(out, function(a, b) return a:lower() < b:lower() end)
  return out
end

-- хранение в проекте: строки «имя<TAB>текст»
function PL.encode(lists)
  local o = {}
  for _, l in ipairs(lists or {}) do o[#o + 1] = (l.name or ''):gsub('[\t\n]', ' ') .. '\t' .. (l.text or ''):gsub('[\t\n]', ' ') end
  return table.concat(o, '\n')
end
function PL.decode(s)
  local o = {}
  for line in (s or ''):gmatch('[^\n]+') do
    local n, t = line:match('^(.-)\t(.*)$')
    if n then o[#o + 1] = { name = n, text = t } end
  end
  return o
end

-- свободное имя: playlist 1, playlist 2 …
function PL.free_name(lists, base)
  base = base or 'playlist'
  local used = {}
  for _, l in ipairs(lists or {}) do used[l.name] = true end
  local i = 1
  while used[base .. ' ' .. i] do i = i + 1 end
  return base .. ' ' .. i
end

-- шаги → итог для строки статуса: сколько шагов и строк
function PL.summary(steps)
  local rows = 0
  for _, st in ipairs(steps) do rows = rows + st.len end
  return #steps, rows
end

return PL
