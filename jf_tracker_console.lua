-- jf_tracker_console.lua — консоль: живой язык паттернов (Strudel) в трекере (28 окт; тест tests/test_console.lua).
--
-- Строка — канал: «t2: n("c e g").fast(2).cmd("0R42")» — трек 2 (порядок колонок трекера); без «tN:» — трек курсора.
-- Enter — оценить строку под курсором: ноты пишутся в паттерн курсора на этот трек (трек в паттерне переписывается
-- целиком); «t2: ~» / «hush» — снять. Цикл = такт: паттерн из N тактов получает циклы 0..N-1.
-- Редактор — по образцу jf_tracker_notes (строки, курсор, перенос); история ответов над строками.
-- Без reaper / gfx в разборе и плане: C.plan(line, bars, rows_per_bar) → { track_n, clear, events = { … } }.
local DIR = (debug.getinfo(1, 'S').source:match('^@(.*/)') or './')
local MN = dofile(DIR .. 'jf_tracker_mini.lua')
local TX = dofile(DIR .. 'jf_tracker_utf8.lua')
local C = {}

C.lines = { '' }
C.l, C.c = 1, 0
C.scroll = 0
C.log = {}            -- история ответов { text, err }
C.LOG_MAX = 200
C.hist = {}           -- оценённые строки (Up / Down в пустой строке)
C.hpos = nil
C.err = {}            -- [номер строки] = текст ошибки
C.chan = {}           -- [track_n] = строка, что сейчас звучит (для переписи и сохранения)

local LEFT, RIGHT, UP, DOWN, HOME, END, DEL = 1818584692, 1919379572, 30064, 1685026670, 1752132965, 6647396, 6579564

-- ── разбор строки ─────────────────────────────────────────────────────────
-- «t2: …» → 2, '…'; без префикса → nil, строка; пустая / ~ / hush → clear
function C.split(line)
  local s = (line or ''):gsub('^%s+', ''):gsub('%s+$', '')
  local n, rest = s:match('^t(%d+)%s*:%s*(.*)$')
  if n then return tonumber(n), rest end
  return nil, s
end

-- план записи: события в строках паттерна (row_f — дробная строка от начала паттерна)
-- opts: { base = MIDI-нота C-4 инструмента (60), oct = 4, vel = 0..1 → 1..127 }
function C.plan(line, bars, rpb, opts)
  opts = opts or {}
  local n, expr = C.split(line)
  if expr == 'help' or expr == '?' then return { help = true, events = {} } end
  if expr == '' or expr == '~' or expr == 'hush' then return { track_n = n, clear = true, all = expr == 'hush', events = {} } end
  local events = {}
  local nb = math.max(1, math.floor(bars or 1))
  for cyc = 0, nb - 1 do
    local evs = MN.query(expr, cyc, { base = opts.base or 60, oct = opts.oct or 4, vel = opts.vel or 0.8 })
    for _, e in ipairs(evs) do
      if e.pitch or e.slice then
        events[#events + 1] = {
          row_f = (cyc + e.s) * rpb, len_rows = math.max(1e-6, (e.e - e.s) * rpb),
          pitch = e.pitch, slice = e.slice, inst = e.inst, cmd = e.cmd,
          vel = math.max(1, math.min(127, math.floor((e.vel or 0.8) * 127 + 0.5))),
        }
      end
    end
  end
  return { track_n = n, clear = false, events = events }
end

-- 29 окт: справка консоли — `help` или `?` (строки в журнал)
C.HELP = {
  'console: Strudel patterns written into the pattern at the cursor',
  '  t2: n("c e g b")        notes on track 2 (REAPER number); no t2: - the cursor track',
  '  n("c [e g] <a b>")      space steps, [ ] subdivide, , chord, < > one per bar, ~ rest',
  '  n("c*4")  c/2  c!3  c@3  c?  c(3,8)   faster, slower, repeat, weight, sometimes, euclid',
  '  .fast(2) .slow(2) .rev() .every(4, "rev") .add(7) .oct(-1)   transform',
  '  s("1 3 ~ 5")            slices of the instrument (slixer: base note + n - 1)',
  '  .vel("1 0.5")  .cmd("0R42")  .i(3)    velocity, tracker command, lib instrument',
  '  t2: ~   hush            clear the track / every channel in the pattern',
  '  Enter line, Cmd+Enter all lines, Shift+Enter new line, Up Down history, Esc back',
}
-- ── редактор ──────────────────────────────────────────────────────────────
local function clamp()
  if C.l < 1 then C.l = 1 elseif C.l > #C.lines then C.l = #C.lines end
  local s = C.lines[C.l]
  if C.c < 0 then C.c = 0 elseif C.c > #s then C.c = #s end
