-- jf_tracker_notes.lua — текстовый редактор заметок (2 окт).
--
-- На месте списка эффектов (слева от DSP), кнопка «notes» в контроле.
-- Цели: project — заметки проекта, context — заметки item под курсором
-- трекера (или трека, если item нет). Чтение и запись делает main (ctx).
--
-- Клавиши (фокус на заметках): буквы — текст, Enter — новая строка, BS /
-- Del — стереть, стрелки — курсор, Home / End — начало / конец строки,
-- Esc / Tab — выйти (main записывает текст). Строки переносятся по ширине.
--
-- Без reaper.*: тестируется стабами.

local NT = {}
NT.lines = { '' }
NT.l, NT.c = 1, 0          -- курсор: строка, символ (0 — перед первым)
NT.scroll = 0
NT.dirty = false
NT.target = 'project'      -- 'project' | 'context'

local LEFT, RIGHT, UP, DOWN, HOME, END, DEL = 1818584692, 1919379572, 30064, 1685026670, 1752132965, 6647396, 6579564

function NT.set(text)
  NT.lines = {}
  for ln in ((text or '') .. '\n'):gmatch('(.-)\r?\n') do NT.lines[#NT.lines + 1] = ln end
  if #NT.lines == 0 then NT.lines = { '' } end
  NT.l, NT.c, NT.scroll, NT.dirty = 1, 0, 0, false
end

function NT.text() return table.concat(NT.lines, '\n') end

local function clamp()
  if NT.l < 1 then NT.l = 1 elseif NT.l > #NT.lines then NT.l = #NT.lines end
  local n = #NT.lines[NT.l]
  if NT.c < 0 then NT.c = 0 elseif NT.c > n then NT.c = n end
end

-- 'leave' — выйти из редактора; true — съедено; false — не наше
function NT.key(c)
  local s = NT.lines[NT.l]
  if c == 27 or c == 9 then return 'leave'
  elseif c == 13 then
    table.insert(NT.lines, NT.l + 1, s:sub(NT.c + 1)); NT.lines[NT.l] = s:sub(1, NT.c)
    NT.l, NT.c = NT.l + 1, 0; NT.dirty = true
  elseif c == 8 then
    if NT.c > 0 then NT.lines[NT.l] = s:sub(1, NT.c - 1) .. s:sub(NT.c + 1); NT.c = NT.c - 1
    elseif NT.l > 1 then
      local prev = NT.lines[NT.l - 1]
      NT.c = #prev; NT.lines[NT.l - 1] = prev .. s; table.remove(NT.lines, NT.l); NT.l = NT.l - 1
    end
    NT.dirty = true
  elseif c == DEL then
    if NT.c < #s then NT.lines[NT.l] = s:sub(1, NT.c) .. s:sub(NT.c + 2)
    elseif NT.l < #NT.lines then NT.lines[NT.l] = s .. NT.lines[NT.l + 1]; table.remove(NT.lines, NT.l + 1) end
    NT.dirty = true
  elseif c == LEFT then if NT.c > 0 then NT.c = NT.c - 1 elseif NT.l > 1 then NT.l = NT.l - 1; NT.c = #NT.lines[NT.l] end
  elseif c == RIGHT then if NT.c < #s then NT.c = NT.c + 1 elseif NT.l < #NT.lines then NT.l = NT.l + 1; NT.c = 0 end
  elseif c == UP then NT.l = NT.l - 1; clamp()
  elseif c == DOWN then NT.l = NT.l + 1; clamp()
  elseif c == HOME then NT.c = 0
  elseif c == END then NT.c = #s
  elseif c >= 32 and c <= 126 then
    NT.lines[NT.l] = s:sub(1, NT.c) .. string.char(c) .. s:sub(NT.c + 1); NT.c = NT.c + 1; NT.dirty = true
  elseif c > 126 and c < 0x110000 and utf8 then
    local ch = utf8.char(c)
    NT.lines[NT.l] = s:sub(1, NT.c) .. ch .. s:sub(NT.c + 1); NT.c = NT.c + #ch; NT.dirty = true
  else return false end
  clamp()
  return true
end

-- отрисовка в (x, y, w, h); title — чьи заметки; focused — курсор виден.
-- Возвращает hover: 'project' | 'context' (кнопки цели) | 'text'
function NT.draw(U, L, x, y, w, h, focused, fit, title)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local hover
  U.set(U.PANEL); gfx.rect(x, y, w, h, 1)
  U.set(U.LINE); gfx.rect(x + w - 1, y, 1, h, 1)
  -- шапка: [project] [context] и чьи заметки
  local bx = x + L.pad
  for _, t in ipairs({ 'project', 'context' }) do
    local bw = U.measure(t) + 2 * L.pad
    local on = NT.target == t
    local hot = mx >= bx and mx < bx + bw and my >= y + 2 and my < y + 2 + L.rh
    U.set(hot and U.tint(U.AMBER, 0.3) or (on and U.tint(U.AMBER, 0.15) or U.BG)); gfx.rect(bx, y + 2, bw, L.rh, 1)
    U.set(on and U.AMBER or U.LINE); gfx.rect(bx, y + 2, bw, L.rh, 0)
    U.text(bx + L.pad, y + 3, t, on and U.AMBER or (hot and U.TEXT or U.GREY))
    if hot then hover = t end
    bx = bx + bw + L.pad
  end
  U.text(bx, y + 3, fit((title or '') .. (NT.dirty and ' *' or ''), x + w - L.pad - bx), U.GREY)
  -- текст с переносом по ширине
  local top = y + L.rh + 6
  local cw = U.measure('W')
  local cols = math.max(4, math.floor((w - 2 * L.pad) / math.max(1, cw)))
  local vis = {}                         -- { l =, c0 = } визуальные строки
  local cur_v = 1
  for li, s in ipairs(NT.lines) do
    local n = math.max(1, math.ceil(#s / cols))
    if #s > 0 and #s % cols == 0 then n = n + 0 end
    for k = 0, n - 1 do
      vis[#vis + 1] = { l = li, c0 = k * cols }
      if li == NT.l and NT.c >= k * cols and (NT.c < (k + 1) * cols or k == n - 1) then cur_v = #vis end
    end
  end
  local nvis = math.max(1, math.floor((y + h - top - 2) / L.rh))
  if cur_v - 1 < NT.scroll then NT.scroll = cur_v - 1 end
  if cur_v - 1 >= NT.scroll + nvis then NT.scroll = cur_v - nvis end
  for i = 1, nvis do
    local v = vis[NT.scroll + i]
    if not v then break end
    local ry = top + (i - 1) * L.rh
    local s = NT.lines[v.l]:sub(v.c0 + 1, v.c0 + cols)
    U.text(x + L.pad, ry + 1, s, U.TEXT)
    if focused and NT.scroll + i == cur_v then
      local cx = x + L.pad + U.measure(NT.lines[v.l]:sub(v.c0 + 1, NT.c))
      U.set(U.AMBER); gfx.rect(cx, ry + 1, 2, L.rh - 2, 1)
    end
  end
  if NT.lines[1] == '' and #NT.lines == 1 and not focused then U.text(x + L.pad, top + 1, 'click to write notes', U.DIM) end
  if not hover and mx >= x and mx < x + w and my >= top and my < y + h then hover = 'text' end
  return hover
end

return NT
