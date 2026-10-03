-- jf_tracker_ask.lua — маленький вопрос посреди окна (3 окт).
--
-- A.open(title, text, choices): choices = { { key = 'u', label = …, fn = … }, … };
-- первый — по умолчанию: Enter, Esc и клик мимо окна выбирают его. Клавиша
-- выбора или клик по строке — свой. Пока открыт, клавиши и мышь идут сюда
-- (main перехватывает раньше всего, как окно опций). Без reaper.*: gfx и U.

local A = { active = false, choices = {}, hover = nil }
local U, ctx

function A.init(u, c) U, ctx = u, c end

function A.open(title, text, choices)
  A.title, A.text, A.choices = title or '', text or '', choices or {}
  A.active = #A.choices > 0
end

local function pick(i)
  local ch = A.choices[i]
  A.active = false
  if ch and ch.fn then ch.fn() end
end

function A.key(c)
  if c == 13 or c == 27 then pick(1); return true end
  local s = c > 0 and c < 256 and string.char(c) or ''
  for i, ch in ipairs(A.choices) do if ch.key == s then pick(i); return true end end
  return true
end

function A.click()
  if A.hover then pick(A.hover) else pick(1) end
end

function A.draw(L, W, H)
  if not A.active then return end
  local rh = L.rh
  local lines = { A.title, A.text }
  local bw = 0
  for _, l in ipairs(lines) do bw = math.max(bw, U.measure(l)) end
  for _, ch in ipairs(A.choices) do bw = math.max(bw, U.measure(('[%s] %s'):format(ch.key, ch.label))) end
  bw = math.min(W - 40, bw + 4 * L.pad)
  local bh = (2 + #A.choices) * rh + 3 * L.pad
  local bx, by = math.floor((W - bw) / 2), math.floor((H - bh) / 2)
  U.set(U.BG); gfx.rect(bx, by, bw, bh, 1)
  U.set(U.AMBER); gfx.rect(bx, by, bw, bh, 0)
  U.text(bx + L.pad, by + L.pad, ctx.fit(A.title, bw - 2 * L.pad), U.AMBER)
  U.text(bx + L.pad, by + L.pad + rh, ctx.fit(A.text, bw - 2 * L.pad), U.GREY)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  A.hover = nil
  for i, ch in ipairs(A.choices) do
    local y = by + 2 * L.pad + (1 + i) * rh
    local hot = mx >= bx and mx < bx + bw and my >= y and my < y + rh
    if hot then A.hover = i end
    if hot or i == 1 then U.set(U.tint(U.AMBER, hot and 0.3 or 0.15)); gfx.rect(bx + 1, y, bw - 2, rh, 1) end
    U.text(bx + L.pad, y, ctx.fit(('[%s] %s%s'):format(ch.key, ch.label, i == 1 and '  (Enter)' or ''), bw - 2 * L.pad), i == 1 and U.TEXT or U.GREY)
  end
end

return A
