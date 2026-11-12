-- jf_tracker_buffers.lua (12 ноя) — панель показывает буфер: модуль + его состояние (курсор, прокрутка, выбор).
--
-- Шаг 1 плана PLAN_BUFFERS.md: обёртка без изменения поведения. Буфер №1 каждого модуля — сама таблица модуля
-- (IN, RF, HU …): модули не переписаны, их поля живут где жили. Буфер №2 и дальше ('dsp#2') держит копию полей
-- состояния; перед отрисовкой / клавишами этого буфера поля подменяются в таблице модуля (B.enter), после —
-- возвращаются (B.leave). Так второй экземпляр получает любой модуль без правки его кода; модуль, которому
-- состояния не хватает (поля не названы при регистрации), второго буфера не получает.
-- id панели: 'dsp' — буфер 1, 'dsp#2' — второй; B.base снимает номер (guard-списки роутера сравнивают модуль).
-- Без reaper.*: тест tests/test_buffers.lua.
local B = { mods = {}, bufs = {} }

-- 'dsp#2' → 'dsp', 2;  'dsp' → 'dsp', 1
function B.base(id)
  if type(id) ~= 'string' then return id, 1 end
  local b, n = id:match('^(.-)#(%d+)$')
  if b then return b, tonumber(n) end
  return id, 1
end
function B.id(mod, n) return (n or 1) <= 1 and mod or (mod .. '#' .. n) end

-- модуль mod с таблицей tbl; fields — имена полей состояния (их копирует второй буфер); defaults — их начальные
-- значения для нового буфера (иначе — текущие значения tbl при B.new)
function B.register(mod, tbl, fields, defaults)
  B.mods[mod] = { tbl = tbl, fields = fields or {}, defaults = defaults }
  B.bufs[mod] = B.bufs[mod] or { id = mod, mod = mod, n = 1, st = tbl }   -- буфер 1 — алиас таблицы модуля
  return B.bufs[mod]
end
function B.can_multi(mod) local m = B.mods[mod]; return m ~= nil and #m.fields > 0 end

-- новый буфер модуля → id ('dsp#2'); nil — модуль не зарегистрирован или без полей состояния
function B.new(mod)
  if not B.can_multi(mod) then return nil end
  local m, n = B.mods[mod], 2
  while B.bufs[B.id(mod, n)] do n = n + 1 end
  local st = {}
  for _, f in ipairs(m.fields) do st[f] = m.defaults and m.defaults[f]; if st[f] == nil then st[f] = m.tbl[f] end end
  local id = B.id(mod, n)
  B.bufs[id] = { id = id, mod = mod, n = n, st = st }
  return id
end
function B.get(id) return B.bufs[id] end
-- буфер по id из сохранённой раскладки ('inputs#2'): есть — он, модуль умеет — создать с этим номером, иначе nil
function B.ensure(id)
  if B.bufs[id] then return B.bufs[id] end
  local mod, n = B.base(id)
  if n < 2 or not B.can_multi(mod) then return nil end
  local m, st = B.mods[mod], {}
  for _, f in ipairs(m.fields) do st[f] = m.defaults and m.defaults[f]; if st[f] == nil then st[f] = m.tbl[f] end end
  B.bufs[id] = { id = id, mod = mod, n = n, st = st }
  return B.bufs[id]
end
function B.drop(id) local b = B.bufs[id]; if b and b.n > 1 then B.bufs[id] = nil; return true end; return false end
function B.list(mod)
  local out = {}
  for id, b in pairs(B.bufs) do if not mod or b.mod == mod then out[#out + 1] = id end end
  table.sort(out)
  return out
end

-- подменить поля модуля на состояние буфера (буфер 1 — ничего); leave возвращает их и запоминает изменения
local cur
function B.enter(id)
  local b = B.bufs[id]
  if not b or b.n == 1 or cur then return false end
  local m = B.mods[b.mod]
  local saved = {}
  for _, f in ipairs(m.fields) do saved[f] = m.tbl[f]; m.tbl[f] = b.st[f] end
  cur = { b = b, saved = saved }
  return true
end
function B.leave()
  if not cur then return false end
  local m = B.mods[cur.b.mod]
  for _, f in ipairs(m.fields) do cur.b.st[f] = m.tbl[f]; m.tbl[f] = cur.saved[f] end
  cur = nil
  return true
end
function B.with(id, fn, ...)
  local on = B.enter(id)
  local ok, r = pcall(fn, ...)
  if on then B.leave() end
  if not ok then error(r, 0) end
  return r
end

return B
