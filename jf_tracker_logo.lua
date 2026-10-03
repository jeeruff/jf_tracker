-- jf_tracker_logo.lua — граффити-логотип JFTRACKER для страницы about (3 окт).
--
-- Каждый показ — новый стиль, как логотипы на pouet: буквы берутся из своего
-- пиксельного шрифта 5×7 (ровные всегда), а стиль решает, чем «рисовать»
-- пиксели: блок #, олдскул с тенью, бабл-граффити, металл (курсив, шипы,
-- потёки), 3D-тень; плюс классический figlet «standard» (pouet ASCII).
-- Только ASCII — битмап-шрифт REAPER другого не знает.
--
-- Без reaper.*: тестируется tests/test_logo.lua.

local LG = {}

local FONT = {
  J = { '..###', '...#.', '...#.', '...#.', '#..#.', '#..#.', '.##..' },
  F = { '#####', '#....', '#....', '####.', '#....', '#....', '#....' },
  T = { '#####', '..#..', '..#..', '..#..', '..#..', '..#..', '..#..' },
  R = { '####.', '#...#', '#...#', '####.', '#.#..', '#..#.', '#...#' },
  A = { '.###.', '#...#', '#...#', '#####', '#...#', '#...#', '#...#' },
  C = { '.###.', '#...#', '#....', '#....', '#....', '#...#', '.###.' },
  K = { '#...#', '#..#.', '#.#..', '##...', '#.#..', '#..#.', '#...#' },
  E = { '#####', '#....', '#....', '####.', '#....', '#....', '#####' },
}
LG.WORD = 'JFTRACKER'

-- пиксельная сетка слова: rows[y][x] = true; буквы через 1 пустой столбец
function LG.grid(word)
  word = word or LG.WORD
  local rows = {}
  for y = 1, 7 do rows[y] = {} end
  local x0 = 0
  for i = 1, #word do
    local g = FONT[word:sub(i, i)]
    if g then
      for y = 1, 7 do
        for x = 1, 5 do rows[y][x0 + x] = g[y]:sub(x, x) == '#' end
      end
      x0 = x0 + 6
    end
  end
  return rows, x0 - 1
end

local function px(rows, x, y) return rows[y] and rows[y][x] or false end

local function trim(lines)
  for i, l in ipairs(lines) do lines[i] = l:gsub('%s+$', '') end
  return lines
end

-- стили: функция (rows, w) → строки
local STYLES = {}

-- блок: просто #
STYLES.block = function(rows, w)
  local out = {}
  for y = 1, 7 do
    local t = {}
    for x = 1, w do t[x] = px(rows, x, y) and '#' or ' ' end
    out[y] = table.concat(t)
  end
  return out
end

-- олдскул: буквы @, тень : со сдвигом вправо-вниз (Amiga / C64)
STYLES.oldskool = function(rows, w)
  local out = {}
  for y = 1, 8 do
    local t = {}
    for x = 1, w + 1 do
      if px(rows, x, y) then t[x] = '@'
      elseif px(rows, x - 1, y - 1) then t[x] = ':'
      else t[x] = ' ' end
    end
    out[y] = table.concat(t)
  end
  return out
end

-- бабл: каждая полоса пикселей — пузырь (ooo), одиночный пиксель — o
STYLES.bubble = function(rows, w)
  local out = {}
  for y = 1, 7 do
    local t = {}
    local x = 1
    while x <= w do
      if px(rows, x, y) then
        local x1 = x
        while px(rows, x1 + 1, y) do x1 = x1 + 1 end
        local len = x1 - x + 1
        t[#t + 1] = len == 1 and 'o' or ('(' .. ('o'):rep(len - 2) .. ')')
        x = x1 + 1
      else t[#t + 1] = ' '; x = x + 1 end
    end
    out[y] = table.concat(t)
  end
  return out
end

-- металл: курсив (каждая строка левее), шипы ^ над верхним краем, потёки
-- | и ' под нижним — продолжают наклон; шипастые концы >> << посередине
STYLES.metal = function(rows, w)
  local out = {}
  local slant = 8
  local function pre(y) return (' '):rep(math.max(0, slant - y)) end
  local top = {}
  for x = 1, w do top[x] = (px(rows, x, 1) and (x % 2 == 1)) and '^' or ' ' end
  out[#out + 1] = pre(0) .. '  ' .. table.concat(top)
  for y = 1, 7 do
    local t = {}
    for x = 1, w do t[x] = px(rows, x, y) and '#' or ' ' end
    out[#out + 1] = pre(y) .. (y == 4 and '>>' or '  ') .. table.concat(t) .. (y == 4 and ' <<' or '')
  end
  for d = 1, 2 do
    local t = {}
    for x = 1, w do t[x] = (px(rows, x, 7) and ((x * 7 + d) % 3 == 0)) and (d == 1 and '|' or "'") or ' ' end
    out[#out + 1] = pre(7 + d) .. '  ' .. table.concat(t)
  end
  return out
end

-- 3D: # и грань / справа от каждой полосы
STYLES.shadow3d = function(rows, w)
  local out = {}
  for y = 1, 7 do
    local t = {}
    for x = 1, w + 1 do
      if px(rows, x, y) then t[x] = '#'
      elseif px(rows, x - 1, y) then t[x] = '/'
      else t[x] = ' ' end
    end
    out[y] = table.concat(t)
  end
  return out
end

-- хром: градиент сверху вниз, как хромированные олдскул-логотипы
STYLES.chrome = function(rows, w)
  local ink = { '@', '@', '#', '=', '+', ':', '.' }
  local out = {}
  for y = 1, 7 do
    local t = {}
    for x = 1, w do t[x] = px(rows, x, y) and ink[y] or ' ' end
    out[y] = table.concat(t)
  end
  return out
end

-- pouet ASCII: figlet «standard», буквы как в ASCII-интро
local FIG = {
  J = { '     _ ', '    | |', ' _  | |', '| |_| |', ' \\___/ ' },
  F = { ' _____ ', '|  ___|', '| |_   ', '|  _|  ', '|_|    ' },
  T = { ' _____ ', '|_   _|', '  | |  ', '  | |  ', '  |_|  ' },
  R = { ' ____  ', '|  _ \\ ', '| |_) |', '|  _ < ', '|_| \\_\\' },
  A = { '    _    ', '   / \\   ', '  / _ \\  ', ' / ___ \\ ', '/_/   \\_\\' },
  C = { '  ____ ', ' / ___|', '| |    ', '| |___ ', ' \\____|' },
  K = { ' _  __', '| |/ /', "| ' / ", '| . \\ ', '|_|\\_\\' },
  E = { ' _____ ', '| ____|', '|  _|  ', '| |___ ', '|_____|' },
}
function LG.figlet(word)
  word = word or LG.WORD
  local out = { '', '', '', '', '' }
  for i = 1, #word do
    local g = FIG[word:sub(i, i)]
    if g then for y = 1, 5 do out[y] = out[y] .. g[y] end end
  end
  return out
end

LG.STYLE_NAMES = { 'pouet', 'block', 'oldskool', 'bubble', 'metal', 'shadow3d', 'chrome' }

-- логотип стиля name (nil — случайный); вторым — имя стиля
function LG.make(name, rnd)
  rnd = rnd or math.random
  name = name or LG.STYLE_NAMES[rnd(1, #LG.STYLE_NAMES)]
  local lines
  if name == 'pouet' then lines = LG.figlet()
  else
    local rows, w = LG.grid()
    lines = STYLES[name](rows, w)
  end
  return trim(lines), name
end

return LG
