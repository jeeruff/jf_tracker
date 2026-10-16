-- jf_tracker_actions.lua — панель actions (16 окт): список действий REAPER шире родного окна Actions.
--
-- Секции (main, midi, event list, inline, explorer), слева группы — по префиксу имени
-- («Script:», «Item:», «Track:», «SWS:» …) плюс all / favourites / recent; справа таблица:
-- состояние тогла, имя, шорткаты REAPER. Фильтр — слова по порядку букв, лучшие совпадения
-- (подряд, с начала слова) выше. Избранное и недавние — ExtState (именованные id скриптов
-- переживают перезапуск: «_RS…» вместо числа).
--
-- Без reaper.*: группы, фильтр, разбор id; тест tests/test_actions.lua.

local A = {}

A.SECTIONS = {
  { id = 0,     key = 'main',     label = 'main' },
  { id = 32060, key = 'midi',     label = 'midi editor' },
  { id = 32061, key = 'list',     label = 'event list' },
  { id = 32062, key = 'inline',   label = 'inline midi' },
  { id = 32063, key = 'explorer', label = 'media explorer' },
}

-- группа действия — слово до первого «:» (короткое, без цифр); иначе «other»
function A.group_of(name)
  local g = (name or ''):match('^%s*([%w][%w%s%-/&]-)%s*:')
  if g and #g <= 24 and not g:match('%d') then return g:lower() end
  return 'other'
end

-- группы списка: { name, n }, крупные сверху, «other» — в конце
function A.groups(list)
  local cnt = {}
  for _, it in ipairs(list) do local g = A.group_of(it.label); cnt[g] = (cnt[g] or 0) + 1 end
  local out = {}
  for g, n in pairs(cnt) do if g ~= 'other' then out[#out + 1] = { name = g, n = n } end end
  table.sort(out, function(a, b) if a.n ~= b.n then return a.n > b.n end; return a.name < b.name end)
  if cnt.other then out[#out + 1] = { name = 'other', n = cnt.other } end
  return out
end

-- очки совпадения: nil — нет; меньше — лучше. Каждое слово запроса — буквы по порядку;
-- подряд идущие и с начала слова дешевле, разрывы дороже
function A.score(hay, q)
  hay = hay:lower()
  local total = 0
  for w in q:lower():gmatch('%S+') do
    local sub = hay:find(w, 1, true)
    if sub then
      local wb = sub == 1 or hay:sub(sub - 1, sub - 1):match('[%s:_%-/%(]')
      total = total + (wb and 0 or 1)
    else
      local pos, last, gaps = 1, nil, 0
      for ch in w:gmatch('.') do
        local f = hay:find(ch, pos, true)
        if not f then return nil end
        if last and f > last + 1 then gaps = gaps + 1 end
        last, pos = f, f + 1
      end
      total = total + 10 + gaps
    end
  end
  return total
end

-- фильтр: группа (all / favourites / recent / имя) и запрос; порядок — по очкам, затем как было
function A.filter(list, query, group, fav, recent)
  local out = {}
  local rpos = {}
  for i, k in ipairs(recent or {}) do rpos[k] = i end
  for i, it in ipairs(list) do
    local ok = true
    if group == 'favourites' then ok = fav and fav[it.key] or false
    elseif group == 'recent' then ok = rpos[it.key] ~= nil
    elseif group and group ~= 'all' then ok = A.group_of(it.label) == group end
    if ok then
      local s = 0
      if query and query ~= '' then s = A.score(it.label, query) end
      if s then out[#out + 1] = { it = it, s = s, i = (group == 'recent' and rpos[it.key]) or i } end
    end
  end
  table.sort(out, function(a, b) if a.s ~= b.s then return a.s < b.s end; return a.i < b.i end)
  local r = {}
  for k, e in ipairs(out) do r[k] = e.it end
  return r
end

-- ключ действия для хранения: именованный id («_RS…», «_SWS…») или число строкой
function A.key_of(id, named)
  if named and named ~= '' then return '_' .. named:gsub('^_', '') end
  return tostring(math.floor(id or 0))
end

-- набор ключей ↔ строка ExtState через запятую
function A.set_decode(s) local t = {}; for k in (s or ''):gmatch('[^,]+') do t[k] = true end; return t end
function A.set_encode(t) local o = {}; for k in pairs(t or {}) do o[#o + 1] = k end; table.sort(o); return table.concat(o, ',') end
function A.list_decode(s) local t = {}; for k in (s or ''):gmatch('[^,]+') do t[#t + 1] = k end; return t end
-- недавнее: ключ в начало, без повторов, не длиннее n
function A.recent_push(rec, key, n)
  local out = { key }
  for _, k in ipairs(rec or {}) do if k ~= key and #out < (n or 30) then out[#out + 1] = k end end
  return out
end

return A
