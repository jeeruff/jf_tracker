-- jf_tracker_smart.lua — смарт-панель (9 окт, как Smart Select в PlayerPro /
-- Paketti): у ячейки курсора всплывает сетка значений того поля, где стоит
-- курсор — ноты (октавы × 12), громкость, задержка, команда (сперва буква,
-- потом значение), инструмент, точка огибающей / CC. Выбор мышью (наведение +
-- щелчок) или h j k l + Enter; Esc, щелчок мимо или ПКМ — закрыть.
--
-- Что показать и что делать при выборе, решает вызывающий (vim: V.smart):
-- SM.open{ title, items = { {label, v, tip, on}, … }, cols, sel, on_pick(it) }
-- on_pick может вернуть следующую сетку (буква команды → её значения).
-- 10 окт: p.cell_w (px) и p.cell_rows (высота ячейки в строках) — для превью;
-- it.draw(x, y, w, h, sel) рисует ячейку сам (шрифт своим шрифтом, тема цветами)
-- Без reaper.* — тест tests/test_smart.lua.

local SM = { p = nil, rect = nil, hot = nil }
-- 11 окт: listen (кнопка внизу, по умолчанию вкл) — смена выбора звучит: p.on_sel(it) у вызывающего
SM.listen = true
SM.on_listen = nil      -- main: запомнить вкл / выкл
local function notify(p, i)
  if not (SM.listen and p and p.on_sel) then return end
  local it = p.items[i]
  if it then pcall(p.on_sel, it) end
end

function SM.active() return SM.p ~= nil end
function SM.close() SM.p, SM.rect, SM.hot, SM.hot_prev = nil, nil, nil, nil end

