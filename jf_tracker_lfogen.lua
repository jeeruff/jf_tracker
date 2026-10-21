-- jf_tracker_lfogen.lua — генератор кривых в точки огибающей (2 окт).
--
-- Три типа (поле type):
--   lfo     форма по периоду (ниже)
--   podkat  подкат Anticipate: перед каждым хитом источника кривая за lead
--           строк (curve: −1 быстрый старт … +1 медленный), на хите hold,
--           затем экспоненциальный release; duck — вниз от center, swell —
--           вверх. Хиты: события трека-источника (ноты / items) или
--           транзиенты его аудио (sens). Наложения — максимум, как в
--           anticipate.lua (~/code/reascript).
--   follow  кривая от другой автоматизации (env) или громкости аудио трека
--           (audio): follower attack / release в строках, shift (> 0 —
--           раньше, lookahead), invert. Источник выбирает main (fzf).
-- Длительности — в строках трекера (следуют LPB и темпу). Плотные отсчёты
-- прореживаются (Рамер — Дуглас — Пекер, допуск LG.tol).
--
-- Панель справа во вкладке modulation: форма, период (строки трекера —
-- следует темпу и LPB), глубина, центр, фаза, точек на период. Кнопки:
-- «AI» — новый automation item с кривой на огибающей курсора, «points» —
-- точки прямо в огибающую. Где: time selection, иначе регион курсора,
-- иначе такт от строки курсора (решает main). Значения точек — 0..1
-- (main переводит в сырые: min + v·(max − min)).
--
-- Клавиши (панель в фокусе): j k — поле, h l + - — значение (Shift ×10 в
-- main), Enter — на кнопке: сделать, g — auto-item сразу, p — точки сразу,
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
LG.type = 'lfo'
LG.TYPES = { 'lfo', 'podkat', 'follow' }
-- podkat
LG.hits = 'events'      -- 'events' | 'transients'
LG.sens = 0.6
LG.lead = 4             -- строк до хита
LG.curve = 0.5          -- −1 … +1
LG.hold = 0.5
LG.release = 2
LG.dir = 'duck'         -- 'duck' | 'swell'
-- follow
LG.fsrc = 'env'         -- 'env' | 'audio'
LG.attack = 0.25
LG.frel = 2
LG.shift = 0
LG.invert = false
-- источник: номер колонки (podkat, follow audio) / подпись огибающей (follow env)
LG.src_i = 1
LG.src_names = {}
LG.src_env = nil        -- подпись выбранной огибающей-источника (main хранит указатель)
LG.tol = 0.004

