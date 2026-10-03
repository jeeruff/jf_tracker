-- jf_tracker_logo.lua — логотип JFTRACKER для about (главный модуль, 3 окт).
--
-- Шесть текстовых логотипов, присланных пользователем (картинки ANSI убраны
-- по просьбе — только настоящий текст); каждый показ about — другой.
-- Блочные символы (░ ▒ ▓ █ ▀ ▄ ╱ ╲) битмап-шрифт REAPER не знает, а запасной
-- системный шрифт сбил бы колонки — поэтому логотип рисуется сам, по сетке
-- символов: прямоугольники (█ ▀ ▄ ▌ ▐), оттенки ░ ▒ ▓ — попиксельным дизерингом,
-- диагонали линиями, ASCII-штрихи (: + # _ -) — палочками. Сетка ужимается
-- под ширину окна; меньше 2 px на символ — about пишет LG.SHORT строкой.
-- Цвет — палитра CGA / ANSI по строкам (LG.SCHEME), на чёрной плашке.
--
-- Без reaper.* (только gfx в LG.draw): тестируется tests/test_logo.lua.

local LG = {}

LG.LOGOS = {
  { name = 'alligator', lines = {
    [[::::::::::: :::::::::: ::::::::::: :::::::::      :::      ::::::::  :::    ::: :::::::::: :::::::::]],
    [[    :+:     :+:            :+:     :+:    :+:   :+: :+:   :+:    :+: :+:   :+:  :+:        :+:    :+:]],
    [[    +:+     +:+            +:+     +:+    +:+  +:+   +:+  +:+        +:+  +:+   +:+        +:+    +:+]],
    [[    +#+     :#::+::#       +#+     +#++:++#:  +#++:++#++: +#+        +#++:++    +#++:++#   +#++:++#:]],
    [[    +#+     +#+            +#+     +#+    +#+ +#+     +#+ +#+        +#+  +#+   +#+        +#+    +#+]],
    [[#+# #+#     #+#            #+#     #+#    #+# #+#     #+# #+#    #+# #+#   #+#  #+#        #+#    #+#]],
    [[ #####      ###            ###     ###    ### ###     ###  ########  ###    ### ########## ###    ###]],
  } },
  { name = 'drip', lines = {
    [[  ▓▄▓ ▓▄▓▀▓ ▓▀▓▄▓▀▓ ▓▄▓▀ ▄▄ ▓▄▓▀ ▄▓ ▓▄▓▀▓ ▓▄▓  ▄▓ ▓▄▓▀▓ ▓▄▓▀ ▄▄]],
    [[  ▒▓▒ ▒▓▒ ▒ ▒ ▒▓▒ ▒ ▒▓▒ ▒▓▒ ▒▓▒ ▒▓▒ ▒▓▒ ▒ ▒▓▒ ▒▓▒ ▒▓▒ ▒ ▒▓▒ ▒▓▒]],
    [[  ░▒░ ░▒░ ░ ░ ░▒░ ░ ░▒░ ░▒░ ░▒░ ░▒░ ░▒░ ░ ░▒░ ░▒░ ░▒░ ░ ░▒░ ░▒░]],
    [[  █░   ░       ░█    ░█  ░█  ░█  ░█ █░█    ░█  ░█ █░█    ░█  ░█]],
    [[  █▀█ █▀█▀    █▀    █▀█▀█▀▄ █▀█▀█▀█ █▀█   █▀█▀█▀▄ █▀█▀  █▀█▀█▀▄]],
    [[   ░█  ░      █░    █░  █░  █░  █░  █░█   █░  █░  █░█   █░  █░]],
    [[░ ░▒░ ░▒░     ░▒░   ░▒░ ░▒░ ░▒░ ░▒░ ░▒░ ░ ░▒░ ░▒░ ░▒░ ░ ░▒░ ░▒░]],
    [[▒ ▒▓▒ ▒▓▒     ▒▓▒   ▒▓▒ ▒▓▒ ▒▓▒ ▒▓▒ ▒▓▒ ▒ ▒▓▒ ▒▓▒ ▒▓▒ ▒ ▒▓▒ ▒▓▒]],
    [[▓ ▓█▓ ▓█▓     ▓█▓   ▓█▓ ▓█▓ ▓█▓ ▓█▓ ▓█▓ ▓ ▓█▓ ▓█▓ ▓█▓ ▓ ▓█▓ ▓█▓]],
    [[▀▀▀▀▀ ▀▀▀     ▀▀▀   ▀▀▀ ▀▀▀ ▀▀▀ ▀▀▀ ▀▀▀▀▀ ▀▀▀ ▀▀▀ ▀▀▀▀▀ ▀▀▀ ▀▀▀]],
  } },
  { name = 'slant', lines = {
    [[    ______  ________  ________  ________  ________  ________  ____ ___  ________  ________]],
    [[   ╱      ╲╱        ╲╱        ╲╱        ╲╱        ╲╱        ╲╱    ╱   ╲╱        ╲╱        ╲]],
    [[  ╱       ╱       __╱        _╱         ╱         ╱         ╱         ╱         ╱         ╱]],
    [[_╱       ╱        _╱╱       ╱╱        _╱         ╱       --╱        _╱        _╱        _╱]],
    [[╲_______╱╲_______╱  ╲______╱ ╲____╱___╱╲___╱____╱╲________╱╲____╱___╱╲________╱╲____╱___╱]],
  } },
  { name = 'shade', lines = {
    [[░        ░░        ░░        ░░       ░░░░      ░░░░      ░░░  ░░░░  ░░        ░░       ░░]],
    [[▒▒▒▒▒▒▒  ▒▒  ▒▒▒▒▒▒▒▒▒▒▒  ▒▒▒▒▒  ▒▒▒▒  ▒▒  ▒▒▒▒  ▒▒  ▒▒▒▒  ▒▒  ▒▒▒  ▒▒▒  ▒▒▒▒▒▒▒▒  ▒▒▒▒  ▒]],
    [[▓▓▓▓▓▓▓  ▓▓      ▓▓▓▓▓▓▓  ▓▓▓▓▓       ▓▓▓  ▓▓▓▓  ▓▓  ▓▓▓▓▓▓▓▓     ▓▓▓▓▓      ▓▓▓▓       ▓▓]],
    [[█  ████  ██  ███████████  █████  ███  ███        ██  ████  ██  ███  ███  ████████  ███  ██]],
    [[██      ███  ███████████  █████  ████  ██  ████  ███      ███  ████  ██        ██  ████  █]],
  } },
  { name = 'bloody', lines = {
    [[ ▄▄▄██▀▀▀█████▒▄▄▄█████▓ ██▀███   ▄▄▄       ▄████▄   ██ ▄█▀▓█████  ██▀███]],
    [[   ▒██ ▓██   ▒ ▓  ██▒ ▓▒▓██ ▒ ██▒▒████▄    ▒██▀ ▀█   ██▄█▒ ▓█   ▀ ▓██ ▒ ██▒]],
    [[   ░██ ▒████ ░ ▒ ▓██░ ▒░▓██ ░▄█ ▒▒██  ▀█▄  ▒▓█    ▄ ▓███▄░ ▒███   ▓██ ░▄█ ▒]],
    [[▓██▄██▓░▓█▒  ░ ░ ▓██▓ ░ ▒██▀▀█▄  ░██▄▄▄▄██ ▒▓▓▄ ▄██▒▓██ █▄ ▒▓█  ▄ ▒██▀▀█▄]],
    [[ ▓███▒ ░▒█░      ▒██▒ ░ ░██▓ ▒██▒ ▓█   ▓██▒▒ ▓███▀ ░▒██▒ █▄░▒████▒░██▓ ▒██▒]],
    [[ ▒▓▒▒░  ▒ ░      ▒ ░░   ░ ▒▓ ░▒▓░ ▒▒   ▓▒█░░ ░▒ ▒  ░▒ ▒▒ ▓▒░░ ▒░ ░░ ▒▓ ░▒▓░]],
    [[ ▒ ░▒░  ░          ░      ░▒ ░ ▒░  ▒   ▒▒ ░  ░  ▒   ░ ░▒ ▒░ ░ ░  ░  ░▒ ░ ▒░]],
    [[ ░ ░ ░  ░ ░      ░        ░░   ░   ░   ▒   ░        ░ ░░ ░    ░     ░░   ░]],
    [[ ░   ░                     ░           ░  ░░ ░      ░  ░      ░  ░   ░]],
    [[                                           ░]],
  } },
  { name = 'rubble', lines = {
    [[    █▀█▀▒ ▀▒▀█▀█▀█▄  ██▀▒▀█▀█▀██ ▀▒▀█▀█▀█▄  ▀▒▀█▀█▀█▄  ▀▒▀█▀█▀█▄  ▀▒▀█▀█ ███ ▀▒▀█▀█▀█▄  ▀▒▀█▀█▀█▄]],
    [[    ████▓  ▓████ ██▄ ██ ▓████ ██  ▓████ ██▄  ▓████ ██▄  ▓████ ██▄  ▓████ ███  ▓████ ██▄  ▓████ ██▄]],
    [[    █████  █████▄       █████     █████▄▓▀▀  █████▄███  █████      █████▄██▀  █████▄     █████▄▓▀▀]],
    [[▄▄▄ █████  █████        █████     █████ ███  █████ ███  █████ ▄▄▄  █████ ███  █████ ▄▄▄  █████ ███]],
    [[███ █████  █████        █████     ████▓ ███  █████ ███  █████ ███  █████ ███  █████ ███  ████▓ ███]],
    [[███ █▓███  ▄▀███        ▄▀███     ███▀▄ ███  █████ ███  ███▓█ ███  █████ ███  ███▓█ ███  ███▀▄ ███]],
    [[███ ▀▄▄▀█  ░▌▐██        ░▌▐██     ██▌▐░ ▐██  ▓████ ███  █▀▄▄▀ ███  ▓████ ███  █▀▄▄▀ ███  ██▌▐░ ▐██]],
    [[█▓█ █ ░▀▄  ▀▄▀▓█        ▀▄▀▓█     █▓▀▄▀ █▓█  ▄▄▀██ ███  ▄▀░ █ █▓█  ▄▄▀██ ███  ▄▀░ █ █▓█  █▓▀▄▀ █▓█]],
    [[▀▄▄ ▄▀▀▄▄  ▒░█▄▀        ▒░█▄▀     ▀▄ ░▒ ▄▄▀   ░▒ █ ███  ▄▄▀▀▄ ▄▄▀   ░▒ █ ███  ▄▄▀▀▄ ▄▄▀  ▀▄ ░▒ ▄▄▀]],
    [[░▀▀  ██░▒  ░ ░▒         ░ ░▒       ▒░ ░ ░ ░  ▀▀▄▀▓ ███  ▒░██  ▀▀░  ▀▀▄▀▓ ███  ▒░██  ▀▀░   ▒░ ░ ░ ░]],
    [[▄▓▒ █▄▀█░  ▄▀▀▄░        ▄▀▀▄░     ░▄▀▀▄ ▄▀▄  ▒░░▒  ▀▓█  ░█▀▄█ ▒▓▄  ▒░░▒  ▀▓█  ░█▀▄█ ▒▓▄  ░▄▀▀▄ ▄▀▄]],
    [[ ▀░▄█░ ▄▄  ░█ ░▓        ░█ ░▓     ▒░ █░ ░▒   ░ ▀▄░ ░▄▀  ▄▄ ░█▄░▀   ░ ▀▄░ ░▄▀  ▄▄ ░█▄░▀   ▒░ █░ ░▒]],
  } },
}
LG.SHORT = 'J F T R A C K E R'

-- символы строки (UTF-8 → таблица строк по одному символу)
local function chars(s)
  local t = {}
  for _, cp in utf8.codes(s) do t[#t + 1] = utf8.char(cp) end
  return t
end
LG.chars = chars

-- размер логотипа в символах: ширина, высота
function LG.size(logo)
  local w = 0
  for _, l in ipairs(logo.lines) do w = math.max(w, utf8.len(l)) end
  return w, #logo.lines
end

-- следующий логотип: не тот же, что prev (индекс); rnd — для тестов
function LG.pick(prev, rnd)
  rnd = rnd or math.random
  local n = #LG.LOGOS
  if n < 2 then return 1 end
  local k = rnd(1, n - 1)
  if prev and k >= prev then k = k + 1 end
  return k
end

-- ячейка: ширина символа, чтобы логотип влез в aw px, при соотношении
-- сторон шрифта (cw0 × ch0); nil — не влезает (меньше 2 px)
function LG.cell(logo, aw, cw0, ch0)
  local w = LG.size(logo)
  local cw = math.min(cw0, math.floor(aw / math.max(1, w)))
  if cw < 2 then return nil end
  return cw, math.max(2, math.floor(cw * ch0 / cw0 + 0.5))
end

-- палитра CGA / ANSI (как в генераторах ANSI-логотипов)
LG.PAL = {
  black = { 0, 0, 0 }, blue = { 0, 0, 0.667 }, green = { 0, 0.667, 0 }, cyan = { 0, 0.667, 0.667 },
  red = { 0.667, 0, 0 }, magenta = { 0.667, 0, 0.667 }, brown = { 0.667, 0.333, 0 }, lightgrey = { 0.667, 0.667, 0.667 },
  darkgrey = { 0.333, 0.333, 0.333 }, lightblue = { 0.333, 0.333, 1 }, lightgreen = { 0.333, 1, 0.333 },
  lightcyan = { 0.333, 1, 1 }, lightred = { 1, 0.333, 0.333 }, lightmagenta = { 1, 0.333, 1 },
  yellow = { 1, 1, 0.333 }, white = { 1, 1, 1 },
}
-- раскраска по строкам, ступенями (как в ANSI, без плавных градиентов):
-- { с какой строки, цвет, [цвет оттенков ░ ▒ ▓ — иначе тот же] }
-- rubble — по референсу пользователя: светло-серая кромка, серый верх,
-- коричневый низ, жёлтый дизеринг; остальные — в той же палитре
LG.SCHEME = {
  alligator = { { 1, 'lightcyan' }, { 3, 'cyan' }, { 6, 'lightblue' } },
  drip = { { 1, 'lightmagenta' }, { 4, 'magenta' }, { 7, 'lightred', 'magenta' } },
  slant = { { 1, 'white' }, { 2, 'lightcyan' }, { 4, 'lightblue' } },
  shade = { { 1, 'lightcyan', 'darkgrey' }, { 3, 'cyan', 'darkgrey' } },
  bloody = { { 1, 'lightred' }, { 3, 'red' }, { 6, 'red', 'darkgrey' } },
  rubble = { { 1, 'lightgrey' }, { 2, 'darkgrey' }, { 6, 'brown', 'yellow' } },
}

-- цвет строки li: { основной, оттенков }
function LG.row_colour(logo, li)
  local sc = LG.SCHEME[logo.name]
  if not sc then return nil end
  local ink, sh = sc[1][2], sc[1][3]
  for _, st in ipairs(sc) do if li >= st[1] then ink, sh = st[2], st[3] end end
  return LG.PAL[ink], LG.PAL[sh or ink]
end

-- дизеринг: какие пиксели горят (клетки d×d, узор непрерывный по абсолютным координатам)
local DITHER = {
  ['░'] = function(x, y) return x % 2 == 0 and y % 2 == 0 end,
  ['▒'] = function(x, y) return (x + y) % 2 == 0 end,
  ['▓'] = function(x, y) return not (x % 2 == 1 and y % 2 == 1) end,
}
LG.DITHER = DITHER

-- нарисовать на чёрном (фон — забота вызывающего: about рисует логотип
-- один раз в отдельную картинку, дизеринг попиксельный и дорогой):
-- левый верх x, y; ячейка cw × ch; ink — цвет, если у логотипа нет схемы
function LG.draw(logo, x, y, cw, ch, ink)
  local t = math.max(1, math.floor(cw / 4))
  local d = math.max(1, math.floor(cw / 5))                 -- размер точки дизеринга
  local function set(c) gfx.set(c[1], c[2], c[3], 1) end
  local function r(x0, y0, w, h) gfx.rect(x0, y0, math.max(1, w), math.max(1, h), 1) end
  for li, l in ipairs(logo.lines) do
    local cy = y + (li - 1) * ch
    local fg, shc = LG.row_colour(logo, li)
    fg = fg or ink; shc = shc or fg
    for k, c in ipairs(chars(l)) do
      local cx = x + (k - 1) * cw
      if c ~= ' ' then
        local dz = DITHER[c]
        if dz then
          set(shc)
          for py = 0, ch - 1, d do
            for px = 0, cw - 1, d do
              if dz(math.floor((cx + px) / d), math.floor((cy + py) / d)) then r(cx + px, cy + py, math.min(d, cw - px), math.min(d, ch - py)) end
            end
          end
        else
          set(fg)
          local hm = math.floor(ch / 2)
          if c == '█' then r(cx, cy, cw, ch)
          elseif c == '▀' then r(cx, cy, cw, hm)
          elseif c == '▄' then r(cx, cy + hm, cw, ch - hm)
          elseif c == '▌' then r(cx, cy, math.floor(cw / 2), ch)
          elseif c == '▐' then local h2 = math.floor(cw / 2); r(cx + h2, cy, cw - h2, ch)
          elseif c == '╱' or c == '╲' then
            for dd = 0, t - 1 do
              if c == '╱' then gfx.line(cx + dd, cy + ch - 1, cx + cw - 1 + dd, cy)
              else gfx.line(cx + dd, cy, cx + cw - 1 + dd, cy + ch - 1) end
            end
          elseif c == '_' then r(cx, cy + ch - t, cw, t)
          elseif c == '-' then r(cx, cy + hm, cw, t)
          -- : + # — плотность «аллигатора» (светлый → тёмный): штрихи толще и во
          -- всю клетку, иначе буквы на пиксельной сетке рассыпаются в точки
          elseif c == ':' then
            local s = math.max(1, math.floor(cw / 2)); local ox = cx + math.floor((cw - s) / 2)
            r(ox, cy + math.floor(ch * 0.2), s, s); r(ox, cy + math.floor(ch * 0.8) - s, s, s)
          elseif c == '+' then
            local s = math.max(1, math.floor(cw / 2))
            r(cx + math.floor((cw - s) / 2), cy, s, ch)
            r(cx, cy + hm - math.floor(s / 2), cw, s)
          elseif c == '#' then
            local s = math.max(1, math.floor(cw / 3))
            r(cx, cy, s, ch); r(cx + cw - s, cy, s, ch)
            r(cx, cy + math.floor(ch * 0.25), cw, s); r(cx, cy + math.floor(ch * 0.75) - s, cw, s)
          else r(cx, cy, cw, ch) end                         -- неизвестный — сплошной
        end
      end
    end
  end
end

return LG
