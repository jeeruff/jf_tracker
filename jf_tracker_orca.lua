-- jf_tracker_orca.lua — ядро Orca (Hundred Rabbits) для Garden трекера.
-- Чистый Lua: без reaper.*, тестируется tests/test_orca.lua.
--
-- Поле — сетка символов. Каждый тик (= строка трекера при игре) поле
-- читается сверху вниз, слева направо. Заглавная буква — оператор, работает
-- каждый тик; строчная — только если рядом (N S E W) лежит банг `*`.
-- Входы оператора — клетки слева/справа (порты), выход — клетка под ним.
-- Прочитанные и записанные клетки блокируются до конца тика (поэтому
-- аргумент-буква не исполняется как оператор). Значения — base-36
-- (0-9, a-z, регистр не важен; регистр результата — как у правого входа).
--
-- Операторы: A add  B subtract  C clock  D delay  E/W/N/S движение
--   F if  G generator  H halt  I increment  J jumper  K konkat  L lesser
--   M multiply  O read  P push  Q query  R random  T track  U uclid
--   V variable  X write  Y yumper  Z lerp  * банг  # комментарий.
-- Выходы в REAPER (работают каждый тик, блокируют аргументы, срабатывают
-- только по бангу рядом):
--   : track inst oct note vel len  — посадить ноту
--   ; slot slot                     — регион последовательности в очередь
--   = track fx param value          — параметр FX
--   $ track inst slice vel          — посадить слайс
-- Нота: C D E F G A B, строчная = диез (c=C#, d=D#, f=F#, g=G#, a=A#, e=F,
-- b=C следующей октавы); pitch = (oct+1)*12 + полутон (oct 4, C → 60).

local O = {}
O.rand = math.random

local B36 = '0123456789abcdefghijklmnopqrstuvwxyz'

function O.b36(ch)
  if not ch or ch == '.' or ch == '' then return nil end
  local i = B36:find(ch:lower(), 1, true)
  return i and (i - 1) or nil
end

function O.chr(n, upper)
  n = math.floor(n) % 36
  local c = B36:sub(n + 1, n + 1)
  return upper and c:upper() or c
end

local NOTES = { C = 0, D = 2, E = 4, F = 5, G = 7, A = 9, B = 11,
                c = 1, d = 3, e = 5, f = 6, g = 8, a = 10, b = 12 }
function O.note_pitch(oct, note)
  local o = O.b36(oct)
  local s = note and NOTES[note]
  if not o or not s then return nil end
  return (o + 1) * 12 + s
end

function O.new(w, h)
  local f = { w = w or 32, h = h or 8, cells = {}, frame = 0, vars = {}, on = true }
  for y = 0, f.h - 1 do f.cells[y] = {}; for x = 0, f.w - 1 do f.cells[y][x] = '.' end end
  f.locks, f.fired = {}, {}
  return f
end

function O.get(f, x, y)
  if x < 0 or y < 0 or x >= f.w or y >= f.h then return '.' end
  return f.cells[y][x]
end

function O.set(f, x, y, ch)
  if x < 0 or y < 0 or x >= f.w or y >= f.h then return end
  if not ch or ch == '' or ch == ' ' then ch = '.' end
  f.cells[y][x] = ch:sub(1, 1)
end

