-- jf_tracker_ui.lua (копия jf_looper_ui.lua, 5 окт) — нативная графика REAPER (gfx), минимализм.
-- Прямые углы, линии в один пиксель, цвета из темы REAPER. Активное
-- помечается подчёркиванием и цветом текста, а не заливкой.
--
-- Имена (U.AMBER, U.frame, U.button …) сохранены от прошлой версии
-- намеренно: меняется только то, КАК рисуется, вызывающий код не трогаем.
--
-- Модуль только рисует и ловит мышь; вся логика — в jf_looper_loops.lua.

local U = {}

-- Цвета из темы REAPER: окно живёт рядом с ней и не должно выглядеть чужим.
-- НО брать ключи по одному нельзя: у пользователя может стоять любая тема, и
-- пара фон/текст запросто окажется светлой на светлом. В Default 6.0, например,
-- col_main_text2 на col_main_bg2 даёт контраст 2.4:1 — читать невозможно.
-- Поэтому: взять пару, ПОСЧИТАТЬ контраст, и при провале развести
-- принудительно, сохранив оттенок темы.
local function theme(key, fallback)
  local ok, v = pcall(reaper.GetThemeColor, key, 0)
  if not ok or not v or v < 0 then return fallback end
  local r, g, b = reaper.ColorFromNative(v)
  if r + g + b == 0 then return fallback end
  return { r/255, g/255, b/255 }
end

local function mix(a, b, t)
  return { a[1] + (b[1]-a[1])*t, a[2] + (b[2]-a[2])*t, a[3] + (b[3]-a[3])*t }
end

-- относительная яркость по WCAG
local function lum(c)
  local f = {}
  for i = 1, 3 do
    local v = c[i]
    f[i] = v <= 0.03928 and v/12.92 or ((v + 0.055)/1.055)^2.4
  end
  return 0.2126*f[1] + 0.7152*f[2] + 0.0722*f[3]
end

local function contrast(a, b)
  local l1, l2 = lum(a), lum(b)
  if l1 < l2 then l1, l2 = l2, l1 end
  return (l1 + 0.05) / (l2 + 0.05)
end

-- Довести текст до читаемости, сохранив оттенок: тянем к белому или чёрному
-- в зависимости от того, тёмный фон или светлый.
local function readable(fg, bg, target)
  target = target or 4.5
  if contrast(fg, bg) >= target then return fg end
  local goal = lum(bg) < 0.18 and {1, 1, 1} or {0, 0, 0}
  for t = 0.1, 1.0, 0.1 do
    local c = mix(fg, goal, t)
    if contrast(c, bg) >= target then return c end
  end
  return goal
end

U.BG    = theme('col_main_bg2', {0.055, 0.062, 0.068})
local raw_text = theme('col_main_text2', {0.62, 0.66, 0.66})
U.TEXT  = readable(raw_text, U.BG)
-- Акцент задаём сами, а не берём из темы: col_cursor во многих темах
-- зелёно-бирюзовый и сливается с col_seltrack2 — активные кнопки и статус
-- монома становятся неразличимы. Тёплый акцент на холодном фоне читается
-- однозначно и в любой теме.
U.AMBER = readable({0.92, 0.52, 0.22}, U.BG, 3.0)
U.CYAN  = readable(theme('col_seltrack2', {0.42, 0.72, 0.78}), U.BG, 3.0)
U.GREEN = readable({0.36, 0.74, 0.50}, U.BG, 3.0)
U.RED   = readable({0.88, 0.32, 0.28}, U.BG, 3.0)
U.GREY  = mix(U.TEXT, U.BG, 0.35)     -- приглушённый текст, но ещё читаемый
U.PANEL = mix(U.BG, U.TEXT, 0.06)     -- фон панели чуть светлее окна
U.DIM   = mix(U.BG, U.TEXT, 0.30)     -- линии и неактивное
U.LINE  = mix(U.BG, U.TEXT, 0.42)     -- рамки
-- Экспорт для других окон экосистемы (jf_tracker): те же правила контраста,
-- без копий кода. Интерфейс старых вызовов не меняется.
U.theme, U.readable, U.contrast, U.mix = theme, readable, contrast, mix

-- Заливка «намёком»: цвет состояния, подмешанный к фону. Так подсветка
-- работает и на тёмной теме, и на светлой — в отличие от вписанных чисел.
function U.tint(c, amount)
  return mix(U.BG, c, amount or 0.22)
end

local function set(c, a) gfx.set(c[1], c[2], c[3], a or 1) end
U.set = set

-- 13 окт: слайдер-ромбик: тонкая дорожка, тонкая заливка (от центра или от края) и ромбик на значении
function U.dslider(sx, cy, sw, fr, centered, col, hot, rh)
  fr = math.max(0, math.min(1, fr or 0))
  local px = sx + math.floor(fr * (sw - 1) + 0.5)
  -- 15 окт: дорожка видна всегда (U.DIM терялся на тёмном фоне, у пана в центре заливки нет) — цветом ручки, приглушённо
  set(U.readable(U.mix(col, U.BG, 0.55), U.BG, 2.0)); gfx.rect(sx, cy, sw, 1, 1)
  local r = math.max(3, math.floor(((rh or 12) - 6) / 2))
  if centered then
    local mid = sx + math.floor(sw / 2)
    set(U.LINE); gfx.rect(mid, cy - r, 1, 2 * r + 1, 1)
    set(col, 0.6); gfx.rect(math.min(mid, px), cy - 1, math.max(1, math.abs(px - mid)), 3, 1)
  else set(col, 0.6); gfx.rect(sx, cy - 1, math.max(1, px - sx), 3, 1) end
  U.diamond(px, cy, r, col, hot)
