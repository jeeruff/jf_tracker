-- jf_tracker_reform.lua — reform (19 окт): живая переделка выделенных нот. Идея — Reform для Renoise,
-- https://www.aqu.surf/reform (своя реализация, код не копировался; в Credits README).
--
-- Время: scale (растянуть / сжать от якоря), curve (перераспределить моменты по кривой), shift (сдвиг строк),
-- redistribute (равномерно); якорь — note (от первой ноты до последней) / sel (рамка выделения).
-- Значения: vol (velocity / громкость) или команда поля — новый диапазон lo..hi с кривой; mode remap (по исходным
-- значениям) / even (равномерно по порядку). Всё считается от исходного снимка — слайдеры можно крутить туда-обратно.
-- Клавиши: j k — строка, h l — значение / переключатель (Shift — мелко), Space — прослушать выделение, 0 — сброс строки,
-- Enter — оставить, Esc — вернуть как было. Без reaper.* — тест tests/test_reform.lua; применение — main.

local RF = { sel = 1 }

RF.ROWS = {
  { k = 'scale',  label = 'scale',      min = 0.25, max = 4,  step = 0.05, fmt = 'x%.2f', def = 1 },
  { k = 'curve',  label = 'curve',      min = -1,   max = 1,  step = 0.05, fmt = '%+.2f', def = 0 },
  { k = 'shift',  label = 'shift',      min = -64,  max = 64, step = 1,    fmt = '%+d rows', def = 0 },
  { k = 'redist', label = 'redistribute', toggle = true, def = false },
  { k = 'anchor', label = 'anchor',     toggle = true, def = false, on = 'selection', off = 'notes' },
  { k = 'vals',   label = 'values',     toggle = true, def = false },
  { k = 'lo',     label = 'value from', min = 0, max = 255, step = 1, fmt = '%02X', def = 0 },
  { k = 'hi',     label = 'value to',   min = 0, max = 255, step = 1, fmt = '%02X', def = 255 },
  { k = 'vcurve', label = 'value curve', min = -1, max = 1, step = 0.05, fmt = '%+.2f', def = 0 },
  { k = 'even',   label = 'value mode', toggle = true, def = false, on = 'even', off = 'remap' },
}

function RF.defaults()
  local p = {}
  for _, r in ipairs(RF.ROWS) do p[r.k] = r.def end
  return p
end

-- кривая: c > 0 — медленно, потом быстро (сгущается к началу), c < 0 — наоборот
local function shape(t, c)
  t = math.max(0, math.min(1, t))
  if math.abs(c) < 1e-6 then return t end
  local e = 1 + 3 * math.abs(c)
  if c > 0 then return t ^ e end
  return 1 - (1 - t) ^ e
end
RF.shape = shape

-- ev: { { row = дробная строка, v = 0..255 или nil } … } в порядке нот; r0, r1 — рамка выделения (включительно)
-- → новые { row, v } (копия)
function RF.compute(ev, r0, r1, p)
  local n = #ev
  local out = {}
  if n == 0 then return out end
  local order = {}
  for i = 1, n do order[i] = i end
  table.sort(order, function(a, b) return ev[a].row < ev[b].row end)
  local rank = {}
  for k, i in ipairs(order) do rank[i] = k end
  local a, b
  if p.anchor then a, b = r0, r1 else a, b = ev[order[1]].row, ev[order[n]].row end
  local span = b - a
  local vmin, vmax
  for _, e in ipairs(ev) do if e.v then vmin = math.min(vmin or e.v, e.v); vmax = math.max(vmax or e.v, e.v) end end
  for i, e in ipairs(ev) do
    local t = span > 1e-9 and (e.row - a) / span or 0
    if p.redist then t = n > 1 and (rank[i] - 1) / (n - 1) or 0 end
    local row = (span > 1e-9 or p.redist) and (a + shape(t, p.curve or 0) * span) or e.row
    row = a + (row - a) * (p.scale or 1) + (p.shift or 0)
    local v = e.v
    if p.vals and e.v then
      local u
      if p.even then u = n > 1 and (rank[i] - 1) / (n - 1) or 0
      else u = (vmax and vmax > vmin) and (e.v - vmin) / (vmax - vmin) or 0 end
      v = math.floor((p.lo or 0) + ((p.hi or 255) - (p.lo or 0)) * shape(u, p.vcurve or 0) + 0.5)
    end
    out[i] = { row = math.max(0, row), v = v }
  end
  return out
end

local function clamp(r, v) return math.max(r.min, math.min(r.max, v)) end

