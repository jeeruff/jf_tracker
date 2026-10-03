-- jf_tracker_modmatrix.lua — модуляционная матрица: нативная модуляция
-- параметров FX REAPER (Parameter Modulation) в виде простой таблицы.
--
-- Строка — модулированный параметр трека курсора (param.N.mod.active = 1).
-- Колонки — короткие обозначения, как в Excel-таблице:
--   FX.param | BASE | L1 SHP SPD SYN STR | ENV ATT REL E.ST | LNK SRC SCL OFS
--   L1  — LFO (param.N.lfo.*), ENV — следящий за громкостью (ACS,
--   param.N.acs.*), LNK — связь с другим параметром (param.N.plink.*).
-- Ячейки: тоггл (on / --), перечисление (форма LFO), число, ссылка (SRC).
--
-- Клавиши (фокус верхней панели, вкладка modulation): h j k l — ячейка;
-- Enter / Space — тоггл или выбор (форма по кругу, SRC — fzf по параметрам);
-- + - / ^A ^X — значение, > < — ×10; a — добавить параметр (fzf), x — снять
-- модуляцию строки; o — окно FX; w — нативное окно модуляции; Esc — назад.
-- Мышь: клик — ячейка, двойной клик — как Enter, колесо — значение.
--
-- Читает ctx.mod_rows(col) (модель), пишет ctx.mod_field / mod_set (edit).

local MM = {}
local U, ctx

MM.row, MM.col = 1, 3
MM.scroll = 0

local SHAPES = { [0] = 'sin', [1] = 'sqr', [2] = 'saw<', [3] = 'saw>', [4] = 'tri', [5] = 'rnd' }

-- kind: name | num | toggle | enum | link ; key — поле param.N.<key>
MM.COLS = {
  { head = 'FX.param', kind = 'name', w = 16 },
  { head = 'BASE', key = 'mod.baseline', kind = 'num', min = 0, max = 1, step = 0.01, fmt = '%.2f', w = 4 },
  { head = 'L1', key = 'lfo.active', kind = 'toggle', w = 3, group = 'lfo' },
  { head = 'SHP', key = 'lfo.shape', kind = 'enum', min = 0, max = 5, w = 4, names = SHAPES },
  { head = 'SPD', key = 'lfo.speed', kind = 'num', min = 0.0039, max = 16, step = 0.05, fmt = '%.2f', w = 5 },
  { head = 'SYN', key = 'lfo.temposync', kind = 'toggle', w = 3 },
  { head = 'STR', key = 'lfo.strength', kind = 'num', min = 0, max = 1, step = 0.01, fmt = '%.2f', w = 4 },
  { head = 'ENV', key = 'acs.active', kind = 'toggle', w = 3, group = 'acs' },
  { head = 'ATT', key = 'acs.attack', kind = 'num', min = 0, max = 1000, step = 5, fmt = '%.0f', w = 4 },
  { head = 'REL', key = 'acs.release', kind = 'num', min = 0, max = 1000, step = 5, fmt = '%.0f', w = 4 },
  { head = 'E.ST', key = 'acs.strength', kind = 'num', min = 0, max = 1, step = 0.01, fmt = '%.2f', w = 4 },
  { head = 'LNK', key = 'plink.active', kind = 'toggle', w = 3, group = 'plink' },
  { head = 'SRC', key = 'plink', kind = 'link', w = 10 },
  { head = 'SCL', key = 'plink.scale', kind = 'num', min = -1, max = 1, step = 0.01, fmt = '%.2f', w = 5 },
  { head = 'OFS', key = 'plink.offset', kind = 'num', min = -1, max = 1, step = 0.01, fmt = '%.2f', w = 5 },
}

function MM.init(u, c) U, ctx = u, c end

-- текст ячейки
local function cell_text(r, c)
  local v = r.v and r.v[c.key]
  if c.kind == 'name' then return r.fxname .. '.' .. r.pname end
  if c.kind == 'toggle' then return (v and v >= 0.5) and 'on' or '--' end
  if c.kind == 'enum' then return c.names[math.floor(v or 0)] or tostring(v) end
  if c.kind == 'link' then
    if not r.v or not r.v['plink.effect'] or r.v['plink.effect'] < 0 then return '-' end
    return r.link_name or ('%d.%d'):format(r.v['plink.effect'], r.v['plink.param'] or 0)
  end
  if v == nil then return '.' end
  return (c.fmt):format(v)
end

-- активна ли группа ячейки (числа L1 тусклые, если L1 выкл)
local function group_on(r, ci)
  local g
  for k = ci, 1, -1 do if MM.COLS[k].group then g = MM.COLS[k]; break end end
  if not g or ci == 1 or ci == 2 then return true end
  local v = r.v and r.v[g.key]
  return v and v >= 0.5
end

