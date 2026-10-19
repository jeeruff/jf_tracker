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
-- Markdown (4 окт): текст остаётся как есть (курсор по символам), а
-- раскраска — по разметке: # заголовки, - [ ] / - [x] задачи (клик по
-- коробке переключает), - списки, > цитаты, `код`, **жирный**. Коробки
-- задач — интерактивные: hover 'todo:<строка>', NT.toggle(l).
--
-- Без reaper.*: тестируется стабами.

local NT = {}
NT.lines = { '' }
NT.l, NT.c = 1, 0          -- курсор: строка, символ (0 — перед первым)
NT.scroll = 0
NT.dirty = false
NT.target = 'project'      -- 'project' | 'context' | 'dev' (CHECK.md, с debug)
NT.code = false            -- 11 окт: редактор кода (Video processor в DSP): без целей и Markdown, Tab — отступ, // — серым

local LEFT, RIGHT, UP, DOWN, HOME, END, DEL = 1818584692, 1919379572, 30064, 1685026670, 1752132965, 6647396, 6579564

function NT.set(text)
  NT.lines = {}
  for ln in ((text or '') .. '\n'):gmatch('(.-)\r?\n') do NT.lines[#NT.lines + 1] = ln end
  if #NT.lines == 0 then NT.lines = { '' } end
  NT.l, NT.c, NT.scroll, NT.dirty = 1, 0, 0, false
end

function NT.text() return table.concat(NT.lines, '\n') end

-- задача в строке: позиция «[» коробки и отмечена ли; nil — не задача
function NT.todo(s)
  local pre, mark = s:match('^(%s*[-*+]%s+)%[([ xX])%]')
  if not pre then return nil end
  return #pre + 1, mark ~= ' '
end
-- переключить коробку строки l: [ ] ↔ [x]
function NT.toggle(l)
  local s = NT.lines[l]
  if not s then return false end
  local at, done = NT.todo(s)          -- не «s and NT.todo(s)»: and режет второе значение
  if not at then return false end
  NT.lines[l] = s:sub(1, at) .. (done and ' ' or 'x') .. s:sub(at + 2)
  NT.dirty = true
  return true
end
-- раскраска строки: массив ключей цвета на каждый байт (TEXT, HEAD1, HEAD2,
-- DONE, MARK, CODE, BOLD, QUOTE) — отрисовка режет по визуальным строкам
function NT.style(s)
  local st = {}
  local function fill(a, b, k) for i = a, b do st[i] = k end end
  fill(1, #s, 'TEXT')
  local h = s:match('^(#+)%s')
  if h then fill(1, #s, #h == 1 and 'HEAD1' or 'HEAD2'); return st end
  if s:match('^%s*>') then fill(1, #s, 'QUOTE'); return st end
  local at, done = NT.todo(s)
  if at then
    if done then fill(at + 3, #s, 'DONE') end
    fill(1, at + 2, 'MARK')
  else
    local b = s:match('^(%s*[-*+]%s)') or s:match('^(%s*%d+[.)]%s)')
    if b then fill(1, #b, 'MARK') end
  end
  for a, b in s:gmatch('()`[^`]+`()') do fill(a, b - 1, 'CODE') end
  for a, b in s:gmatch('()%*%*[^*]+%*%*()') do fill(a, b - 1, 'BOLD') end
  return st
end

local function clamp()
  if NT.l < 1 then NT.l = 1 elseif NT.l > #NT.lines then NT.l = #NT.lines end
  local n = #NT.lines[NT.l]
  if NT.c < 0 then NT.c = 0 elseif NT.c > n then NT.c = n end
end

-- 'leave' — выйти из редактора; true — съедено; false — не наше
function NT.key(c)
  local s = NT.lines[NT.l]
  if c == 27 or (c == 9 and not NT.code) then return 'leave'
  elseif c == 9 then NT.lines[NT.l] = s:sub(1, NT.c) .. '  ' .. s:sub(NT.c + 1); NT.c = NT.c + 2; NT.dirty = true
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
  for _, t in ipairs(NT.code and {} or NT.show_dev and { 'project', 'context', 'dev' } or { 'project', 'context' }) do   -- dev — только в режиме debug (8 окт)
    local bw = U.measure(t) + 2 * L.pad
    local on = NT.target == t
    local hot = mx >= bx and mx < bx + bw and my >= y + 2 and my < y + 2 + L.rh
    U.set(hot and U.tint(U.AMBER, 0.3) or (on and U.tint(U.AMBER, 0.15) or U.BG)); gfx.rect(bx, y + 2, bw, L.rh, 1)
    U.set(on and U.AMBER or U.LINE); gfx.rect(bx, y + 2, bw, L.rh, 0)
    U.text(bx + L.pad, y + 3, t, on and U.AMBER or (hot and U.TEXT or U.GREY))
    if hot then hover = t end
    bx = bx + bw + L.pad
  end
  -- − + (4 окт): размер текста заметок — справа в шапке
  local zw = U.measure('+') + 2 * L.pad
  local zx = x + w - L.pad - 2 * zw - 2
  for i, z in ipairs(NT.code and {} or { { '-', 'zoom-' }, { '+', 'zoom+' } }) do
    local kx = zx + (i - 1) * (zw + 2)
    local hot = mx >= kx and mx < kx + zw and my >= y + 2 and my < y + 2 + L.rh
    U.set(hot and U.tint(U.AMBER, 0.3) or U.BG); gfx.rect(kx, y + 2, zw, L.rh, 1)
    U.set(hot and U.AMBER or U.LINE); gfx.rect(kx, y + 2, zw, L.rh, 0)
    U.text(kx + L.pad, y + 3, z[1], hot and U.AMBER or U.GREY)
    if hot then hover = z[2] end
  end
  U.text(bx, y + 3, fit((title or '') .. (NT.dirty and ' *' or ''), zx - L.pad - bx), U.GREY)
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
  -- 19 окт: за курсором — только когда он сдвинулся (иначе полоса и колесо не листали: прокрутку возвращало к курсору)
  local ck = NT.l .. ':' .. NT.c .. ':' .. #vis
  if NT.cur_key ~= ck then
    NT.cur_key = ck
    if cur_v - 1 < NT.scroll then NT.scroll = cur_v - 1 end
    if cur_v - 1 >= NT.scroll + nvis then NT.scroll = cur_v - nvis end
  end
  -- колесо над заметками — 3 строки
  if gfx.mouse_wheel ~= 0 and mx >= x and mx < x + w and my >= top and my < top + nvis * L.rh then
    NT.scroll = NT.scroll + (gfx.mouse_wheel > 0 and -3 or 3); gfx.mouse_wheel = 0
  end
  NT.scroll = math.max(0, math.min(math.max(0, #vis - nvis), NT.scroll))
  if U.vbar then U.vbar('notes', x, top, w, nvis * L.rh, NT.scroll, nvis, #vis) end   -- 15 окт: полоса всегда
  for i = 1, nvis do
    local v = vis[NT.scroll + i]
    if not v then break end
    local ry = top + (i - 1) * L.rh
    local line = NT.lines[v.l]
    local s = line:sub(v.c0 + 1, v.c0 + cols)
    -- раскраска Markdown: куски одного цвета подряд
    local st
    if NT.code then   -- код: комментарий // — серым, остальное текстом
      st = {}; local cm = line:find('//', 1, true); if cm then for q = cm, #line do st[q] = 'MARK' end end
    else st = NT.style(line) end
    local COL = { TEXT = U.TEXT, HEAD1 = U.AMBER, HEAD2 = U.CYAN, DONE = U.DIM, MARK = U.GREY,
                  CODE = U.CYAN, BOLD = U.AMBER, QUOTE = U.GREY }
    local i0, px = 1, x + L.pad
    while i0 <= #s do
      local k = st[v.c0 + i0] or 'TEXT'
      local i1 = i0
      while i1 < #s and (st[v.c0 + i1 + 1] or 'TEXT') == k do i1 = i1 + 1 end
      local part = s:sub(i0, i1)
      U.text(px, ry + 1, part, COL[k] or U.TEXT)
      px = px + U.measure(part)
      i0 = i1 + 1
    end
    -- коробка задачи — буквами «[ ]» / «[x]» (никаких значков): отмеченная
    -- зелёная, под мышью — янтарная подложка; клик — переключить
    local at, done
    if not NT.code then at, done = NT.todo(line) end
    if at and at > v.c0 and at + 2 <= v.c0 + cols then
      local bx0 = x + L.pad + U.measure(s:sub(1, at - v.c0 - 1))
      local box = line:sub(at, at + 2)
      local bw0 = U.measure(box)
      local hot = mx >= bx0 - 2 and mx < bx0 + bw0 + 2 and my >= ry and my < ry + L.rh
      U.set(hot and U.tint(U.AMBER, 0.35) or U.PANEL); gfx.rect(bx0 - 1, ry, bw0 + 2, L.rh, 1)
      U.text(bx0, ry + 1, box, done and U.GREEN or (hot and U.AMBER or U.TEXT))
      if hot then hover = 'todo:' .. v.l end
    end
    if focused and NT.scroll + i == cur_v then
      local cx = x + L.pad + U.measure(NT.lines[v.l]:sub(v.c0 + 1, NT.c))
      U.set(U.AMBER); gfx.rect(cx, ry + 1, 2, L.rh - 2, 1)
    end
  end
  if not NT.code and NT.lines[1] == '' and #NT.lines == 1 and not focused then U.text(x + L.pad, top + 1, 'click to write notes', U.DIM) end
  if not hover and mx >= x and mx < x + w and my >= top and my < y + h then hover = 'text' end
  return hover
end

return NT