-- клавиша → 'changed' | 'keep' | 'revert' | true | false
function RF.key(p, c, shift)
  local ch = c > 0 and c < 256 and string.char(c) or ''
  local r = RF.ROWS[RF.sel]
  if ch == 'j' or c == 1685026670 then RF.sel = math.min(#RF.ROWS, RF.sel + 1); return true end
  if ch == 'k' or c == 30064 then RF.sel = math.max(1, RF.sel - 1); return true end
  if ch == 'g' then RF.sel = 1; return true end
  if ch == 'G' then RF.sel = #RF.ROWS; return true end
  if c == 13 then return 'keep' end
  if ch == ' ' then return 'play' end   -- 19 окт: Space — прослушать выделение (как в Reform)
  if c == 27 then return 'revert' end
  if ch == '0' then p[r.k] = r.def; return 'changed' end
  if r.toggle then
    if ch == 'h' or ch == 'l' or c == 1818584692 or c == 1919379572 then p[r.k] = not p[r.k]; return 'changed' end
    return true
  end
  if ch == 'h' or ch == 'l' or ch == 'H' or ch == 'L' or c == 1818584692 or c == 1919379572 then
    local d = (ch == 'l' or ch == 'L' or c == 1919379572) and 1 or -1
    local st = (shift or ch == 'H' or ch == 'L') and (r.step < 1 and r.step / 5 or 1) or (r.step >= 1 and r.k ~= 'shift' and 8 or r.step)
    p[r.k] = clamp(r, (p[r.k] or r.def) + d * st)
    if r.k == 'lo' or r.k == 'hi' or r.k == 'vcurve' then p.vals = true end   -- тронул значение — значения включены
    return 'changed'
  end
  return true
end

function RF.set_from_x(p, i, frac)
  local r = RF.ROWS[i]; if not r or r.toggle then return end
  local v = r.min + math.max(0, math.min(1, frac)) * (r.max - r.min)
  if r.step >= 1 then v = math.floor(v + 0.5) else v = math.floor(v / r.step + 0.5) * r.step end
  p[r.k] = clamp(r, v)
  if r.k == 'lo' or r.k == 'hi' or r.k == 'vcurve' then p.vals = true end
end

-- рисование; info = { n = нот, target = 'vol' | код команды } — подпись; возвращает hover
function RF.draw(U, L, p, info, x, y, w, h, focus, mx, my)
  local hv = {}
  local rh, pad = L.rh, L.pad
  local lw = 0
  for _, r in ipairs(RF.ROWS) do lw = math.max(lw, U.measure(r.label)) end
  local vw = U.measure('+64 rows')
  local yy = y + 2
  local head = info and info.n and (info.pending and ('reform: the selection - %d note(s) (moves on the first change)'):format(info.n) or ('reform: %d note(s), values - %s'):format(info.n, info.target or 'vol')) or 'reform: select notes (v / V or a right drag)'
  U.text(x + pad, yy, head, info and info.n and U.GREY or U.DIM)
  yy = yy + rh + 2
  for i, r in ipairs(RF.ROWS) do
    if yy + rh > y + h then break end
    local cur = focus and i == RF.sel
    local lx = x + pad
    U.text(lx, yy, r.label, cur and U.AMBER or U.TEXT)
    local sx = lx + lw + pad
    local hot = mx >= sx and mx < x + w - pad and my >= yy and my < yy + rh
    if r.toggle then
      local on = p[r.k]
      local lab = on and (r.on or 'on') or (r.off or 'off')
      local bw = U.measure(lab) + 2 * pad
      U.set(on and U.tint(U.CYAN, 0.25) or (hot and U.tint(U.AMBER, 0.3) or U.BG)); gfx.rect(sx, yy, bw, rh - 1, 1)
      U.set(on and U.CYAN or U.LINE); gfx.rect(sx, yy, bw, rh - 1, 0)
      U.text(sx + pad, yy, lab, hot and U.AMBER or (on and U.CYAN or U.GREY))
      if hot then hv.toggle = i end
    else
      local sw = math.max(4 * L.cw, x + w - pad - vw - pad - sx)
      local v = p[r.k] or r.def
      local dim = (r.k == 'lo' or r.k == 'hi' or r.k == 'vcurve') and not p.vals
      U.dslider(sx, yy + math.floor(rh / 2), sw, (v - r.min) / (r.max - r.min), r.min < 0, (hot or cur) and U.AMBER or (dim and U.DIM or U.TEXT), hot, rh)
      local vs = r.fmt:format(v)
      U.text(x + w - pad - U.measure(vs), yy, vs, dim and U.DIM or U.GREY)
      if hot then hv.slider = { i = i, x0 = sx, w = sw } end
    end
    if mx >= x and mx < x + w and my >= yy and my < yy + rh then hv.row = i end
    yy = yy + rh
  end
  if yy + rh + 2 <= y + h then
    local bx = x + pad
    for _, b in ipairs({ { 'keep (Enter)', 'keep' }, { 'revert (Esc)', 'revert' } }) do
      local bw = U.measure(b[1]) + 2 * pad
      local bh = mx >= bx and mx < bx + bw and my >= yy + 2 and my < yy + 2 + rh
      U.set(bh and U.tint(U.AMBER, 0.3) or U.BG); gfx.rect(bx, yy + 2, bw, rh - 1, 1)
      U.set(bh and U.AMBER or U.LINE); gfx.rect(bx, yy + 2, bw, rh - 1, 0)
      U.text(bx + pad, yy + 2, b[1], bh and U.AMBER or U.TEXT)
      if bh then hv.btn = b[2] end
      bx = bx + bw + pad
    end
  end
  return hv
end

return RF