-- отрисовка в прямоугольнике (x, y, w, h); возвращает hover { row, col }
function MM.draw(L, x, y, w, h, rows, focused, title)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local hover
  local cw = U.measure('W')
  -- ширины: имя тянется, остальные по w символов
  local fixed = 0
  for i = 2, #MM.COLS do fixed = fixed + MM.COLS[i].w * cw + L.pad end
  local name_w = math.max(cw * 8, w - fixed - L.pad)
  local xs, ws = {}, {}
  local cx = x
  for i, c in ipairs(MM.COLS) do
    xs[i] = cx
    ws[i] = (i == 1) and name_w or (c.w * cw)
    cx = cx + ws[i] + L.pad
  end
  -- шапка
  U.text(x, y, ctx.fit(title or '', name_w), U.GREY)
  for i = 2, #MM.COLS do
    local c = MM.COLS[i]
    local col = (c.group and U.AMBER) or U.GREY
    U.text(xs[i], y, ctx.fit(c.head, ws[i]), col)
    if xs[i] + ws[i] > x + w then break end
  end
  U.set(U.LINE); gfx.rect(x, y + L.rh, w, 1, 1)
  local top = y + L.rh + 2
  -- полоса выбранной строки снизу (3 окт): кнопки формы LFO, тумблеры групп,
  -- слайдеры параметров группы курсора — если высоты хватает
  local strip_h = (#rows > 0 and h >= 6 * L.rh) and (2 * L.rh + 4) or 0
  local nvis = math.max(1, math.floor((h - L.rh - 2 - strip_h) / L.rh))
  if MM.row > #rows then MM.row = math.max(1, #rows) end
  if MM.row - 1 < MM.scroll then MM.scroll = MM.row - 1 end
  if MM.row - 1 >= MM.scroll + nvis then MM.scroll = MM.row - nvis end
  if #rows == 0 then
    U.text(x, top, ctx.fit('no modulated parameters - a: add (fzf), or rclick a DSP parameter', w), U.GREY)
  end
  for i = 1, nvis do
    local ri = MM.scroll + i
    local r = rows[ri]
    if not r then break end
    local ry = top + (i - 1) * L.rh
    for ci, c in ipairs(MM.COLS) do
      if xs[ci] + ws[ci] > x + w + 1 then break end
      local sel = focused and ri == MM.row and ci == MM.col
      local txt = ctx.fit(cell_text(r, c), ws[ci])
      local on = group_on(r, ci)
      local colr = (c.kind == 'toggle' and r.v and (r.v[c.key] or 0) >= 0.5) and U.GREEN or (on and U.TEXT or U.DIM)
      if c.kind == 'name' then colr = (ri == MM.row) and U.AMBER or U.TEXT end
      if sel then
        U.set(U.TEXT); gfx.rect(xs[ci] - 1, ry, ws[ci] + 2, L.rh, 1)
        U.text(xs[ci], ry + 1, txt, U.BG, U.TEXT)
      else
        U.text(xs[ci], ry + 1, txt, colr)
      end
      if mx >= xs[ci] - 1 and mx < xs[ci] + ws[ci] + L.pad and my >= ry and my < ry + L.rh then hover = { row = ri, col = ci } end
      if ctx.hint and c.kind ~= 'name' then ctx.hint('mm', xs[ci], ry, ws[ci], L.rh, { row = ri, col = ci }) end
    end
  end
  local r = rows[MM.row]
  if strip_h > 0 and r then
    local sy = y + h - strip_h + 2
    U.set(U.LINE); gfx.rect(x, sy - 2, w, 1, 1)
    local hv = MM.draw_strip(L, x, sy, w, r)
    if hv then hover = hv end
  end
  return hover
end

-- группа колонки: lfo / acs / plink (по ближайшему слева заголовку группы)
function MM.group_of(ci)
  for i = ci, 1, -1 do if MM.COLS[i].group then return MM.COLS[i].group end end
  return 'lfo'
end

-- полоса выбранной строки: { strip = 'shape', v = n } | { strip = 'toggle', key = }
-- | { strip = 'slider', ci =, x =, w = }
function MM.draw_strip(L, x, y, w, r)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local hover
  local v = r.v or {}
  local bx = x
  local function button(label, on, hv)
    local bw = U.measure(label) + 2 * L.pad
    if bx + bw > x + w then return end
    local hot = mx >= bx and mx < bx + bw and my >= y and my < y + L.rh
    U.set(on and U.tint(U.AMBER, 0.35) or (hot and U.tint(U.AMBER, 0.18) or U.BG)); gfx.rect(bx, y, bw, L.rh - 1, 1)
    U.set((on or hot) and U.AMBER or U.LINE); gfx.rect(bx, y, bw, L.rh - 1, 0)
    U.text(bx + L.pad, y, label, on and U.AMBER or (hot and U.TEXT or U.GREY))
    if hot then hover = hv end
    bx = bx + bw + 2
  end
  -- строка 1: тумблеры групп, форма LFO кнопками
  for _, t in ipairs({ { 'L1', 'lfo.active' }, { 'ENV', 'acs.active' }, { 'LNK', 'plink.active' } }) do
    button(t[1], (v[t[2]] or 0) >= 0.5, { strip = 'toggle', key = t[2] })
  end
  bx = bx + L.pad
  local cur = math.floor(v['lfo.shape'] or 0)
  for n = 0, 5 do button(SHAPES[n], cur == n, { strip = 'shape', v = n }) end
  -- строка 2: BASE + числа группы курсора — горизонтальные слайдеры
  local g = MM.group_of(MM.col)
  local list = {}
  for ci, c in ipairs(MM.COLS) do
    if c.kind == 'num' and (c.key == 'mod.baseline' or MM.group_of(ci) == g) then list[#list + 1] = ci end
  end
  local y2 = y + L.rh + 2
  local n = #list
  if n > 0 then
    local cw = math.floor((w - (n - 1) * L.pad) / n)
    for k, ci in ipairs(list) do
      local c = MM.COLS[ci]
      local sx = x + (k - 1) * (cw + L.pad)
      local lab = c.head
      local lw = U.measure(lab) + L.pad
      local val = v[c.key] or c.min or 0
      local vt = (c.fmt or '%.2f'):format(val)
      local vw = U.measure(vt) + L.pad
      local tw = cw - lw - vw
      U.text(sx, y2 + 1, lab, U.GREY)
      if tw >= 8 then
        local fr = (val - c.min) / math.max(1e-9, c.max - c.min)
        local tx = sx + lw
        local cy = y2 + math.floor(L.rh / 2)
        U.set(U.DIM); gfx.rect(tx, cy - 1, tw, 2, 1)
        U.set(U.TEXT); gfx.rect(tx, y2 + 3, math.max(1, math.floor(fr * tw + 0.5)), L.rh - 6, 1)
        U.text(tx + tw + L.pad / 2, y2 + 1, vt, U.TEXT)
        if mx >= tx - 2 and mx < tx + tw + 2 and my >= y2 and my < y2 + L.rh then hover = { strip = 'slider', ci = ci, x = tx, w = tw } end
      end
    end
  end
  return hover
end

-- ── правка ────────────────────────────────────────────────────────────────
local function clamp(v, c) return math.max(c.min or -math.huge, math.min(c.max or math.huge, v)) end

function MM.adjust(rows, d)
  local r, c = rows[MM.row], MM.COLS[MM.col]
  if not r or not c then return end
  if c.kind == 'num' then
    local v = (r.v and r.v[c.key]) or c.min or 0
    ctx.mod_field(r, c.key, clamp(v + d * c.step, c))
  elseif c.kind == 'enum' then
    local v = math.floor((r.v and r.v[c.key]) or 0) + (d > 0 and 1 or -1)
    if v > c.max then v = c.min elseif v < c.min then v = c.max end
    ctx.mod_field(r, c.key, v)
  elseif c.kind == 'toggle' then
    MM.activate(rows)
  end
end

function MM.activate(rows)
  local r, c = rows[MM.row], MM.COLS[MM.col]
  if not r or not c then return end
  if c.kind == 'toggle' then
    local on = not ((r.v and r.v[c.key] or 0) >= 0.5)
    ctx.mod_field(r, c.key, on and 1 or 0)
  elseif c.kind == 'enum' then MM.adjust(rows, 1)
  elseif c.kind == 'link' then ctx.mod_link_pick(r)
  elseif c.kind == 'name' then ctx.mod_open_fx(r) end
end

-- клавиши; true — съедена
function MM.key(c, rows)
  local ch = c < 256 and string.char(c) or ''
  local n = #MM.COLS
  if ch == 'h' or c == 1818584692 then MM.col = math.max(1, MM.col - 1)
  elseif ch == 'l' or c == 1919379572 then MM.col = math.min(n, MM.col + 1)
  elseif ch == 'j' or c == 1685026670 then MM.row = math.min(math.max(1, #rows), MM.row + 1)
  elseif ch == 'k' or c == 30064 then MM.row = math.max(1, MM.row - 1)
  elseif ch == 'g' then MM.row = 1
  elseif ch == 'G' then MM.row = math.max(1, #rows)
  elseif ch == '0' then MM.col = 1
  elseif ch == '$' then MM.col = n
  elseif c == 13 or ch == ' ' then MM.activate(rows)
  elseif ch == '+' or ch == '=' or c == 1 then MM.adjust(rows, 1)
  elseif ch == '-' or c == 24 then MM.adjust(rows, -1)
  elseif ch == '>' or ch == '.' then MM.adjust(rows, 10)
  elseif ch == '<' or ch == ',' then MM.adjust(rows, -10)
  elseif ch == 'a' then ctx.mod_add_pick()
  elseif ch == 'x' or c == 8 then local r = rows[MM.row]; if r then ctx.mod_remove(r) end
  elseif ch == 'o' then local r = rows[MM.row]; if r then ctx.mod_open_fx(r) end
  elseif ch == 'w' then local r = rows[MM.row]; if r then ctx.mod_window(r) end
  else return false end
  return true
end

return MM
