-- jf_tracker_lfogen.lua — генератор LFO в точки огибающей (2 окт).
--
-- Панель справа во вкладке modulation: форма, период (строки трекера —
-- следует темпу и LPB), глубина, центр, фаза, точек на период. Кнопки:
-- «AI» — новый automation item с кривой на огибающей курсора, «points» —
-- точки прямо в огибающую. Где: time selection, иначе регион курсора,
-- иначе такт от строки курсора (решает main). Значения точек — 0..1
-- (main переводит в сырые: min + v·(max − min)).
--
-- Клавиши (панель в фокусе): j k — поле, h l + - — значение (Shift ×10 в
-- main), Enter — на кнопке: сделать, g — AI сразу, p — точки сразу,
-- L / Esc — назад к матрице.
--
-- Без reaper.*: тестируется tests/test_lfogen.lua.

local LG = {}
LG.SHAPES = { 'sin', 'tri', 'saw+', 'saw-', 'sqr', 'rnd' }
LG.shape = 'sin'
LG.period = 16          -- строк на период
LG.depth = 0.5          -- размах 0..1 (от центра ± depth/2)
LG.center = 0.5
LG.phase = 0            -- 0..1 периода
LG.res = 16             -- точек на период (sin / tri)
LG.seed = 1             -- случайность rnd (повторяемая)
LG.sel = 1

LG.FIELDS = {
  { key = 'shape', label = 'shape' },
  { key = 'period', label = 'period', min = 1, max = 256, step = 1, fmt = '%d rows' },
  { key = 'depth', label = 'depth', min = 0, max = 1, step = 0.05, fmt = '%.2f' },
  { key = 'center', label = 'center', min = 0, max = 1, step = 0.05, fmt = '%.2f' },
  { key = 'phase', label = 'phase', min = 0, max = 1, step = 0.125, fmt = '%.3f' },
  { key = 'res', label = 'points', min = 4, max = 64, step = 4, fmt = '%d / period' },
  { key = 'ai', label = 'make AI', button = true },
  { key = 'points', label = 'write points', button = true },
}

-- форма: x — доля периода 0..1 → −1..1
function LG.wave(shape, x)
  x = x % 1
  if shape == 'sin' then return math.sin(2 * math.pi * x)
  elseif shape == 'tri' then return x < 0.25 and 4 * x or (x < 0.75 and 2 - 4 * x or 4 * x - 4)
  elseif shape == 'saw+' then return 2 * x - 1
  elseif shape == 'saw-' then return 1 - 2 * x
  elseif shape == 'sqr' then return x < 0.5 and 1 or -1 end
  return 0
end

local function clamp01(v) return math.max(0, math.min(1, v)) end
local function level(w) return clamp01(LG.center + w * LG.depth / 2) end

-- псевдослучайное 0..1 по номеру шага (повторяемо: seed + шаг)
local function rnd(k)
  local x = math.sin((k + 1) * 12.9898 + LG.seed * 78.233) * 43758.5453
  return x - math.floor(x)
end