function O.serialize(f)
  local out = { ('v1 %d %d %s'):format(f.w, f.h, f.on and 'on' or 'off') }
  for y = 0, f.h - 1 do
    local row = {}
    for x = 0, f.w - 1 do row[#row + 1] = f.cells[y][x] end
    out[#out + 1] = table.concat(row)
  end
  return table.concat(out, '\n')
end

function O.parse(text)
  if not text or text == '' then return nil end
  local lines = {}
  for l in (text .. '\n'):gmatch('([^\n]*)\n') do lines[#lines + 1] = l end
  local w, h, on = (lines[1] or ''):match('^v1 (%d+) (%d+) (%a+)')
  if not w then return nil end
  local f = O.new(tonumber(w), tonumber(h))
  f.on = on == 'on'
  for y = 0, f.h - 1 do
    local l = lines[y + 2] or ''
    for x = 0, f.w - 1 do
      local c = l:sub(x + 1, x + 1)
      f.cells[y][x] = (c ~= '' and c ~= ' ') and c or '.'
    end
  end
  return f
end

function O.resize(f, w, h)
  local g = O.new(w, h)
  g.on, g.frame, g.vars = f.on, f.frame, f.vars
  for y = 0, math.min(f.h, h) - 1 do for x = 0, math.min(f.w, w) - 1 do g.cells[y][x] = f.cells[y][x] end end
  return g
end

-- ── тик ───────────────────────────────────────────────────────────────────
local function key(x, y) return y * 4096 + x end

-- один кадр; возвращает список выходов { op=, x=, y=, args = {символы} }
function O.tick(f)
  f.locks, f.fired = {}, {}
  local outs = {}
  local frame = f.frame
  local locks = f.locks
  local function lock(x, y) locks[key(x, y)] = true end
  local function locked(x, y) return locks[key(x, y)] end
  local function read(x, y) lock(x, y); return O.get(f, x, y) end
  local function write(x, y, ch) if x >= 0 and y >= 0 and x < f.w and y < f.h then f.cells[y][x] = ch; lock(x, y) end end
  local function val(x, y, def) local v = O.b36(read(x, y)); if v == nil then return def end; return v end
  local function upper_of(x, y) local c = O.get(f, x, y); return c:match('%u') ~= nil end
  local function banged(x, y)
    return O.get(f, x - 1, y) == '*' or O.get(f, x + 1, y) == '*' or O.get(f, x, y - 1) == '*' or O.get(f, x, y + 1) == '*'
  end
  local function fire(x, y) f.fired[key(x, y)] = true end
  local function bang_out(x, y, yes) write(x, y + 1, yes and '*' or '.'); if yes then fire(x, y) end end

  local ops = {}
  ops.A = function(x, y) local a, b = val(x - 1, y, 0), val(x + 1, y, 0); write(x, y + 1, O.chr(a + b, upper_of(x + 1, y))) end
  ops.B = function(x, y) local a, b = val(x - 1, y, 0), val(x + 1, y, 0); write(x, y + 1, O.chr(math.abs(b - a), upper_of(x + 1, y))) end
  ops.C = function(x, y)
    local rate, mod = math.max(1, val(x - 1, y, 1)), val(x + 1, y, 8)
    if mod < 1 then mod = 8 end
    write(x, y + 1, O.chr(math.floor(frame / rate) % mod, upper_of(x + 1, y)))
  end
  ops.D = function(x, y)
    local rate, mod = math.max(1, val(x - 1, y, 1)), val(x + 1, y, 8)
    if mod < 1 then mod = 8 end
    bang_out(x, y, frame % (rate * mod) == 0)
  end
  ops.F = function(x, y) local a, b = read(x - 1, y), read(x + 1, y); bang_out(x, y, a == b and a ~= '.') end
  ops.G = function(x, y)
    local px, py, len = val(x - 3, y, 0), val(x - 2, y, 0), math.max(1, val(x - 1, y, 1))
    for i = 0, len - 1 do write(x + px + i, y + py + 1, read(x + 1 + i, y)) end
  end
  ops.H = function(x, y) lock(x, y + 1) end
  ops.I = function(x, y)
    local step, mod = val(x - 1, y, 1), val(x + 1, y, 36)
    if mod < 1 then mod = 36 end
    local cur = O.b36(O.get(f, x, y + 1)) or 0
    write(x, y + 1, O.chr((cur + step) % mod, upper_of(x + 1, y)))
  end
  ops.J = function(x, y) local v = read(x, y - 1); if v ~= 'J' then write(x, y + 1, v) end end
  ops.K = function(x, y)
    local len = math.max(1, val(x - 1, y, 1))
    for i = 1, len do
      local name = read(x + i, y)
      if name ~= '.' and f.vars[name] then write(x + i, y + 1, f.vars[name]) end
    end
  end
  ops.L = function(x, y) local a, b = val(x - 1, y, 0), val(x + 1, y, 0); write(x, y + 1, O.chr(math.min(a, b), upper_of(x + 1, y))) end
  ops.M = function(x, y) local a, b = val(x - 1, y, 0), val(x + 1, y, 0); write(x, y + 1, O.chr(a * b, upper_of(x + 1, y))) end
  ops.O = function(x, y)
    local px, py = val(x - 2, y, 0), val(x - 1, y, 0)
    write(x, y + 1, read(x + 1 + px, y + py))
  end
  ops.P = function(x, y)
    local k, len = val(x - 2, y, 0), math.max(1, val(x - 1, y, 1))
    local v = read(x + 1, y)
    for i = 0, len - 1 do lock(x + i, y + 1) end
    write(x + (k % len), y + 1, v)
  end
  ops.Q = function(x, y)
    local px, py, len = val(x - 3, y, 0), val(x - 2, y, 0), math.max(1, val(x - 1, y, 1))
    for i = 0, len - 1 do write(x - len + 1 + i, y + 1, read(x + 1 + px + i, y + py)) end
  end
  ops.R = function(x, y)
    local lo, hi = val(x - 1, y, 0), val(x + 1, y, 35)
    if hi < lo then lo, hi = hi, lo end
    write(x, y + 1, O.chr(lo + math.floor(O.rand() * (hi - lo + 1)) % (hi - lo + 1), upper_of(x + 1, y)))
  end
  ops.T = function(x, y)
    local k, len = val(x - 2, y, 0), math.max(1, val(x - 1, y, 1))
    for i = 1, len do lock(x + i, y) end
    write(x, y + 1, O.get(f, x + 1 + (k % len), y))
  end
  ops.U = function(x, y)
    local step, max = val(x - 1, y, 1), val(x + 1, y, 8)
    if max < 1 then max = 8 end
    local k = frame % max
    bang_out(x, y, math.floor((k + 1) * step / max) > math.floor(k * step / max))
  end
  ops.V = function(x, y)
    local w, r = read(x - 1, y), read(x + 1, y)
    if w ~= '.' then f.vars[w] = r
    elseif r ~= '.' then write(x, y + 1, f.vars[r] or '.') end
  end
  ops.X = function(x, y)
    local px, py = val(x - 2, y, 0), val(x - 1, y, 0)
    write(x + px, y + py + 1, read(x + 1, y))
  end
  ops.Y = function(x, y) local v = read(x - 1, y); if v ~= 'Y' then write(x + 1, y, v) end end
  ops.Z = function(x, y)
    local rate, target = val(x - 1, y, 1), val(x + 1, y, 0)
    local cur = O.b36(O.get(f, x, y + 1)) or 0
    local nv = cur
    if cur < target then nv = math.min(target, cur + rate) elseif cur > target then nv = math.max(target, cur - rate) end
    write(x, y + 1, O.chr(nv, upper_of(x + 1, y)))
  end
  local function mover(dx, dy)
    return function(x, y)
      local ch = f.cells[y][x]
      local nx, ny = x + dx, y + dy
      if nx < 0 or ny < 0 or nx >= f.w or ny >= f.h or O.get(f, nx, ny) ~= '.' then
        f.cells[y][x] = '*'; lock(x, y); fire(x, y); return
      end
      f.cells[y][x] = '.'
      write(nx, ny, ch)
    end
  end
  ops.E, ops.W, ops.N, ops.S = mover(1, 0), mover(-1, 0), mover(0, -1), mover(0, 1)

  -- выходы в REAPER: аргументы справа, срабатывают по бангу
  local NARGS = { [':'] = 6, [';'] = 2, ['='] = 4, ['$'] = 4 }
  local erase = {}       -- банги, прожившие тик: стираются в конце (соседи успевают их увидеть)

  for y = 0, f.h - 1 do
    local x = 0
    while x < f.w do
      local ch = f.cells[y][x]
      if ch == '#' and not locked(x, y) then
        -- комментарий: до следующего # в строке ничего не исполняется
        local x2 = x + 1
        while x2 < f.w and f.cells[y][x2] ~= '#' do lock(x2, y); x2 = x2 + 1 end
        if x2 < f.w then lock(x2, y) end
        x = x2
      elseif not locked(x, y) and ch ~= '.' then
        if ch == '*' then
          erase[#erase + 1] = { x, y }            -- банг живёт один тик
        elseif NARGS[ch] then
          local args = {}
          for i = 1, NARGS[ch] do args[i] = read(x + i, y) end
          if banged(x, y) then outs[#outs + 1] = { op = ch, x = x, y = y, args = args }; fire(x, y) end
        else
          local up = ch:upper()
          local fn = ops[up]
          if fn and (ch == up or banged(x, y)) then fn(x, y) end
        end
      end
      x = x + 1
    end
  end
  for _, p in ipairs(erase) do
    if not locked(p[1], p[2]) and f.cells[p[2]][p[1]] == '*' then f.cells[p[2]][p[1]] = '.' end
  end
  f.frame = frame + 1
  return outs
end

-- треки, куда сажают : и $ (флаг ячейки Garden): base-36 первого аргумента
function O.targets(f)
  local set = {}
  for y = 0, f.h - 1 do for x = 0, f.w - 1 do
    local c = f.cells[y][x]
    if c == ':' or c == '$' then local t = O.b36(O.get(f, x + 1, y)); if t then set[t] = true end end
  end end
  return set
end

-- справка оператора под курсором (статус-бар)
O.DOC = {
  A = 'A add: a A b -> a+b below', B = 'B subtract: a B b -> |b-a|', C = 'C clock: rate C mod -> frame/rate % mod',
  D = 'D delay: rate D mod -> bang every rate*mod ticks', E = 'E east mover', W = 'W west mover', N = 'N north mover', S = 'S south mover',
  F = 'F if: a F b -> bang if equal', G = 'G generator: x y len G values -> write at offset', H = 'H halt: freezes the cell below',
  I = 'I increment: step I mod -> counts below', J = 'J jumper: passes the value above to below', K = 'K konkat: len K names -> variable values below',
  L = 'L lesser: a L b -> min', M = 'M multiply: a M b -> a*b', O = 'O read: x y O -> value at offset', P = 'P push: key len P val -> writes into a row',
  Q = 'Q query: x y len Q -> copies cells', R = 'R random: min R max', T = 'T track: key len T values -> picks one',
  U = 'U uclid: step U max -> euclidean bangs', V = 'V variable: name V value (write) / V name (read)', X = 'X write: x y X val',
  Y = 'Y yumper: passes the value on the left to the right', Z = 'Z lerp: rate Z target -> moves toward target',
  ['*'] = '* bang (one tick)', ['#'] = '# comment until the next #',
  [':'] = ': plant a note: track inst oct note vel len (on bang)',
  [';'] = '; queue region: slot slot (on bang)',
  ['='] = '= set FX param: track fx param value (on bang)',
  ['$'] = '$ plant a slice: track inst slice vel (on bang)',
}

return O