function SM.open(p, anchor)
  if not p or not p.items or #p.items == 0 then SM.close(); return false end
  p.cols = math.max(1, math.min(p.cols or 16, #p.items))
  p.sel = math.max(1, math.min(#p.items, p.sel or 1))
  if anchor then p.anchor = anchor elseif SM.p then p.anchor = SM.p.anchor end
  SM.p, SM.hot = p, nil
  return true
end

local function pick(i)
  local p = SM.p
  local it = p and p.items[i]
  if not it then return end
  local nxt = p.on_pick and p.on_pick(it)
  if type(nxt) == 'table' then SM.open(nxt) else SM.close() end
end

-- клавиши; true — съели
local ESC, ENTER, UP, DOWN, LEFT, RIGHT = 27, 13, 30064, 1685026670, 1818584692, 1919379572
function SM.key(c)
  local p = SM.p
  if not p then return false end
  local n, cols = #p.items, p.cols
  local s0 = p.sel
  local r = SM.key_in(c, p, n, cols)
  if SM.p == p and p.sel ~= s0 then notify(p, p.sel) end
  return r
end
function SM.key_in(c, p, n, cols)
  local ch = c > 0 and c < 256 and string.char(c) or ''
  if c == ESC or ch == 'q' then SM.close()
  elseif c == ENTER or ch == ' ' then pick(p.sel)
  elseif ch == 'h' or c == LEFT then p.sel = math.max(1, p.sel - 1)
  elseif ch == 'l' or c == RIGHT then p.sel = math.min(n, p.sel + 1)
  elseif ch == 'k' or c == UP then if p.sel - cols >= 1 then p.sel = p.sel - cols end
  elseif ch == 'j' or c == DOWN then if p.sel + cols <= n then p.sel = p.sel + cols end
  elseif ch == '0' or ch == '^' then p.sel = p.sel - (p.sel - 1) % cols
  elseif ch == '$' then p.sel = math.min(n, p.sel - (p.sel - 1) % cols + cols - 1)
  elseif ch == 'g' then p.sel = 1
  elseif ch == 'G' then p.sel = n
  end
  return true                                 -- пока открыта — все клавиши её
end

-- геометрия: ячейка = самая широкая подпись + поля; сетка у anchor (под
-- ячейкой, не влезает — над ней), целиком в окне
function SM.layout(L, ms, W, H)
  local p = SM.p
  local cw = 0
  for _, it in ipairs(p.items) do cw = math.max(cw, ms(it.label)) end
  cw = p.cell_w or (cw + 2 * L.pad)
  local crh = (p.cell_rows or 1) * L.rh
  local rows = math.ceil(#p.items / p.cols)
  local w = p.cols * cw + 2 * L.pad
  local tw = ms(p.title or '') + 2 * L.pad
  if w < tw then cw = cw + math.ceil((tw - w) / p.cols); w = p.cols * cw + 2 * L.pad end
  local h = rows * crh + 2 * L.rh + 2 * L.pad     -- заголовок, сетка, строка подсказки (и кнопка listen)
  local a = p.anchor or { x = L.pad, y = L.pad }
  local x = math.max(2, math.min(W - w - 2, a.x))
  local y = a.y
  if y + h > H - 2 then y = (a.top or a.y) - h - 2 end
  y = math.max(2, math.min(y, H - h - 2))
  return x, y, w, h, cw, rows, crh
end

-- рисование; d = { L, set, rect, text, ms, fit, C = цвета }
function SM.draw(d)
  local p = SM.p
  if not p then return end
  local L, set, text, ms, C = d.L, d.set, d.text, d.ms, d.C
  local x, y, w, h, cw, rows, crh = SM.layout(L, ms, gfx.w, gfx.h)
  SM.rect = { x, y, w, h }
  set(C.PANEL); gfx.rect(x, y, w, h, 1)
  set(C.FRAME); gfx.rect(x, y, w, h, 0); gfx.rect(x + 1, y + 1, w - 2, h - 2, 0)
  text(x + L.pad, y + L.pad, d.fit(p.title or '', w - 2 * L.pad), C.CYAN)
  local gx, gy = x + L.pad, y + L.pad + L.rh
  local mx, my = gfx.mouse_x, gfx.mouse_y
  SM.hot = nil
  for i, it in ipairs(p.items) do
    local r, c = (i - 1) // p.cols, (i - 1) % p.cols
    local cx, cy = gx + c * cw, gy + r * crh
    local hot = mx >= cx and mx < cx + cw and my >= cy and my < cy + crh
    if hot then SM.hot = i end
    -- 9 окт: выбор клавишами — заметная янтарная заливка; текущее значение — янтарный текст
    local sel = i == p.sel
    if sel then set(C.SELF); gfx.rect(cx, cy, cw - 1, crh, 1) end
    if it.draw then it.draw(cx + 1, cy + 1, cw - 3, crh - 2, sel)
    else
      local col = sel and C.TEXT or (it.on and C.AMBER or (it.dim and C.GREY or C.TEXT))
      text(cx + math.floor((cw - ms(it.label)) / 2), cy + 1, it.label, col)
    end
    if sel then set(C.AMBER); gfx.rect(cx, cy, cw - 1, crh, 0)
    elseif hot then set(C.TEXT); gfx.rect(cx, cy, cw - 1, crh, 0)
    elseif it.on then set(C.AMBER); gfx.rect(cx, cy, cw - 1, crh, 0) end
  end
  -- наведение на другую ячейку — тоже прослушивание
  if SM.hot and SM.hot ~= SM.hot_prev then notify(p, SM.hot) end
  SM.hot_prev = SM.hot
  -- кнопка listen справа внизу
  local by = gy + rows * crh
  local lw = ms('listen') + 2 * L.pad
  local lx = x + w - L.pad - lw
  local lhot = mx >= lx and mx < lx + lw and my >= by and my < by + L.rh
  set(SM.listen and C.SELF or C.PANEL); gfx.rect(lx, by, lw, L.rh, 1)
  set(SM.listen and C.AMBER or C.GREY); gfx.rect(lx, by, lw, L.rh, 0)
  text(lx + L.pad, by, 'listen', (SM.listen or lhot) and C.AMBER or C.GREY)
  SM.lbtn = { lx, by, lw, L.rh }
  -- подсказка: под мышью, иначе выбранное
  local ti = p.items[SM.hot or p.sel]
  local tip = lhot and ('listen: the choice sounds when it changes - ' .. (SM.listen and 'on' or 'off')) or (ti and (ti.tip or ti.label) or '')
  text(x + L.pad, by, d.fit(tip, lx - x - 2 * L.pad), C.GREY)
end

-- мышь: щелчок по ячейке — выбор, мимо (или ПКМ) — закрыть. true — съели
function SM.click(mx, my, right)
  if not SM.p then return false end
  local r = SM.rect
  local inside = r and mx >= r[1] and mx < r[1] + r[3] and my >= r[2] and my < r[2] + r[4]
  if right or not inside then SM.close(); return true end
  local b = SM.lbtn
  if b and mx >= b[1] and mx < b[1] + b[3] and my >= b[2] and my < b[2] + b[4] then
    SM.listen = not SM.listen
    if SM.on_listen then SM.on_listen(SM.listen) end
    return true
  end
  if SM.hot then SM.p.sel = SM.hot; pick(SM.hot) end
  return true
end

function SM.inside(mx, my)
  local r = SM.rect
  return SM.p and r and mx >= r[1] and mx < r[1] + r[3] and my >= r[2] and my < r[2] + r[4]
end

-- ── сетки ─────────────────────────────────────────────────────────────────
SM.NAMES = { 'C-', 'C#', 'D-', 'D#', 'E-', 'F-', 'F#', 'G-', 'G#', 'A-', 'A#', 'B-' }
function SM.note_label(p) return SM.NAMES[p % 12 + 1] .. tostring(p // 12 - 1) end

-- ноты: октавы 0..9 строками по 12, ниже OFF и --- (удалить). cur — высота
-- ноты в ячейке (подсвечена), oct — октава ввода (выбор стартует там)
function SM.notes(cur, oct)
  local items = {}
  for o = 0, 9 do
    for k = 0, 11 do
      local p = (o + 1) * 12 + k
      if p <= 127 then items[#items + 1] = { label = SM.note_label(p), v = p, on = p == cur, tip = ('note %s (%d)'):format(SM.note_label(p), p) } end
    end
  end
  while #items % 12 ~= 0 do items[#items + 1] = { label = '', v = nil, dim = true } end
  items[#items + 1] = { label = 'OFF', v = 'off', tip = 'note off: the sounding note ends in this row' }
  items[#items + 1] = { label = '---', v = 'del', tip = 'delete the event of this row' }
  local sel
  for i, it in ipairs(items) do if it.v == (cur or ((oct or 4) + 1) * 12) then sel = i end end
  return items, 12, sel
end

-- значения 0..n−1 (n = 128 или 256): hex — две цифры, midi — десятичные;
-- clear — ячейка «--» в конце (убрать значение)
function SM.values(n, cur, hex, clear)
  local items = {}
  for v = 0, n - 1 do
    items[#items + 1] = { label = hex and ('%02X'):format(v) or tostring(v), v = v, on = v == cur,
                          tip = ('%d  (hex %02X)'):format(v, v) }
  end
  if clear then items[#items + 1] = { label = '--', v = 'clear', tip = clear } end
  local sel = cur and (cur + 1) or 1
  return items, 16, sel
end

-- буквы команд (описания — как в справке; порядок: часто нужные сперва)
SM.FX = {
  { 'S', 'slice xx / sample offset xx/256' }, { 'C', 'item volume xx/80' }, { '8', 'pan (80 = centre)' },
  { 'I', 'fade in xx/16 row' }, { 'O', 'fade out xx/16 row' }, { 'T', 'beatsync to xx rows' },
  { 'U', 'pitch up xx/16 semitone per row' }, { 'D', 'pitch down xx/16 semitone per row' },
  { 'G', 'glide from the previous note in xx rows' }, { '4', 'vibrato: period 16/x rows, depth y/8 semitone' },
  { '0', 'arpeggio 0, x, y semitones' }, { 'A', 'volume slide: up x/16, down y/16 per row' },
  { 'R', 'retrigger every x/16 row, volume x(1 - y/16)' }, { 'P', 'probability xx/FF' },
  { 'F', 'tempo: BPM = xx' }, { 'B', 'jump to sequence slot xx' }, { 'L', 'L00: loop source off' },
  { 'M', 'channel mode 0..4' }, { '9', 'offset xx/FF (old, as S)' },
}
function SM.fx_letters()
  local items = {}
  for _, e in ipairs(SM.FX) do items[#items + 1] = { label = e[1], v = e[1], tip = e[1] .. 'xx  ' .. e[2] } end
  return items, 8, 1
end

return SM
