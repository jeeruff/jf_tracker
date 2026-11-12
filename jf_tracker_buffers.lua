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
-- значения для нового буфера (иначе — текущие значения tbl при B.new); extra — ещё таблицы состояния того же
-- модуля: { { tbl = DK, fields = { 'anchor' } } } (ключ в st — 'k:поле', k — номер таблицы)
function B.register(mod, tbl, fields, defaults, extra)
  local m = { tbl = tbl, fields = fields or {}, defaults = defaults, tabs = { { tbl = tbl, fields = fields or {}, pre = '' } } }
  for k, x in ipairs(extra or {}) do m.tabs[#m.tabs + 1] = { tbl = x.tbl, fields = x.fields or {}, pre = k .. ':' } end
  B.mods[mod] = m
  B.bufs[mod] = B.bufs[mod] or { id = mod, mod = mod, n = 1, st = tbl }   -- буфер 1 — алиас таблицы модуля
  return B.bufs[mod]
end
function B.can_multi(mod) local m = B.mods[mod]; return m ~= nil and #m.fields > 0 end
local function fresh_st(m)
  local st = {}
  for _, t in ipairs(m.tabs) do
    for _, f in ipairs(t.fields) do
      local v
      if t.pre == '' and m.defaults then v = m.defaults[f] end
      if v == nil then v = t.tbl[f] end
      st[t.pre .. f] = v
    end
  end
  return st
end

-- новый буфер модуля → id ('dsp#2'); nil — модуль не зарегистрирован или без полей состояния
function B.new(mod)
  if not B.can_multi(mod) then return nil end
  local m, n = B.mods[mod], 2
  while B.bufs[B.id(mod, n)] do n = n + 1 end
  local id = B.id(mod, n)
  B.bufs[id] = { id = id, mod = mod, n = n, st = fresh_st(m) }
  return id
end
function B.get(id) return B.bufs[id] end
-- буфер по id из сохранённой раскладки ('inputs#2'): есть — он, модуль умеет — создать с этим номером, иначе nil
function B.ensure(id)
  if B.bufs[id] then return B.bufs[id] end
  local mod, n = B.base(id)
  if n < 2 or not B.can_multi(mod) then return nil end
  B.bufs[id] = { id = id, mod = mod, n = n, st = fresh_st(B.mods[mod]) }
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
  local b = B.bufs[id] or B.ensure(id)   -- раскладка из ExtState / скринсета: буфер создаётся при первом входе
  if not b or b.n == 1 or cur then return false end
  local m = B.mods[b.mod]
  local saved = {}
  for _, t in ipairs(m.tabs) do for _, f in ipairs(t.fields) do saved[t.pre .. f] = t.tbl[f]; t.tbl[f] = b.st[t.pre .. f] end end
  cur = { b = b, saved = saved }
  return true
end
function B.leave()
  if not cur then return false end
  local m = B.mods[cur.b.mod]
  for _, t in ipairs(m.tabs) do for _, f in ipairs(t.fields) do cur.b.st[t.pre .. f] = t.tbl[f]; t.tbl[f] = cur.saved[t.pre .. f] end end
  cur = nil
  return true
end
function B.current() return cur and cur.b.id or nil end
-- сменить активный буфер (leave + enter); 'mod' или буфер 1 — просто выйти
function B.switch(id)
  B.leave()
  local b = B.bufs[id]
  if b and b.n > 1 then return B.enter(id) end
  return false
end
function B.with(id, fn, ...)
  local on = B.enter(id)
  local ok, r = pcall(fn, ...)
  if on then B.leave() end
  if not ok then error(r, 0) end
  return r
end

return B