end
-- 13 окт: ручка-ромбик (квадрат на угол): заливка цветом, обводка фоном и контуром текста —
-- видна издалека в любой теме. cx, cy — центр, r — полудиагональ
function U.diamond(cx, cy, r, col, hot)
  r = r or 5
  set(U.BG); gfx.triangle(cx, cy - r - 2, cx + r + 2, cy, cx, cy + r + 2, cx - r - 2, cy)
  set(hot and U.TEXT or col); gfx.triangle(cx, cy - r, cx + r, cy, cx, cy + r, cx - r, cy)
  set(hot and col or U.TEXT, 0.9)
  gfx.line(cx, cy - r - 1, cx + r + 1, cy); gfx.line(cx + r + 1, cy, cx, cy + r + 1); gfx.line(cx, cy + r + 1, cx - r - 1, cy); gfx.line(cx - r - 1, cy, cx, cy - r - 1)
end

-- Прямоугольник: прямые углы, линия в 1 px. Параметр r остался в сигнатуре
-- ради старых вызовов, но игнорируется — скруглений больше нет.
function U.frame(x, y, w, h, col, fill, r)
  if fill then set(fill); gfx.rect(x, y, w, h, 1) end
  set(col or U.LINE)
  gfx.rect(x, y, w, h, 0)
end

function U.text(x, y, s, col)
  if col then set(col) end
  gfx.x, gfx.y = math.floor(x), math.floor(y)
  gfx.drawstr(s)
end

-- курсор списка (10 окт, стандарт): одна полоса для всех списков — как в lib:
-- тонированный акцент, текст акцентом; читается в любой теме (mono, светлые).
-- Было в браузере: сплошная полоса цветом текста и текст цветом фона — при ×2
-- текст блитится аддитивно, тёмный на светлом пропадал. Возвращает цвет текста
function U.list_cursor(x, y, w, h, focused)
  set(U.tint(U.AMBER, focused and 0.30 or 0.14)); gfx.rect(x, y, w, h, 1)
  return focused and U.AMBER or U.TEXT
end
function U.textc(x, y, w, s, col)
  U.text(x + (w - gfx.measurestr(s)) / 2, y, s, col)
end

function U.textr(x, y, w, s, col)
  U.text(x + w - gfx.measurestr(s), y, s, col)
end

-- Панель: заголовок НАД рамкой, приглушённым цветом. Никаких врезок в линию.
function U.panel(x, y, w, h, title)
  if title then
    U.text(x + 1, y - gfx.texth - 6, title, U.DIM)
  end
  U.frame(x, y, w, h, U.LINE, U.PANEL)
end

-- Кнопка: рамка + текст. Активная — акцентный текст и подчёркивание снизу.
-- Под курсором подсвечивается фон, а не рамка: спокойнее при быстром движении.
U.mdown = false
function U.button(x, y, w, h, label, on, col)
  local hot = gfx.mouse_x >= x and gfx.mouse_x < x + w
          and gfx.mouse_y >= y and gfx.mouse_y < y + h
  local c = col or U.AMBER
  set(hot and mix(U.PANEL, U.TEXT, 0.10) or U.PANEL); gfx.rect(x, y, w, h, 1)
  set(on and c or U.LINE); gfx.rect(x, y, w, h, 0)
  U.textc(x, y + (h - gfx.texth)/2, w, label, on and c or (hot and U.TEXT or U.GREY))
  if on then
    set(c); gfx.rect(x + 1, y + h - 2, w - 2, 1, 1)
  end
  return hot and U.click
end

function U.numbtn(x, y, sz, n, on, col)
  return U.button(x, y, sz, sz, tostring(n), on, col)
end

-- Иконки типов: линиями, без картинок. Мельче и суше, чем было.
-- project — папка, loop — стрелка по кругу, reel — бабина, pack — стопка,
-- region — отрезок с засечками.
function U.icon(x, y, sz, kind, col)
  set(col or U.TEXT)
  local h = math.floor(sz / 2)
  if kind == 'reel' then
    gfx.circle(x + h, y + h, h - 2, 0, 1)
    gfx.circle(x + h, y + h, 1, 1, 1)
  elseif kind == 'loop' then
    gfx.arc(x + h, y + h, h - 2, -math.pi*0.6, math.pi)
    gfx.line(x + h - 1, y + 1, x + h + 2, y + 3)
    gfx.line(x + h - 1, y + 5, x + h + 2, y + 3)
  elseif kind == 'pack' then
    for k = 0, 2 do gfx.line(x + 2, y + 3 + k*4, x + sz - 3, y + 3 + k*4) end
  elseif kind == 'region' then
    gfx.line(x + 2, y + h, x + sz - 3, y + h)
    gfx.line(x + 2, y + 3, x + 2, y + sz - 4)
    gfx.line(x + sz - 3, y + 3, x + sz - 3, y + sz - 4)
  else -- project: папка
    gfx.line(x + 2, y + 4, x + h, y + 4)
    gfx.line(x + h, y + 4, x + h + 2, y + 6)
    gfx.rect(x + 2, y + 6, sz - 5, sz - 10, 0)
  end
end

-- Разделитель: одна линия. Нужен вместо рамок там, где рамка была бы шумом.
function U.rule(x, y, w)
  set(U.DIM); gfx.rect(x, y, w, 1, 1)
end

function U.begin_frame()
  U.click  = gfx.mouse_cap & 1 == 1 and not U.mdown
  U.rclick = gfx.mouse_cap & 2 == 2 and not U.rdown
  set(U.BG); gfx.rect(0, 0, gfx.w, gfx.h, 1)
end

function U.end_frame()
  U.mdown = gfx.mouse_cap & 1 == 1
  U.rdown = gfx.mouse_cap & 2 == 2
end

return U
