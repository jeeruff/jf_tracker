-- jf_tracker_xform.lua — модификаторы (15 окт): трансформации времени и громкости блока событий.
--
-- Вход: события { { row = дробная строка, v = 0..1 (громкость / velocity) } … } в отрезке [r0, r1)
-- (строки относительные или абсолютные — отрезок задаёт рамку). Выход — тот же список (копия) с
-- новыми row / v; main переносит ноты (E.retime). Без reaper.* — тест tests/test_xform.lua.
--
-- Операции (:xf …, макросы built-in):
--   stretch k   время ×k от начала отрезка (2 — вдвое медленнее, 0.5 — вдвое быстрее)
--   reverse     ретроград: порядок событий задом наперёд в отрезке
--   rotate n    циклический сдвиг на n строк внутри отрезка (отрицательный — назад)
--   shuffle     случайная перестановка позиций (seed — повторяемо)
--   gravity g   ускорение / замедление: доля отрезка возводится в степень g (g > 1 — сгущается к концу,
--               как падение; g < 1 — к началу); порядок и число событий те же
--   bounce r    отскоки мяча: интервалы между событиями убывают в r раз (r < 1), от первого к последнему
--   fib         позиции по Фибоначчи от первого события: 0 1 2 3 5 8 13 … строк (масштаб — под отрезок)
--   tuplet n    события равномерно по отрезку (n событий — n-оль; без n — сколько есть)
--   golden      громкость убывает по золотому сечению: каждая следующая ×0.618 от первой
--   vel k       громкость ×k (0.5 тише, 2 громче)

local XF = {}
XF.PHI = (1 + math.sqrt(5)) / 2

local function copy(ev)
  local out = {}
  for i, e in ipairs(ev) do out[i] = { row = e.row, v = e.v, i = i } end
  return out
end
local function clamp01(v) return math.max(0, math.min(1, v)) end

function XF.stretch(ev, r0, r1, k)
  k = (k and k > 0) and k or 1
  local out = copy(ev)
  for _, e in ipairs(out) do e.row = r0 + (e.row - r0) * k end
  return out
end

function XF.reverse(ev, r0, r1)
  local out = copy(ev)
  for _, e in ipairs(out) do e.row = r0 + (r1 - 1 - (e.row - r0)) end   -- голова последней строки ↔ первой
  return out
end

function XF.rotate(ev, r0, r1, n)
  local len = math.max(1, r1 - r0)
  local out = copy(ev)
  for _, e in ipairs(out) do e.row = r0 + ((e.row - r0 + (n or 0)) % len) end
  return out
end

-- детерминированная перестановка (seed)
function XF.shuffle(ev, r0, r1, seed)
  local out = copy(ev)
  local rows = {}
  for i, e in ipairs(out) do rows[i] = e.row end
  local s = (seed or 1) * 7919
  local function rnd(n) s = (s * 1103515245 + 12345) % 2147483648; return s % n + 1 end
  for i = #rows, 2, -1 do local j = rnd(i); rows[i], rows[j] = rows[j], rows[i] end
  for i, e in ipairs(out) do e.row = rows[i] end
  return out
end

function XF.gravity(ev, r0, r1, g)
  g = (g and g > 0) and g or 2
  local len = math.max(1e-9, r1 - r0)
  local out = copy(ev)
  for _, e in ipairs(out) do
    local x = clamp01((e.row - r0) / len)
    e.row = r0 + (x ^ g) * len
  end
  return out
end

-- отскоки: n событий, интервалы d, d·r, d·r² … укладываются в отрезок между первым и последним
function XF.bounce(ev, r0, r1, r)
  r = (r and r > 0 and r < 1) and r or 0.7
  local out = copy(ev)
  table.sort(out, function(a, b) return a.row < b.row end)
  local n = #out
  if n < 3 then return out end
  local a, b = out[1].row, out[n].row
  local total = 0
  for k = 0, n - 2 do total = total + r ^ k end
  local d = (b - a) / total
  local pos = a
  for k = 1, n do
    out[k].row = pos
    pos = pos + d * r ^ (k - 1)
  end
  return out
end

-- Фибоначчи: k-е событие на строке первого + F(k) (0 1 1 2 3 5 8 …, без дубля 1): 0 1 2 3 5 8 13 21 …
-- масштаб — чтобы последнее событие не вышло за r1 (если выходит — все расстояния делятся)
function XF.fib(ev, r0, r1)
  local out = copy(ev)
  table.sort(out, function(a, b) return a.row < b.row end)
  local n = #out
  if n < 2 then return out end
  local f = { 0, 1 }
  while #f < n + 1 do f[#f + 1] = f[#f] + f[#f - 1] end
  local seq = { 0 }
  for k = 3, #f do seq[#seq + 1] = f[k] end                 -- 0 1 2 3 5 8 …
  local a = out[1].row
  local span = seq[n]
  local scale = 1
  if a + span > r1 - 1 then scale = (r1 - 1 - a) / math.max(1, span) end
  for k = 1, n do out[k].row = a + seq[k] * scale end
  return out
end

-- n-оль: события равномерно по отрезку (первые n событий; меньше n — сколько есть)
function XF.tuplet(ev, r0, r1, n)
  local out = copy(ev)
  table.sort(out, function(a, b) return a.row < b.row end)
  local m = math.min(#out, n or #out)
  if m < 1 then return out end
  local len = r1 - r0
  for k = 1, m do out[k].row = r0 + (k - 1) * len / m end
  return out
end

function XF.golden(ev, r0, r1)
  local out = copy(ev)
  table.sort(out, function(a, b) return a.row < b.row end)
  local v0 = out[1] and out[1].v or 1
  for k, e in ipairs(out) do e.v = clamp01(v0 / XF.PHI ^ (k - 1)) end
  return out
end

function XF.vel(ev, r0, r1, k)
  local out = copy(ev)
  for _, e in ipairs(out) do e.v = clamp01((e.v or 0) * (k or 1)) end
  return out
end

XF.OPS = { stretch = XF.stretch, reverse = XF.reverse, rotate = XF.rotate, shuffle = XF.shuffle, gravity = XF.gravity,
           bounce = XF.bounce, fib = XF.fib, tuplet = XF.tuplet, golden = XF.golden, vel = XF.vel }
-- короткие имена
XF.ALIAS = { rev = 'reverse', rot = 'rotate', shuf = 'shuffle', grav = 'gravity', str = 'stretch', tup = 'tuplet', gold = 'golden' }

-- :xf строка → op, arg; nil — неизвестно
function XF.parse(s)
  local name, arg = (s or ''):match('^%s*(%a+)%s*(.-)%s*$')
  if not name then return nil end
  name = XF.ALIAS[name] or name
  if not XF.OPS[name] then return nil end
  return name, tonumber(arg)
end

function XF.apply(name, ev, r0, r1, arg)
  local f = XF.OPS[name]
  if not f then return nil end
  return f(ev, r0, r1, arg)
end

return XF