end
function C.set(text)
  C.lines = {}
  for ln in ((text or '') .. '\n'):gmatch('(.-)\r?\n') do C.lines[#C.lines + 1] = ln end
  if #C.lines == 0 then C.lines = { '' } end
  C.l, C.c = #C.lines, #C.lines[#C.lines]
  clamp()
end
function C.text() return table.concat(C.lines, '\n') end
function C.say(text, err)
  C.log[#C.log + 1] = { text = text, err = err or nil }
  while #C.log > C.LOG_MAX do table.remove(C.log, 1) end
end
function C.push_hist(line)
  for i = #C.hist, 1, -1 do if C.hist[i] == line then table.remove(C.hist, i) end end
  C.hist[#C.hist + 1] = line
  while #C.hist > 100 do table.remove(C.hist, 1) end
  C.hpos = nil
end

-- клавиши: → 'leave' (Esc), 'eval' (Enter — строка под курсором), 'evalall' (Cmd+Enter), true / false
function C.key(c, mods)
  mods = mods or {}
  local s = C.lines[C.l]
  if c == 27 then return 'leave'
  elseif c == 13 then
    if mods.cmd then return 'evalall' end
    if mods.shift then   -- Shift+Enter — новая строка
      table.insert(C.lines, C.l + 1, s:sub(C.c + 1)); C.lines[C.l] = s:sub(1, C.c); C.l, C.c = C.l + 1, 0
      return true
    end
    return 'eval'
  elseif c == 8 then
    if C.c > 0 then local head = TX.bs(s:sub(1, C.c)); C.lines[C.l] = head .. s:sub(C.c + 1); C.c = #head
    elseif C.l > 1 then local prev = C.lines[C.l - 1]; C.c = #prev; C.lines[C.l - 1] = prev .. s; table.remove(C.lines, C.l); C.l = C.l - 1 end
  elseif c == DEL then
    if C.c < #s then C.lines[C.l] = s:sub(1, C.c) .. s:sub(C.c + 2)
    elseif C.l < #C.lines then C.lines[C.l] = s .. C.lines[C.l + 1]; table.remove(C.lines, C.l + 1) end
  elseif c == LEFT then if C.c > 0 then C.c = C.c - 1 elseif C.l > 1 then C.l = C.l - 1; C.c = #C.lines[C.l] end
  elseif c == RIGHT then if C.c < #s then C.c = C.c + 1 elseif C.l < #C.lines then C.l = C.l + 1; C.c = 0 end
  elseif c == UP or c == DOWN then
    if s == '' and #C.hist > 0 then   -- история в пустой строке
      if c == UP then C.hpos = (C.hpos or #C.hist + 1) - 1 else C.hpos = (C.hpos or #C.hist) + 1 end
      if C.hpos < 1 then C.hpos = 1 end
      if C.hpos > #C.hist then C.hpos = nil; C.lines[C.l] = ''; C.c = 0
      else C.lines[C.l] = C.hist[C.hpos]; C.c = #C.lines[C.l] end
    elseif C.hpos and (c == UP or c == DOWN) then
      C.hpos = C.hpos + (c == UP and -1 or 1)
      if C.hpos < 1 then C.hpos = 1 end
      if C.hpos > #C.hist then C.hpos = nil; C.lines[C.l] = ''; C.c = 0
      else C.lines[C.l] = C.hist[C.hpos]; C.c = #C.lines[C.l] end
    else C.l = C.l + (c == UP and -1 or 1) end
  elseif c == HOME then C.c = 0
  elseif c == END then C.c = #s
  elseif c >= 32 and c <= 126 then C.lines[C.l] = s:sub(1, C.c) .. string.char(c) .. s:sub(C.c + 1); C.c = C.c + 1; C.hpos = nil
  elseif ((c >= 0x75000000 and c < 0x76000000) or (c > 126 and c < 0x110000)) and utf8 then
    local ch = utf8.char(c >= 0x75000000 and (c - 0x75000000) or c)
    C.lines[C.l] = s:sub(1, C.c) .. ch .. s:sub(C.c + 1); C.c = C.c + #ch
  else return false end
  clamp()
  return true
end

-- раскраска: ключ по байту — CHAN (tN:), STR (в кавычках), FN (.func), NUM, TEXT
function C.style(s)
  local st = {}
  local i = 1
  local n0, n1 = s:find('^%s*t%d+%s*:')
  if n0 then for q = n0, n1 do st[q] = 'CHAN' end; i = n1 + 1 end
  local inq
  while i <= #s do
    local ch = s:sub(i, i)
    if inq then st[i] = 'STR'; if ch == inq then inq = nil end
    elseif ch == '"' or ch == "'" then inq = ch; st[i] = 'STR'
    elseif ch == '.' and s:sub(i + 1, i + 1):match('%a') then
      local j = i + 1
      while j <= #s and s:sub(j, j):match('%a') do j = j + 1 end
      for q = i, j - 1 do st[q] = 'FN' end
      i = j - 1
    elseif ch:match('[%d%-]') and not st[i] then st[i] = 'NUM'
    else st[i] = st[i] or 'TEXT' end
    i = i + 1
  end
  return st
end

-- ── отрисовка (x, y, w, h): журнал сверху, строки внизу; → hover 'text' | nil
function C.draw(U, L, x, y, w, h, focused, fit)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local hover
  U.set(U.BG); gfx.rect(x, y, w, h, 1)
  local cw = U.measure('W')
  local cols = math.max(8, math.floor((w - 2 * L.pad) / math.max(1, cw)))
  local nl = #C.lines
  local eh = math.min(h - 2 * L.rh, (nl + 1) * L.rh + 4)   -- поле ввода: строки + строка ошибки
  local ey = y + h - eh
  U.set(U.LINE); gfx.rect(x, ey - 1, w, 1, 1)
  -- журнал: с конца, снизу вверх над полем
  local ly = ey - 2 - L.rh
  local shown = 0
  for i = #C.log - C.scroll, 1, -1 do
    local e = C.log[i]
    if ly < y then break end
    U.text(x + L.pad, ly, fit(e.text, w - 2 * L.pad), e.err and U.RED or U.GREY)
    ly = ly - L.rh; shown = shown + 1
  end
  if gfx.mouse_wheel ~= 0 and mx >= x and mx < x + w and my >= y and my < ey then
    C.scroll = math.max(0, math.min(math.max(0, #C.log - shown), C.scroll + (gfx.mouse_wheel > 0 and 3 or -3))); gfx.mouse_wheel = 0
  end
  -- строки ввода
  local COL = { CHAN = U.GREEN, STR = U.AMBER, FN = U.CYAN, NUM = U.TEXT, TEXT = U.TEXT }
  local ry = ey + 2
  local first = math.max(1, nl - math.floor((eh - L.rh - 4) / L.rh) + 1)
  if C.l < first then first = C.l end
  for li = first, nl do
    if ry + L.rh > y + h - L.rh then break end
    local line = C.lines[li]
    local s = line:sub(1, cols)
    local st = C.style(line)
    local i0, px = 1, x + L.pad
    if li == C.l and focused then U.set(U.tint(U.AMBER, 0.08)); gfx.rect(x, ry, w, L.rh, 1) end
    while i0 <= #s do
      local k = st[i0] or 'TEXT'
      local i1 = i0
      while i1 < #s and (st[i1 + 1] or 'TEXT') == k do i1 = i1 + 1 end
      local part = s:sub(i0, i1)
      U.text(px, ry + 1, part, COL[k] or U.TEXT)
      px = px + U.measure(part)
      i0 = i1 + 1
    end
    if focused and li == C.l then
      local cx = x + L.pad + U.measure(line:sub(1, math.min(C.c, cols)))
      U.set(U.AMBER); gfx.rect(cx, ry + 1, 2, L.rh - 2, 1)
    end
    if C.err[li] then
      ry = ry + L.rh
      if ry + L.rh <= y + h then U.text(x + L.pad, ry + 1, fit('  ' .. C.err[li], w - 2 * L.pad), U.RED) end
    end
    ry = ry + L.rh
  end
  -- 29 окт: пустой журнал — коротко, что это и как (help — всё)
  if #C.log == 0 then
    local hy = y + 2
    for i, h in ipairs(C.HELP) do
      if hy + L.rh > ey - 2 then break end
      U.text(x + L.pad, hy, fit(h, w - 2 * L.pad), i == 1 and U.GREY or U.DIM); hy = hy + L.rh
    end
  end
  if nl == 1 and C.lines[1] == '' and not focused then U.text(x + L.pad, ey + 3, 't1: n("c e g b")   Enter - write it, help - all of it, Esc - back', U.DIM) end
  if mx >= x and mx < x + w and my >= y and my < y + h then hover = my >= ey and 'text' or 'log' end
  return hover
end

return C