local F = {
  type = { key = 'type', label = 'type', enum = 'TYPES' },
  shape = { key = 'shape', label = 'shape', enum = 'SHAPES' },
  period = { key = 'period', label = 'period', min = 1, max = 256, step = 1, fmt = '%d rows' },
  depth = { key = 'depth', label = 'depth', min = 0, max = 1, step = 0.05, fmt = '%.2f' },
  center = { key = 'center', label = 'center', min = 0, max = 1, step = 0.05, fmt = '%.2f' },
  phase = { key = 'phase', label = 'phase', min = 0, max = 1, step = 0.125, fmt = '%.3f' },
  res = { key = 'res', label = 'points', min = 4, max = 64, step = 4, fmt = '%d / period' },
  src = { key = 'src', label = 'source' },
  hits = { key = 'hits', label = 'hits', enum = { 'events', 'transients' } },
  sens = { key = 'sens', label = 'sens', min = 0, max = 1, step = 0.05, fmt = '%.2f' },
  lead = { key = 'lead', label = 'lead', min = 0.25, max = 64, step = 0.25, fmt = '%.2f rows' },
  curve = { key = 'curve', label = 'curve', min = -1, max = 1, step = 0.25, fmt = '%+.2f' },
  hold = { key = 'hold', label = 'hold', min = 0, max = 32, step = 0.25, fmt = '%.2f rows' },
  release = { key = 'release', label = 'release', min = 0.25, max = 64, step = 0.25, fmt = '%.2f rows' },
  dir = { key = 'dir', label = 'dir', enum = { 'duck', 'swell' } },
  fsrc = { key = 'fsrc', label = 'from', enum = { 'env', 'audio' } },
  attack = { key = 'attack', label = 'attack', min = 0, max = 32, step = 0.25, fmt = '%.2f rows' },
  frel = { key = 'frel', label = 'release', min = 0, max = 64, step = 0.25, fmt = '%.2f rows' },
  shift = { key = 'shift', label = 'shift', min = -16, max = 16, step = 0.25, fmt = '%+.2f rows' },
  invert = { key = 'invert', label = 'invert', toggle = true },
  ai = { key = 'ai', label = 'auto-item', button = true },          -- automation item REAPER (3 окт: «make AI» было непонятно)
  points = { key = 'points', label = 'write points', button = true },
}
local LAYOUT = {
  lfo = { 'type', 'shape', 'period', 'depth', 'center', 'phase', 'res', 'ai', 'points' },
  podkat = { 'type', 'src', 'hits', 'sens', 'lead', 'curve', 'hold', 'release', 'dir', 'depth', 'center', 'ai', 'points' },
  follow = { 'type', 'fsrc', 'src', 'attack', 'frel', 'shift', 'invert', 'depth', 'center', 'ai', 'points' },
}
-- поля текущего типа (transients — со sens, events — без)
function LG.fields()
  local out = {}
  for _, k in ipairs(LAYOUT[LG.type] or LAYOUT.lfo) do
    if not (k == 'sens' and LG.hits ~= 'transients') then out[#out + 1] = F[k] end
  end
  return out
end
LG.FIELDS = LG.fields()

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

-- Рамер — Дуглас — Пекер по { row, v }: точки, без которых линия уходит
-- больше чем на tol
local function rdp(pts, tol)
  if #pts <= 2 then return pts end
  local keep = { [1] = true, [#pts] = true }
  local function rec(a, b)
    local pa, pb = pts[a], pts[b]
    local best, bi = 0, nil
    for i = a + 1, b - 1 do
      local p = pts[i]
      local t = (pb.row - pa.row) > 0 and (p.row - pa.row) / (pb.row - pa.row) or 0
      local d = math.abs(p.v - (pa.v + (pb.v - pa.v) * t))
      if d > best then best, bi = d, i end
    end
    if bi and best > tol then keep[bi] = true; rec(a, bi); rec(bi, b) end
  end
  rec(1, #pts)
  local out = {}
  for i, p in ipairs(pts) do if keep[i] then out[#out + 1] = p end end
  return out
end
LG.rdp = rdp

local STEP = 0.125      -- шаг отсчётов, строк

-- подкат: hits — строки хитов (дробные, по возрастанию); точки на [r0, r1)
function LG.podkat_points(hits, r0, r1)
  local k = 2 ^ (LG.curve * 2)
  local tau = math.max(0.05, LG.release) / 3            -- ~5 % к концу release
  local sgn = LG.dir == 'swell' and 1 or -1
  local pts = {}
  local r = r0
  while r < r1 - 1e-9 do
    local duck = 0
    for _, h in ipairs(hits) do
      local ts = h - LG.lead
      local v = 0
      if r >= ts and r < h then v = ((r - ts) / math.max(1e-6, LG.lead)) ^ k
      elseif r >= h and r < h + LG.hold then v = 1
      elseif r >= h + LG.hold then v = math.exp(-(r - h - LG.hold) / tau); if v < 0.005 then v = 0 end end
      if v > duck then duck = v end
      if ts > r then break end
    end
    pts[#pts + 1] = { row = r, v = clamp01(LG.center + sgn * LG.depth * duck), shape = 0 }
    r = r + STEP
  end
  return rdp(pts, LG.tol)
end

-- follow: src(row) → 0..1 (main: огибающая или громкость аудио); точки на [r0, r1)
function LG.follow_points(src, r0, r1)
  local ca = LG.attack > 0 and (1 - math.exp(-STEP / LG.attack)) or 1
  local cr = LG.frel > 0 and (1 - math.exp(-STEP / LG.frel)) or 1
  local pts = {}
  local v
  local r = r0
  while r < r1 - 1e-9 do
    local x = clamp01(src(r + LG.shift) or 0)
    if LG.invert then x = 1 - x end
    if not v then v = x elseif x > v then v = v + (x - v) * ca else v = v + (x - v) * cr end
    pts[#pts + 1] = { row = r, v = clamp01(LG.center + (v * 2 - 1) * LG.depth / 2), shape = 0 }
    r = r + STEP
  end
  return rdp(pts, LG.tol)
end

-- слайдер: доля 0..1 → значение поля i (с шагом поля)
function LG.set_frac(i, fr)
  local f = LG.FIELDS[i]
  if not f or not f.min then return end
  fr = math.max(0, math.min(1, fr))
  local v = f.min + fr * (f.max - f.min)
  v = f.min + math.floor((v - f.min) / f.step + 0.5) * f.step
  LG[f.key] = math.max(f.min, math.min(f.max, v))
  if f.key == 'period' or f.key == 'res' then LG[f.key] = math.floor(LG[f.key] + 0.5) end
end
-- выбрать вариант перечисления
function LG.set_opt(i, o)
  local f = LG.FIELDS[i]
  if not f or not f.enum then return end
  LG[f.key] = o
  if f.key == 'shape' and o == 'rnd' then LG.seed = LG.seed + 1 end
  if f.key == 'type' or f.key == 'hits' then LG.FIELDS = LG.fields(); LG.sel = math.min(LG.sel, #LG.FIELDS) end
end

-- изменить поле i на d шагов (shape — по кругу)
function LG.adjust(i, d)
  local f = LG.FIELDS[i]
  if not f or f.button then return end
  if f.enum then
    local list = type(f.enum) == 'string' and LG[f.enum] or f.enum
    local k = 1
    for j, s in ipairs(list) do if s == LG[f.key] then k = j end end
    k = ((k - 1 + (d >= 0 and 1 or -1)) % #list) + 1
    LG[f.key] = list[k]
    if f.key == 'shape' and LG.shape == 'rnd' then LG.seed = LG.seed + 1 end
    if f.key == 'type' or f.key == 'hits' then LG.FIELDS = LG.fields(); LG.sel = math.min(LG.sel, #LG.FIELDS) end
    return
  end
  if f.toggle then LG[f.key] = not LG[f.key]; return end
  if f.key == 'src' then
    if LG.type == 'follow' and LG.fsrc == 'env' then return end      -- огибающая — выбором (Enter, main)
    local n = math.max(1, #LG.src_names)
    LG.src_i = ((LG.src_i - 1 + (d >= 0 and 1 or -1)) % n) + 1
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
  -- 6 окт: h l — шаг, Shift (H L) — мелкий шаг; назад — Esc
  if c == 27 then return 'leave' end
  if ch == 'j' or c == DOWN then LG.sel = math.min(#LG.FIELDS, LG.sel + 1)
  elseif ch == 'k' or c == UP then LG.sel = math.max(1, LG.sel - 1)
  elseif ch == 'l' or c == RIGHT or ch == '+' or ch == '=' then LG.adjust(LG.sel, mult)
  elseif ch == 'h' or c == LEFT or ch == '-' then LG.adjust(LG.sel, -mult)
  elseif ch == 'L' then LG.adjust(LG.sel, 0.1)
  elseif ch == 'H' then LG.adjust(LG.sel, -0.1)
  elseif c == 13 or ch == ' ' then
    local f = LG.FIELDS[LG.sel]
    if f.button then return f.key end
    if f.key == 'src' and LG.type == 'follow' and LG.fsrc == 'env' then return 'pick' end
    LG.adjust(LG.sel, 1)
  elseif ch == 'g' then return 'ai'
  elseif ch == 'p' then return 'points'
  else return false end
  return true
end

local function field_text(f)
  if f.button then return '' end
  if f.enum then return tostring(LG[f.key]) end
  if f.toggle then return LG[f.key] and 'on' or 'off' end
  if f.key == 'src' then
    if LG.type == 'follow' and LG.fsrc == 'env' then return LG.src_env or 'Enter: pick envelope' end
    return LG.src_names[LG.src_i] or '(no tracks)'
  end
  return f.fmt:format(f.fmt:find('%%d') and math.floor(LG[f.key] + 0.5) or LG[f.key])   -- 21 окт: дробное с %d
end

-- отрисовка в (x, y, w, h); hover = { field = i } | { preview = true }
function LG.draw(U, L, x, y, w, h, focused, fit, target, span)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local hover
  U.text(x, y, fit(LG.type .. ' -> ' .. (target or 'envelope at the cursor'), w), focused and U.AMBER or U.GREY)
  local fy = y + L.rh + 2
  -- ширина подписей — по самой длинной видимой (6 окт: release налезал на слайдер)
  local lw = U.measure('points ')
  for _, f in ipairs(LG.FIELDS) do if not f.button then lw = math.max(lw, U.measure(f.label .. ' ')) end end
  lw = lw + L.pad
  -- поля (3 окт): перечисления — кнопками (форма волны, тип, хиты…), числа —
  -- горизонтальными слайдерами (тянуть по горизонтали), тумблеры — кнопкой
  for i, f in ipairs(LG.FIELDS) do
    local ry = fy + (i - 1) * L.rh
    if ry + L.rh > y + h then break end
    local sel = focused and LG.sel == i
    local hot = mx >= x and mx < x + w and my >= ry and my < ry + L.rh
    local function button(bx, label, on, hv)
      local bw = U.measure(label) + 2 * L.pad
      local bh = hot and mx >= bx and mx < bx + bw
      U.set(on and U.tint(U.AMBER, 0.35) or (bh and U.tint(U.AMBER, 0.18) or U.BG)); gfx.rect(bx, ry, bw, L.rh - 1, 1)
      U.set((on or bh) and U.AMBER or U.LINE); gfx.rect(bx, ry, bw, L.rh - 1, 0)
      U.text(bx + L.pad, ry, label, on and U.AMBER or (bh and U.TEXT or U.GREY))
      if bh then hover = hv end
      return bx + bw + 2
    end
    if f.button then
      button(x, f.label, sel, { field = i })
    else
      if sel or hot then U.set(U.tint(U.AMBER, sel and 0.12 or 0.07)); gfx.rect(x, ry, w, L.rh, 1) end
      U.text(x, ry + 1, f.label, (sel or hot) and U.AMBER or U.GREY)
      local x0, aw = x + lw, w - lw
      if f.enum then
        local list = type(f.enum) == 'string' and LG[f.enum] or f.enum
        local need = 0
        for _, o in ipairs(list) do need = need + U.measure(o) + 2 * L.pad + 2 end
        if need <= aw then
          local bx = x0
          for _, o in ipairs(list) do bx = button(bx, o, LG[f.key] == o, { field = i, opt = o }) end
        else
          -- не влезают все — текущая кнопкой, клик листает
          button(x0, tostring(LG[f.key]), true, { field = i, cycle = true })
        end
      elseif f.toggle then
        button(x0, LG[f.key] and 'on' or 'off', LG[f.key], { field = i, cycle = true })
      elseif f.key == 'src' then
        button(x0, fit(field_text(f), aw - 2 * L.pad), false, { field = i, cycle = true })
      else
        -- слайдер: дорожка, заливка до значения, число справа
        local vt = field_text(f)
        local vw = math.min(U.measure(vt) + L.pad, math.floor(aw * 0.45))
        local sw = math.max(8, math.min(L.cw * 12, aw - vw - L.pad))   -- 6 окт: слайдеры уже
        local fr = (LG[f.key] - f.min) / math.max(1e-9, f.max - f.min)
        local cy = ry + math.floor(L.rh / 2)
        U.set(U.DIM); gfx.rect(x0, cy - 1, sw, 2, 1)
        U.set((sel or hot) and U.AMBER or U.TEXT); gfx.rect(x0, ry + 3, math.max(1, math.floor(fr * sw + 0.5)), L.rh - 6, 1)
        U.text(x0 + sw + L.pad, ry + 1, fit(vt, vw), (sel or hot) and U.AMBER or U.TEXT)
        if hot and mx >= x0 - 2 and mx < x0 + sw + 2 then hover = { field = i, slider = true, x = x0, w = sw } end
      end
      if hot and not hover then hover = { field = i } end
    end
  end
  -- предпросмотр (5 окт): ровно то, что запишется — длина цели в строках
  -- (span: item / time selection / регион / такт), волна от её начала;
  -- без цели — два периода
  local py = fy + #LG.FIELDS * L.rh + 4
  local ph = y + h - py
  if LG.type == 'lfo' and ph >= 3 * L.rh / 2 and w > 16 then
    U.set(U.PANEL); gfx.rect(x, py, w, ph, 1)
    U.set(U.LINE); gfx.rect(x, py, w, ph, 0)
    local n = (span and span > 0) and span or (LG.period * 2)
    local pts = LG.points(0, n)
    local function px(row) return x + 1 + math.floor(row / n * (w - 3)) end
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