-- точки на [r0, r1) строк: { { row = (дробная строка), v = 0..1, shape = 0 lin | 1 sqr } … }
-- main переводит row → время своим row_time (темп, LPB)
function LG.points(r0, r1)
  local out = {}
  local per = math.max(1, LG.period)
  local function add(row, v, shp) if row >= r0 - 1e-9 and row < r1 - 1e-9 then out[#out + 1] = { row = row, v = v, shape = shp } end end
  local ph = LG.phase * per
  -- начало первого периода не позже r0
  local c0 = math.floor((r0 - ph) / per)
  if LG.shape == 'sin' or LG.shape == 'tri' then
    local step = per / math.max(2, LG.res)
    local k0 = math.floor((r0 - ph) / step)
    local k = k0
    while true do
      local row = ph + k * step
      if row >= r1 - 1e-9 then break end
      add(row, level(LG.wave(LG.shape, (row - ph) / per)), 0)
      k = k + 1
    end
  elseif LG.shape == 'saw+' or LG.shape == 'saw-' then
    -- линия через период и скачок: точка в начале, ступень перед концом
    local c = c0
    while true do
      local s = ph + c * per
      if s >= r1 - 1e-9 then break end
      add(s, level(LG.wave(LG.shape, 0)), 0)
      add(s + per - 1e-3, level(LG.wave(LG.shape, 0.9999)), 1)
      c = c + 1
    end
  elseif LG.shape == 'sqr' then
    local c = c0
    while true do
      local s = ph + c * per
      if s >= r1 - 1e-9 then break end
      add(s, level(1), 1)
      add(s + per / 2, level(-1), 1)
      c = c + 1
    end
  elseif LG.shape == 'rnd' then
    -- ступени: 4 на период (sample & hold)
    local step = per / 4
    local k = math.floor((r0 - ph) / step)
    while true do
      local row = ph + k * step
      if row >= r1 - 1e-9 then break end
      add(row, level(rnd(k) * 2 - 1), 1)
      k = k + 1
    end
  end
  -- первая точка ровно в r0 (кривая не начинается с середины пустоты)
  if #out == 0 or out[1].row > r0 + 1e-6 then
    local w = LG.shape == 'rnd' and (rnd(math.floor((r0 - ph) / (per / 4))) * 2 - 1) or LG.wave(LG.shape == 'sqr' and 'sqr' or LG.shape, (r0 - ph) / per)
    table.insert(out, 1, { row = r0, v = level(w), shape = (LG.shape == 'sqr' or LG.shape == 'rnd') and 1 or 0 })
  end
  return out
end

-- изменить поле i на d шагов (shape — по кругу)
function LG.adjust(i, d)
  local f = LG.FIELDS[i]
  if not f or f.button then return end
  if f.key == 'shape' then
    local k = 1
    for j, s in ipairs(LG.SHAPES) do if s == LG.shape then k = j end end
    k = ((k - 1 + (d >= 0 and 1 or -1)) % #LG.SHAPES) + 1
    LG.shape = LG.SHAPES[k]
    if LG.shape == 'rnd' then LG.seed = LG.seed + 1 end
    return
  end
  local v = LG[f.key] + d * f.step
  LG[f.key] = math.max(f.min, math.min(f.max, v))
  if f.key == 'period' or f.key == 'res' then LG[f.key] = math.floor(LG[f.key] + 0.5) end
end

local UP, DOWN, LEFT, RIGHT = 30064, 1685026670, 1818584692, 1919379572
-- 'leave' — к матрице; 'ai' / 'points' — сделать; true — съедено; false — не наше
function LG.key(c, mult)
  local ch = c < 256 and string.char(c) or ''
  mult = mult or 1
  if c == 27 or ch == 'L' then return 'leave' end
  if ch == 'j' or c == DOWN then LG.sel = math.min(#LG.FIELDS, LG.sel + 1)
  elseif ch == 'k' or c == UP then LG.sel = math.max(1, LG.sel - 1)
  elseif ch == 'l' or c == RIGHT or ch == '+' or ch == '=' then LG.adjust(LG.sel, mult)
  elseif ch == 'h' or c == LEFT or ch == '-' then LG.adjust(LG.sel, -mult)
  elseif c == 13 or ch == ' ' then
    local f = LG.FIELDS[LG.sel]
    if f.button then return f.key end
    LG.adjust(LG.sel, 1)
  elseif ch == 'g' then return 'ai'
  elseif ch == 'p' then return 'points'
  else return false end
  return true
end

local function field_text(f)
  if f.button then return '' end
  if f.key == 'shape' then return LG.shape end
  return f.fmt:format(LG[f.key])
end

-- отрисовка в (x, y, w, h); hover = { field = i } | { preview = true }
function LG.draw(U, L, x, y, w, h, focused, fit, target)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local hover
  U.text(x, y, fit('LFO -> ' .. (target or 'envelope at the cursor'), w), focused and U.AMBER or U.GREY)
  local fy = y + L.rh + 2
  local lw = U.measure('points ') + L.pad
  for i, f in ipairs(LG.FIELDS) do
    local ry = fy + (i - 1) * L.rh
    if ry + L.rh > y + h then break end
    local sel = focused and LG.sel == i
    local hot = mx >= x and mx < x + w and my >= ry and my < ry + L.rh
    if f.button then
      local bw = U.measure(f.label) + 2 * L.pad
      U.set(sel and U.tint(U.AMBER, 0.35) or (hot and U.tint(U.AMBER, 0.2) or U.BG)); gfx.rect(x, ry, bw, L.rh, 1)
      U.set((sel or hot) and U.AMBER or U.LINE); gfx.rect(x, ry, bw, L.rh, 0)
      U.text(x + L.pad, ry + 1, f.label, (sel or hot) and U.AMBER or U.TEXT)
      if hot and mx < x + bw then hover = { field = i } end
    else
      if sel then U.set(U.tint(U.AMBER, 0.22)); gfx.rect(x, ry, w, L.rh, 1) end
      U.text(x, ry + 1, f.label, sel and U.AMBER or U.GREY)
      U.text(x + lw, ry + 1, fit(field_text(f), w - lw), U.TEXT)
      if hot then hover = { field = i } end
    end
  end
  -- предпросмотр: два периода
  local py = fy + #LG.FIELDS * L.rh + 4
  local ph = y + h - py
  if ph >= 3 * L.rh / 2 and w > 16 then
    U.set(U.PANEL); gfx.rect(x, py, w, ph, 1)
    U.set(U.LINE); gfx.rect(x, py, w, ph, 0)
    local pts = LG.points(0, LG.period * 2)
    local function px(row) return x + 1 + math.floor(row / (LG.period * 2) * (w - 3)) end
    local function pyv(v) return py + ph - 2 - math.floor(v * (ph - 4)) end
    U.set(U.CYAN)
    for k, p in ipairs(pts) do
      local nx = pts[k + 1]
      local x1, y1 = px(p.row), pyv(p.v)
      local x2 = nx and px(nx.row) or (x + w - 2)
      if p.shape == 1 or not nx then gfx.line(x1, y1, x2, y1); if nx then gfx.line(x2, y1, x2, pyv(nx.v)) end
      else gfx.line(x1, y1, x2, pyv(nx.v)) end
    end
    if mx >= x and mx < x + w and my >= py and my < py + ph then hover = { preview = true } end
  end
  return hover
end

return LG
