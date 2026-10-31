-- jf_tracker_autocanvas.lua — холст автоматизации (15 окт): страница curve вкладки automation.
--
-- { } — клетка сетки; L P — страницы curves / params (main).
-- X — строки трекера на отрезке (time selection → регион курсора → такт), Y — значение 0..1.
-- Несколько кривых наложением (активная ярко, остальные тускло), курсор — строка; значение
-- берётся с активной кривой. Клавиши пишут точки сразу: j k — ±1/16 (J K — 1/128), 0-9 —
-- уровень, x — убрать, v — якорь диапазона, f r R s t q n — заливка формы по сетке (flat, ramp
-- up / down, sine, tri, square, noise), [ ] — сетка, Tab — активная кривая, w b — точки.
-- Активна кривая модуляции (kind lfo / acs) — те же клавиши правят LFO: s t q r R n форма,
-- [ ] скорость, j k сила, w b фаза.
--
-- Дескриптор кривой (строит main): { kind = 'env'|'take'|'pool'|'lfo'|'acs', name, rgb,
--   write (bool), eval(t) → 0..1, points = { {t, v01} … } (активной), mod = { v = {...} } }.
-- Без reaper.* — тест tests/test_autocanvas.lua. Записи делает main через ctx.acv_do(op).

local function clamp01(v) return math.max(0, math.min(1, v)) end
local ACV = { row = 0, anchor = nil, grid = 4, cur = 1, seed = 1 }
-- 30 окт: инструменты мыши — cur (щелчок ставит курсор), draw (карандаш, d), line (прямая, D), erase (E);
-- snap (S) — мазок по клеткам сетки, иначе по строкам. Мазок — превью ACV.stroke, запись при отпускании (main)
ACV.tool, ACV.snap = 'cur', true
ACV.TOOLS = { { 'cur', 'cur' }, { 'draw', 'draw' }, { 'line', 'line' }, { 'shape', 'shape' }, { 'erase', 'erase' }, { 'sel', 'sel' } }
-- 31 окт: цикл формы — в строках, независимо от сетки (сетка 1/8 строки давала синус в 1 строку — мелочь);
-- Opt при мазке shape — вверх / вниз меняет частоту; кнопка ~N в заголовке — список
ACV.cycle = 4
ACV.CYCLES = { 0.5, 1, 2, 4, 8, 16, 32, 64 }
-- 30 окт: инструмент shape (c) — как рисование формами в Ableton: протяжка задаёт отрезок, форма повторяется в каждой
-- клетке сетки, высота — вертикалью мыши; форма — кнопкой рядом (список)
ACV.shape = 'sin'
-- 30 окт: подписи кнопок — буквы со знаком (без нарисованных кривых): ~ sin, ^ tri, / пила вверх, \ вниз, ? случай
ACV.SHAPE_LIST = { { 's', 'sin', '~sin' }, { 't', 'tri', '^tri' }, { 'r', 'ramp+', '/swup' }, { 'R', 'ramp-', '\\swdn' },
  { 'e', 'exp', 'exp' }, { 'l', 'log', 'log' }, { 'q', 'sqr', '[sqr' }, { 'n', 'rnd', '?rnd' } }
function ACV.shape_name(sh) for _, x in ipairs(ACV.SHAPE_LIST) do if x[2] == sh then return x[3] end end; return sh end
-- мазок формой от строки ra до rb (включая клетку rb), высота v
function ACV.shape_stroke(ra, rb, v)
  local st = ACV.snap and ACV.grid or 1
  local a, b = math.min(ra, rb), math.max(ra, rb) + math.max(st, 1)
  local out = {}
  for _, p in ipairs(ACV.shape_points(ACV.shape, a, b, ACV.cycle, v, ACV.seed)) do out[p.row] = p.v end
  return out, a, b
end
ACV.stroke = nil   -- { rows = { [row] = v01 | false }, line = { x0, y0, x1, y1 } — пиксели: нажатие → мышь (инструмент line) }
-- точка холста → строка (с привязкой к сетке) и значение 0..1; g — геометрия из hover (gx gy gw gh r0 nr)
function ACV.at(g, mx, my)
  local row = g.r0 + (mx - g.gx) / math.max(1, g.gw) * g.nr
  row = math.max(g.r0, math.min(g.r0 + g.nr - 1e-6, row))
  -- 30 окт: сетка бывает мельче строки (1/2 … 1/8) — точки между строками; без snap — целые строки
  if ACV.snap then local st = ACV.grid; row = g.r0 + math.floor((row - g.r0) / st + 1e-9) * st else row = math.floor(row) end
  local v = 1 - (my - g.gy - 2) / math.max(1, g.gh - 4)
  return row, clamp01(v)
end
-- строки мазка между двумя точками (линейно по значению); шаг — клетка сетки при snap, иначе строка
function ACV.span_rows(ra, va, rb, vb, out, erase)
  local st = ACV.snap and ACV.grid or 1
  if rb < ra then ra, rb, va, vb = rb, ra, vb, va end
  local n = 0
  for r = ra, rb, st do
    local f = rb > ra and (r - ra) / (rb - ra) or 0
    if erase then out[r] = false else out[r] = va + (vb - va) * f end   -- не «erase and false or …»: and false в Lua проваливается в or
    n = n + 1
    if n > 4000 then break end
  end
  return out
end

-- 31 окт: выделение и трансформация (sel, T), как transform-рамка автоматизации в Ableton: ACV.sel = { a, b } —
-- строки; рамка — от min до max значений точек в них; ромбы: углы — наклон верха / низа, середины сторон —
-- растяжка по времени (l r) и по значению (t b), внутри — сдвиг. Превью ACV.xprev, запись при отпускании
ACV.sel, ACV.xprev = nil, nil
-- 31 окт: несколько кривых сразу (Shift+щелчок в списке) — дорожками друг под другом; ключ — огибающая или имя
ACV.multi = {}
function ACV.mkey(cv) return cv and (cv.env or cv.name) or nil end
-- точки активной кривой в строках [a, b): { row, v } (act.points — { время, 0..1 })
function ACV.sel_points(act, span, a, b)
  local out = {}
  for _, p in ipairs(act and act.points or {}) do
    local r = span.row_of(p[1])
    if r >= a - 1e-6 and r < b - 1e-6 then out[#out + 1] = { row = r, v = p[2] } end
  end
  return out
end
function ACV.box_of(pts, a, b)
  local lo, hi = math.huge, -math.huge
  for _, p in ipairs(pts) do lo = math.min(lo, p.v); hi = math.max(hi, p.v) end
  if lo > hi then return nil end
  return { a = a, b = b, lo = lo, hi = hi }
end
-- точки после ручки h (move l r t b tl tr bl br) со сдвигом dr строк / dv значения
function ACV.xform(pts, box, h, dr, dv)
  local a, b, lo, hi = box.a, box.b, box.lo, box.hi
  local w, hh = math.max(1e-9, b - a), hi - lo
  local out = {}
  for _, p in ipairs(pts) do
    local r, v = p.row, p.v
    if h == 'move' then r, v = r + dr, v + dv
    elseif h == 'l' then local na = math.min(b - 0.125, a + dr); r = b - (b - r) * (b - na) / w
    elseif h == 'r' then local nb = math.max(a + 0.125, b + dr); r = a + (r - a) * (nb - a) / w
    else
      local f = (r - a) / w
      local dt, db = 0, 0
      if h == 't' then dt = dv elseif h == 'b' then db = dv
      elseif h == 'tl' then dt = dv * (1 - f) elseif h == 'tr' then dt = dv * f
      elseif h == 'bl' then db = dv * (1 - f) elseif h == 'br' then db = dv * f end
      if hh < 1e-6 then v = v + dt + db                            -- ровная линия: верх = низ, просто сдвиг
      else local nlo, nhi = lo + db, hi + dt; v = nlo + (v - lo) / hh * (nhi - nlo) end
    end
    out[#out + 1] = { row = math.max(0, r), v = clamp01(v) }
  end
  return out
end
-- humanize: значения ± amt (0..1) случайно, seed — другой разброс на каждый щелчок
function ACV.humanize(pts, amt, seed)
  local out = {}
  for k, p in ipairs(pts) do out[k] = { row = p.row, v = clamp01(p.v + (ACV.rnd(k, seed or 1) * 2 - 1) * amt) } end
  return out
end
-- старые точки → новые: строки для op put (MIDI-лейн — целые строки: старые стереть, новые поверх) и отрезок
-- замены a..b (огибающая: точки в нём удаляются, новые вставляются)
function ACV.replace_rows(old, new, box, ml)
  local map = {}
  local a, b = box.a, box.b
  if ml then for _, p in ipairs(old) do map[math.floor(p.row + 1e-9)] = false end end
  for _, p in ipairs(new) do
    local r = ml and math.floor(p.row + 1e-9) or p.row
    map[r] = p.v
    a = math.min(a, r); b = math.max(b, r + 1 / 64)
  end
  return map, a, b
end
local U, ctx, LG

function ACV.init(u, c, lg) U, ctx, LG = u, c, lg end

-- буква → форма заливки (мнемоники: flat, ramp, Ramp down, sine, triangle, square, noise)
ACV.SHAPES = { f = 'flat', r = 'ramp+', R = 'ramp-', s = 'sin', t = 'tri', q = 'sqr', n = 'rnd' }
-- форма LFO REAPER: 0 sin 1 sqr 2 saw< 3 saw> 4 tri 5 rnd (как SHAPES в jf_tracker_modmatrix)
ACV.LFO_SHAPE = { s = 0, q = 1, R = 2, r = 3, t = 4, n = 5 }
ACV.LFO_NAMES = { [0] = 'sin', 'sqr', 'saw<', 'saw>', 'tri', 'rnd' }

local function rnd(k, seed)
  local x = math.sin((k + 1) * 12.9898 + seed * 78.233) * 43758.5453
  return x - math.floor(x)
end
ACV.rnd = rnd   -- 31 окт: для humanize выше по файлу

-- подпись сетки: доля такта (lpb строк на долю, 4 доли) или строки
function ACV.grid_label(grid, lpb)
  local bar = (lpb or 4) * 4
  if grid < 1 then return '1/' .. math.floor(bar / grid + 0.5) end   -- 30 окт: мельче строки
  if bar % grid == 0 then return '1/' .. (bar // grid) end
  return grid .. ' rows'
end

-- диапазон заливки: якорь…курсор (включая обе строки), иначе клетка сетки под курсором
function ACV.range(st, snap)
  local r0, r1 = st.r0 or 0, st.r1 or (ACV.row + 1)
  if ACV.anchor then
    local a, b = math.min(ACV.anchor, ACV.row), math.max(ACV.anchor, ACV.row) + 1
    if snap then local g = math.max(1, ACV.grid); b = a + math.ceil((b - a) / g) * g end   -- заливка — целыми клетками (форма не сжимается в хвост)
    return math.max(r0, a), math.min(r1, b)
  end
  local g = math.max(1, ACV.grid)
  local a = r0 + math.floor((ACV.row - r0) / g) * g
  return a, math.min(r1, a + g)
end

-- точки формы на [r0, r1) по клеткам сетки: { {row, v (0..1), shape (0 lin / 1 sqr)} … };
-- уровень = верх формы (как shape01 в aiedit: от 0 до level)
function ACV.shape_points(shape, r0, r1, grid, level, seed)
  local out = {}
  local g = math.max(0.125, grid or 1)
  level = clamp01(level or 1)
  local function add(row, v, shp) if row >= r0 - 1e-9 and row < r1 - 1e-9 then out[#out + 1] = { row = row, v = clamp01(v), shape = shp or 0 } end end
  local k = 0
  local a = r0
  while a < r1 - 1e-9 do
    local b = math.min(r1, a + g)
    local wdt = b - a
    if shape == 'flat' then add(a, level, 1)
    elseif shape == 'ramp+' then add(a, 0, 0); add(a + wdt * 0.98, level, 0)
    elseif shape == 'ramp-' then add(a, level, 0); add(a + wdt * 0.98, 0, 0)
    elseif shape == 'sqr' then add(a, level, 1); add(a + wdt / 2, 0, 1)
    elseif shape == 'rnd' then add(a, rnd(k, seed or 1) * level, 1)
    elseif shape == 'exp' or shape == 'log' then   -- 30 окт: изгиб, как у Ableton: exp — медленно, потом круто; log — наоборот
      local n, kk = 8, 4
      for i = 0, n - 1 do
        local x = i / n
        local w = shape == 'exp' and (math.exp(kk * x) - 1) / (math.exp(kk) - 1) or math.log(1 + (math.exp(kk) - 1) * x) / kk
        add(a + wdt * x, w * level, 0)
      end
      add(a + wdt * 0.98, level, 0)
    elseif shape == 'sin' or shape == 'tri' then
      local n = 8
      for i = 0, n - 1 do
        local x = i / n
        local w = LG and LG.wave(shape, x) or 0
        if shape == 'sin' then w = -math.cos(2 * math.pi * x) end          -- начало клетки — низ (как shape01)
        add(a + wdt * x, (w + 1) / 2 * level, 0)
      end
    end
    k = k + 1
    a = a + g
  end
  return out
end

-- предсказанная полоса LFO REAPER вокруг базового значения base (0..1) в момент t (с):
-- lo, hi (границы по силе и направлению), v (значение волны сейчас). mod.v — поля param.N.lfo.*;
-- bpb — ударов в секунду для temposync (скорость тогда — в долях такта за цикл)
function ACV.lfo_band(mod, t, base, bps)
  local v = mod and mod.v or {}
  local str = clamp01(v['lfo.strength'] or 1)
  local dir = v['lfo.dir'] or 0                 -- −1 вниз, 0 вокруг, 1 вверх
  local shape = math.floor(v['lfo.shape'] or 0)
  local speed = v['lfo.speed'] or 1
  local phase = v['lfo.phase'] or 0
  local x
  if (v['lfo.temposync'] or 0) >= 0.5 then x = t * (bps or 2) * speed + phase   -- пробник 15 окт: speed — циклов на долю
  else x = t * speed + phase end
  x = x % 1
  local w
  if shape == 0 then w = math.sin(2 * math.pi * x)
  elseif shape == 1 then w = x < 0.5 and 1 or -1
  elseif shape == 2 then w = 1 - 2 * x
  elseif shape == 3 then w = 2 * x - 1
  elseif shape == 4 then w = x < 0.25 and 4 * x or (x < 0.75 and 2 - 4 * x or 4 * x - 4)
  else w = rnd(math.floor(t * speed), 7) * 2 - 1 end
  local lo, hi
  if dir > 0 then lo, hi = base, base + str
  elseif dir < 0 then lo, hi = base - str, base
  else lo, hi = base - str / 2, base + str / 2 end
  local val = lo + (w + 1) / 2 * (hi - lo)
  return clamp01(lo), clamp01(hi), clamp01(val)
end

-- полоса модуляции кривой cv (kind lfo / acs) вокруг base: ACS — вверх от базы на силу, без волны
function ACV.mod_band(cv, t, base, bps)
  if cv.kind == 'acs' then local str = clamp01(cv.mod and cv.mod.v and cv.mod.v['acs.strength'] or 1); return base, clamp01(base + str), base end
  return ACV.lfo_band(cv.mod, t, base, bps)
end

-- клавиши; st = { r0, r1, lpb, ncurves, kind (активной кривой) }; mods = { shift, ... }
-- → true (съедена, состояние изменено), false (не моя), { op = … } (main пишет)
function ACV.key(c, st, mods)
  local ch = (c > 0 and c < 256) and string.char(c) or ''
  local shift = mods and mods.shift
  local r0, r1 = st.r0 or 0, st.r1 or (st.r0 or 0) + 16
  local lfo = st.kind == 'lfo' or st.kind == 'acs'
  local function clamp_row() ACV.row = math.max(r0, math.min(r1 - 1, ACV.row)) end
  -- 15 окт: zp — весь проект / отрезок (такт, регион, time selection)
  if ACV.zpend then
    ACV.zpend = nil
    if ch == 'p' then ACV.proj = not ACV.proj; return true end
    if c == 27 then return true end
    return false
  end
  if ch == 'z' then ACV.zpend = true; return true end
  -- 30 окт: инструменты мыши и привязка
  if ch == 'd' then ACV.tool = ACV.tool == 'draw' and 'cur' or 'draw'; return true end
  if ch == 'D' then ACV.tool = ACV.tool == 'line' and 'cur' or 'line'; return true end
  if ch == 'E' then ACV.tool = ACV.tool == 'erase' and 'cur' or 'erase'; return true end
  if ch == 'c' then ACV.tool = ACV.tool == 'shape' and 'cur' or 'shape'; return true end
  if ch == 'S' then ACV.snap = not ACV.snap; return true end
  if ch == 'T' then ACV.tool = ACV.tool == 'sel' and 'cur' or 'sel'; return true end   -- 31 окт: transform
  if ch == '/' then return { op = 'addp' } end   -- 31 окт: параметр трека в список (нечёткий поиск)
  if c == 27 then
    if ACV.anchor then ACV.anchor = nil; return true end
    if ACV.sel then ACV.sel = nil; return true end
    return { op = 'leave' }
  elseif ch == 'h' or c == 1818584692 then ACV.row = ACV.row - 1; clamp_row(); return true
  elseif ch == 'l' or c == 1919379572 then ACV.row = ACV.row + 1; clamp_row(); return true
  elseif ch == '{' then ACV.row = ACV.row - math.max(1, ACV.grid); clamp_row(); return true   -- 15 окт: клетка — { } (L P — страницы, как в подсказке)
  elseif ch == '}' then ACV.row = ACV.row + math.max(1, ACV.grid); clamp_row(); return true
  elseif ch == 'g' then ACV.row = r0; return true
  elseif ch == 'G' then ACV.row = r1 - 1; return true
  elseif c == 9 then                                            -- Tab / Shift+Tab — кривая
    local n = math.max(1, st.ncurves or 1)
    ACV.cur = (ACV.cur - 1 + (shift and -1 or 1)) % n + 1
    return true
  elseif ch == 'v' then ACV.anchor = ACV.anchor and nil or ACV.row; return true
  elseif ch == '[' or ch == ']' then
    if lfo then return { op = 'lfo', key = 'lfo.speed', mul = ch == '[' and 0.5 or 2 } end
    local g = ACV.grid
    -- 30 окт: мельче строки — до 1/8 строки (точки между строками огибающей)
    if ch == '[' then g = g > 1 and g // 2 or math.max(0.125, g / 2) else g = math.min((st.lpb or 4) * 4, g * 2) end
    ACV.grid = g
    return true
  elseif ch == 'w' or ch == 'b' then
    if lfo then return { op = 'lfo', key = 'lfo.phase', d = ch == 'w' and 0.125 or -0.125 } end
    return { op = 'point', d = ch == 'w' and 1 or -1 }
  elseif ch == 'j' or ch == 'k' or ch == 'J' or ch == 'K' or c == 1685026670 or c == 30064 then
    local up = ch == 'k' or ch == 'K' or c == 30064
    if lfo then return { op = 'lfo', key = st.kind == 'acs' and 'acs.strength' or 'lfo.strength', d = up and 0.05 or -0.05 } end
    local step = (shift or ch == 'J' or ch == 'K') and 1 / 128 or 1 / 16
    return { op = 'nudge', d = up and step or -step }
  elseif ch:match('^%d$') then
    if lfo then return false end
    return { op = 'level', v = tonumber(ch) / 10 }
  elseif ch == 'x' or c == 8 then
    if lfo then return false end
    return { op = 'del' }
  elseif ACV.SHAPES[ch] then
    if lfo then
      if ch == 'f' then return false end
      return { op = 'lfo', key = 'lfo.shape', val = ACV.LFO_SHAPE[ch] }
    end
    return { op = 'fill', shape = ACV.SHAPES[ch] }
  elseif ch == 'm' then return { op = 'mod', what = 'lfo' }
  elseif ch == 'e' then return { op = 'mod', what = 'acs' }
  end
  return false
end

-- раскладка: легенда справа столбиком при ширине, иначе строкой сверху
function ACV.layout(L, w, h, n)
  local cw, rh = L.cw, L.rh
  local side = w >= cw * 60
  -- 31 окт: список кривых — слева, пошире (параметры читаются); + строка «/ add» — поиск параметра трека
  local lw = side and math.min(math.floor(w * 0.24), cw * 34) or 0
  local top = rh + 2                                              -- строка заголовка (сетка, отрезок)
  if not side then top = top + rh end                             -- легенда — второй строкой
  local gx, gy, gw, gh = side and (lw + L.pad) or 0, top, w - lw - (side and L.pad or 0), h - top - 2
  return { side = side, lw = lw, gx = gx, gy = gy, gw = gw, gh = gh, legend_rows = math.max(1, math.floor(gh / rh)) }
end

-- рисование внутри (x, y, w, h). span = { r0, r1, t0, t1, time = fn(row)→t, lpb, sc, bps, label }
-- → hover { pane = 'curve', curve_t, row, legend = i } | nil
function ACV.draw(Lx, x, y, w, h, curves, span, focused)
  local rh, pad = Lx.rh, Lx.pad
  local n = #curves
  if n == 0 then
    U.text(x + pad, y + 2, ctx.fit('curve: put the cursor on an envelope lane (or Opt+A on a knob) - the canvas shows it; Tab - other curves of the track', w - 2 * pad), U.GREY)
    return nil
  end
  if ACV.cur > n then ACV.cur = 1 end
  local lay = ACV.layout(Lx, w, h, n)
  local gx, gy, gw, gh = x + lay.gx, y + lay.gy, lay.gw, lay.gh
  if gw < 10 or gh < 10 then return nil end
  local r0, r1 = span.r0, span.r1
  local nr = math.max(1, r1 - r0)
  ACV.row = math.max(r0, math.min(r1 - 1, ACV.row))
  local act = curves[ACV.cur]
  local function rx(row) return gx + math.floor((row - r0) / nr * gw + 0.5) end
  local function vy(v) return gy + gh - 2 - math.floor(clamp01(v) * (gh - 4) + 0.5) end
  ACV.geo = { gx = gx, gy = gy, gw = gw, gh = gh, r0 = r0, nr = nr }   -- 30 окт: для рисования пальцем (CONTROL)
  -- заголовок: активная кривая, отрезок, сетка
  -- 30 окт: панель инструментов справа в строке заголовка (буквами): cur draw line erase | snap | [ сетка ]
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local ox, oy = U.mouse_off and U.mouse_off[1] or 0, U.mouse_off and U.mouse_off[2] or 0
  local hover
  local tb = {}
  for _, t in ipairs(ACV.TOOLS) do tb[#tb + 1] = { lab = t[2], tool = t[1], on = ACV.tool == t[1] } end
  -- 30 окт: формы — все кнопками в ряд (выбор формы = инструмент shape); не влезает — одна кнопка со списком
  local shapes_at = #tb + 1
  for i, x in ipairs(ACV.SHAPE_LIST) do tb[#tb + 1] = { lab = x[3], shape = x[2], on = ACV.tool == 'shape' and ACV.shape == x[2], gap = i == 1 } end
  local shapes_n = #ACV.SHAPE_LIST
  tb[#tb + 1] = { lab = '~' .. ACV.grid_label(ACV.cycle, span.lpb), cyc = true }   -- 31 окт: цикл формы
  tb[#tb + 1] = { lab = 'hum', hum = true, gap = true }                                -- 31 окт: humanize выделения / клетки
  tb[#tb + 1] = { lab = 'snap', snap = true, on = ACV.snap, gap = true }
  tb[#tb + 1] = { lab = '[', grid = -1, gap = true }
  tb[#tb + 1] = { lab = ACV.grid_label(ACV.grid, span.lpb), grid = 0 }
  tb[#tb + 1] = { lab = ']', grid = 1 }
  local function width() local t = 0; for _, b in ipairs(tb) do b.w = U.measure(b.lab) + 2 * pad; t = t + b.w + 2 + (b.gap and pad or 0) end; return t end
  local tw = width()
  -- 31 окт: формы всегда кнопками; не влезают рядом с именем — панель второй строкой над холстом (поле ниже на строку);
  -- и там не влезают — одна кнопка формы со списком
  local two = w - 2 * pad - tw < U.measure('W') * 12
  -- раскладка кнопок построчно (перенос по ширине холста): b.bx, b.row
  local nrow = 0
  if two then
    local bx, row = x + pad, 1
    for _, b in ipairs(tb) do
      local need = b.w + 2 + (b.gap and pad or 0)
      if bx + need > x + w - pad and bx > x + pad then row = row + 1; bx = x + pad end
      if b.gap and bx > x + pad then bx = bx + pad end
      b.bx, b.row = bx, row
      bx = bx + b.w + 2
    end
    nrow = row
  else
    local bx = x + w - pad - tw
    for _, b in ipairs(tb) do if b.gap then bx = bx + pad end; b.bx, b.row = bx, 0; bx = bx + b.w + 2 end
  end
  if nrow > 0 then gy = gy + nrow * rh; gh = gh - nrow * rh; ACV.geo = { gx = gx, gy = gy, gw = gw, gh = gh, r0 = r0, nr = nr } end
  local head = ('%s   %s%s'):format(act.name or 'curve', span.label or '',
    ACV.anchor and ('   v %d..%d'):format(math.min(ACV.anchor, ACV.row), math.max(ACV.anchor, ACV.row)) or '')
  local showtb = gh >= 10
  U.text(x + pad, y + 1, ctx.fit(head, w - 2 * pad - (two and 0 or tw + pad)), focused and U.AMBER or U.CYAN)
  if showtb then
    for _, b in ipairs(tb) do
      local bx, ty = b.bx, y + b.row * rh
      local hot = mx >= bx and mx < bx + b.w and my >= ty and my < ty + rh - 1
      if b.on then U.set(U.tint(U.AMBER, 0.3)); gfx.rect(bx, ty, b.w, rh - 1, 1) end
      U.set(hot and U.AMBER or (b.on and U.AMBER or U.LINE)); gfx.rect(bx, ty, b.w, rh - 1, 0)
      U.text(bx + pad, ty, b.lab, (hot or b.on) and U.AMBER or (b.grid == 0 and U.TEXT or U.GREY))
      if hot then hover = { pane = 'curve', tbtool = b.tool, tbsnap = b.snap, tbgrid = b.grid, tbshape = b.shapepick, tbshapeset = b.shape, tbcyc = b.cyc, tbhum = b.hum } end
    end
  end
  -- поле
  U.set(U.BG); gfx.rect(gx, gy, gw, gh, 1)
  -- сетка: клетки тускло, такты ярче; уровни 25 / 50 / 75
  local bar = (span.lpb or 4) * 4
  local g = math.max(1, ACV.grid)
  local dense = gw / nr * g < 3                                  -- проект целиком: клетки сливаются — только такты
  for row = r0, r1 - 1 do
    local d = row - r0
    if d % g == 0 and (not dense or d % bar == 0) then U.set(U.mix(U.LINE, U.BG, (d % bar == 0) and 0.2 or 0.6)); gfx.rect(rx(row), gy, 1, gh, 1) end
  end
  -- 28 окт: границы паттернов (ярче тактов) и секций (цветом, с именем) — сетка по горизонтали, как в трекере
  for _, mk in ipairs(span.marks or {}) do
    local mx0 = rx(mk.row)
    if mk.kind == 'sec' then
      U.set(U.CYAN); gfx.rect(mx0, gy, 2, gh, 1)
      if mk.name ~= '' then U.text(mx0 + 3, gy + 1, ctx.fit(mk.name, math.max(0, gx + gw - mx0 - 4)), U.CYAN) end
    else
      U.set(U.mix(U.LINE, U.TEXT, 0.35)); gfx.rect(mx0, gy, 1, gh, 1)
      if gw / math.max(1, #(span.marks or {})) > 30 and mk.name ~= '' then U.text(mx0 + 2, gy + gh - rh, ctx.fit(mk.name, 40), U.GREY) end
    end
  end
  U.set(U.mix(U.LINE, U.BG, 0.65))
  for _, f in ipairs({ 0.25, 0.5, 0.75 }) do gfx.rect(gx, vy(f), gw, 1, 1) end
  -- диапазон v
  if ACV.anchor then
    local a, b = ACV.range(span)
    U.set(U.AMBER, 0.12); gfx.rect(rx(a), gy, math.max(1, rx(b) - rx(a)), gh, 1)
  end
  -- кривые: тусклые сначала, активная поверх; кэш отсчётов по столбцам
  local cache = ACV.cache
  if not cache or cache.sc ~= span.sc or cache.gw ~= gw or cache.t0 ~= span.t0 or cache.t1 ~= span.t1 or cache.n ~= n then
    cache = { sc = span.sc, gw = gw, t0 = span.t0, t1 = span.t1, n = n, ys = {} }
    for i, cv in ipairs(curves) do
      local ys = {}
      for px = 0, gw - 1 do
        local t = span.t0 + (span.t1 - span.t0) * px / math.max(1, gw - 1)
        local ok, v = pcall(cv.eval, t)
        ys[px] = ok and clamp01(v or 0) or 0
      end
      cache.ys[i] = ys
    end
    ACV.cache = cache
  end
  local function trace(i, col, alpha)
    local ys = cache.ys[i]
    if not ys then return end
    U.set(col, alpha)
    local px, py
    for k = 0, gw - 1 do
      local yy = vy(ys[k])
      if px then gfx.line(px, py, gx + k, yy) end
      px, py = gx + k, yy
    end
    gfx.a = 1
  end
  -- 31 окт: выбрано несколько — поле делится на дорожки (сверху вниз по списку); правится активная (её дорожка),
  -- щелчок по чужой дорожке — она активная
  local fy0, fh0 = gy, gh
  local stack, lane_hover
  for i, cv in ipairs(curves) do if i == ACV.cur or ACV.multi[ACV.mkey(cv)] then stack = stack or {}; stack[#stack + 1] = i end end
  if stack and #stack < 2 then stack = nil end
  if stack then
    local lh = math.floor(fh0 / #stack)
    local ay, ah = fy0, fh0
    for k, i in ipairs(stack) do
      local ly0, lh0 = fy0 + (k - 1) * lh, lh - 2
      if k > 1 then U.set(U.LINE); gfx.rect(gx, ly0 - 1, gw, 1, 1) end
      if i == ACV.cur then ay, ah = ly0, lh0
      else
        gy, gh = ly0, lh0
        local cv = curves[i]
        trace(i, cv.rgb or U.GREEN, 1)
        U.set(cv.rgb or U.GREEN)
        for _, p in ipairs(cv.points or {}) do
          local row = span.row_of and span.row_of(p[1]) or r0
          if row >= r0 and row <= r1 then gfx.rect(rx(row) - 1, vy(p[2]) - 1, 3, 3, 1) end
        end
        U.text(gx + 3, gy + 1, ctx.fit(cv.name or '?', gw - 6), U.GREY)
        if mx >= gx and mx < gx + gw and my >= gy and my < gy + gh then lane_hover = i end
      end
    end
    gy, gh = ay, ah
    ACV.geo = { gx = gx, gy = gy, gw = gw, gh = gh, r0 = r0, nr = nr }
    U.text(gx + 3, gy + 1, ctx.fit(act.name or '?', gw - 6), U.AMBER)
  else
    for i, cv in ipairs(curves) do if i ~= ACV.cur then trace(i, U.mix(cv.rgb or U.GREEN, U.BG, 0.5), 1) end end
  end
  -- полоса модуляции активной LFO / ACS кривой — вокруг её базы
  if (act.kind == 'lfo' or act.kind == 'acs') and act.mod then
    U.set(act.rgb or U.CYAN, 0.18)
    for px = 0, gw - 1, 2 do
      local t = span.t0 + (span.t1 - span.t0) * px / math.max(1, gw - 1)
      local base = cache.ys[ACV.cur] and cache.ys[ACV.cur][px] or 0.5
      local lo, hi = ACV.mod_band(act, t, base, span.bps)
      gfx.rect(gx + px, vy(hi), 2, math.max(1, vy(lo) - vy(hi)), 1)
    end
    gfx.a = 1
    -- предсказанная волна LFO тонкой линией
    if act.kind == 'lfo' then
      U.set(act.rgb or U.CYAN, 0.8)
      local px0, py0
      for px = 0, gw - 1 do
        local t = span.t0 + (span.t1 - span.t0) * px / math.max(1, gw - 1)
        local base = cache.ys[ACV.cur] and cache.ys[ACV.cur][px] or 0.5
        local _, _, vv = ACV.lfo_band(act.mod, t, base, span.bps)
        local yy = vy(vv)
        if px0 then gfx.line(px0, py0, gx + px, yy) end
        px0, py0 = gx + px, yy
      end
      gfx.a = 1
    end
  end
  -- живое значение параметра при игре (модуляция + автоматизация, как слышно)
  if span.play_row and act.live and span.play_row >= r0 and span.play_row < r1 then
    local ok, lv = pcall(act.live)
    if ok and lv then U.set(U.GREEN); gfx.circle(rx(span.play_row), vy(lv), 3, 1, 1) end
  end
  trace(ACV.cur, act.rgb or U.GREEN, 1)
  -- 31 окт: delay нот — хвост от начала строки до реального времени ноты и риска там (грув виден по времени)
  if act.kind == 'vel' and act.fld == 3 then
    for _, p in ipairs(act.points or {}) do
      local row = span.row_of and span.row_of(p[1]) or r0
      if row >= r0 and row < r1 and p[2] > 0 then
        local x0, x1, yy = rx(row), rx(row + p[2] * 255 / 256), vy(p[2])
        U.set(act.rgb or U.CYAN, 0.35); gfx.rect(x1, gy, 1, gh, 1); gfx.a = 1
        U.set(act.rgb or U.CYAN); gfx.rect(x0, yy, math.max(1, x1 - x0), 1, 1)
      end
    end
  end
  -- точки активной
  U.set(act.rgb or U.GREEN)
  for _, p in ipairs(act.points or {}) do
    local row = span.row_of and span.row_of(p[1]) or r0
    if row >= r0 and row <= r1 then gfx.rect(rx(row) - 1, vy(p[2]) - 1, 3, 3, 1) end
  end
  -- 30 окт: мазок мыши (draw / line / erase) — превью до отпускания
  if ACV.stroke then
    local list = {}
    for r, v in pairs(ACV.stroke.rows or {}) do list[#list + 1] = r end
    table.sort(list)
    local ln = ACV.stroke.line
    local px, py
    for _, r in ipairs(list) do
      local v = ACV.stroke.rows[r]
      if r >= r0 and r < r1 then
        if v == false then U.set(U.RED, 0.5); gfx.rect(rx(r), gy, math.max(1, rx(r + 1) - rx(r)), gh, 1); gfx.a = 1; px = nil
        else
          local yy = vy(v)
          U.set(U.AMBER, ln and 0.45 or 1)   -- под прямой line ступеньки тише: видно, что ляжет в клетки
          if px then gfx.line(px, py, rx(r), yy) end
          gfx.rect(rx(r) - 1, yy - 1, 3, 3, 1)
          px, py = rx(r), yy
        end
      end
    end
    gfx.a = 1
    -- 31 окт: line — резинка от точки нажатия до мыши (в границах холста), концы кружками
    if ln then
      local function cx(xx) return math.max(gx, math.min(gx + gw - 1, xx)) end
      local function cy(yy) return math.max(gy, math.min(gy + gh - 1, yy)) end
      local x0, y0, x1, y1 = cx(ln[1]), cy(ln[2]), cx(ln[3]), cy(ln[4])
      U.set(U.AMBER)
      gfx.line(x0, y0, x1, y1, 1); gfx.line(x0, y0 + 1, x1, y1 + 1, 1)
      gfx.circle(x0, y0, 3, 1, 1); gfx.circle(x1, y1, 3, 0, 1)
    end
  end
  -- 31 окт: выделение (sel): рамка по точкам, ромбы на углах и серединах сторон; превью трансформации янтарём
  local xh_at
  if ACV.sel and act.points then
    local pts = ACV.sel_points(act, span, ACV.sel.a, ACV.sel.b)
    local box = ACV.box_of(pts, ACV.sel.a, ACV.sel.b) or { a = ACV.sel.a, b = ACV.sel.b, lo = 0, hi = 1 }
    local bx0, bx1 = math.max(gx, rx(box.a)), math.min(gx + gw - 1, rx(box.b))
    local by0, by1 = vy(box.hi), vy(box.lo)
    if by1 - by0 < 6 then by0 = by0 - 3; by1 = by1 + 3 end
    U.set(U.AMBER, 0.12); gfx.rect(rx(ACV.sel.a), gy, math.max(1, rx(ACV.sel.b) - rx(ACV.sel.a)), gh, 1); gfx.a = 1
    if ACV.xprev then
      U.set(U.AMBER)
      local px, py
      for _, p in ipairs(ACV.xprev) do
        local xx, yy = rx(p.row), vy(p.v)
        if px then gfx.line(px, py, xx, yy) end
        gfx.rect(xx - 1, yy - 1, 3, 3, 1); px, py = xx, yy
      end
    end
    if ACV.tool == 'sel' and not ACV.xprev then
      U.set(U.AMBER); gfx.rect(bx0, by0, math.max(1, bx1 - bx0), math.max(1, by1 - by0), 0)
      local cxm, cym = (bx0 + bx1) // 2, (by0 + by1) // 2
      local hs = { tl = { bx0, by0 }, tr = { bx1, by0 }, bl = { bx0, by1 }, br = { bx1, by1 }, t = { cxm, by0 }, b = { cxm, by1 }, l = { bx0, cym }, r = { bx1, cym } }
      local dr = math.max(3, math.floor(rh / 3))
      for k, p in pairs(hs) do
        local hot = math.abs(mx - p[1]) <= dr + 2 and math.abs(my - p[2]) <= dr + 2
        if hot then xh_at = k end
        U.diamond(p[1], p[2], dr, hot and U.AMBER or U.TEXT, hot)
      end
      if not xh_at and mx > bx0 and mx < bx1 and my > by0 and my < by1 then xh_at = 'move' end
    end
  end
  if ACV.vpt then U.set(U.AMBER); gfx.circle(ACV.vpt[1], ACV.vpt[2], 4, 0, 1); gfx.circle(ACV.vpt[1], ACV.vpt[2], 1, 1, 1) end   -- 30 окт: палец (CONTROL)
  -- курсор холста: строка янтарём, кружок на активной кривой; плейхед зелёным
  local cx = rx(ACV.row)
  U.set(U.AMBER, focused and 0.9 or 0.5); gfx.rect(cx, gy, 1, gh, 1); gfx.a = 1
  local cv_now = cache.ys[ACV.cur] and cache.ys[ACV.cur][math.max(0, math.min(gw - 1, cx - gx))] or 0
  U.set(U.AMBER); gfx.circle(cx, vy(cv_now), 3, 1, 1)
  if span.play_row and span.play_row >= r0 and span.play_row < r1 then U.set(U.GREEN); gfx.rect(rx(span.play_row), gy, 1, gh, 1) end
  U.set(U.LINE); gfx.rect(gx, gy, gw, gh, 0)
  -- 15 окт: рамка правки — то, что сейчас изменят клавиши: клетка сетки под курсором или v-диапазон
  -- (целыми клетками, как заливка); у LFO / ACS — весь отрезок (модуляция одна на параметр)
  do
    local a, b
    if act.kind == 'lfo' or act.kind == 'acs' then a, b = r0, r1 else a, b = ACV.range(span, true) end
    local fx0, fx1 = math.max(gx, rx(a)), math.min(gx + gw, rx(b))
    U.set(U.AMBER, focused and 1 or 0.45); gfx.rect(fx0, gy, math.max(2, fx1 - fx0), gh, 0)
    if focused then gfx.rect(fx0 + 1, gy + 1, math.max(1, fx1 - fx0 - 2), gh - 2, 0) end
    gfx.a = 1
  end
  -- легенда: имя и значение в строке курсора; активная янтарём
  local lx, ly = x + pad, lay.side and fy0 or (y + rh + 1 + nrow * rh)
  local lw = lay.side and (lay.lw - pad) or (w - 2 * pad)
  -- 31 окт: «/ add» — нечёткий поиск по всем параметрам трека: выбранный — в список (огибающая создаётся)
  do
    local aw = lay.side and lw or (U.measure('/ add') + 2 * pad)
    local hot = mx >= lx and mx < lx + aw and my >= ly and my < ly + rh
    U.set(hot and U.AMBER or U.LINE); gfx.rect(lx, ly, aw, rh - 1, 0)
    U.text(lx + pad, ly, '/ add', hot and U.AMBER or U.GREY)
    if hot then hover = { pane = 'curve', addp = true } end
    if lay.side then ly = ly + rh + 2 else lx = lx + aw + 2 end
  end
  for i, cv in ipairs(curves) do
    local on = i == ACV.cur
    local val = cache.ys[i] and cache.ys[i][math.max(0, math.min(gw - 1, cx - gx))] or 0
    if cv.kind == 'lfo' and cv.mod and cv.mod.v then val = cv.mod.v['lfo.strength'] or 0 elseif cv.kind == 'acs' and cv.mod and cv.mod.v then val = cv.mod.v['acs.strength'] or 0 end
    local lab = ('%s %3d%%'):format(cv.name or '?', math.floor(val * 100 + 0.5))
    local ix, iy, iw
    if lay.side then
      if i > lay.legend_rows - 1 then break end
      ix, iy, iw = lx, ly + (i - 1) * rh, lw
    else
      iw = U.measure(lab) + 2 * pad + 6
      if lx + iw > x + w - pad then break end
      ix, iy = lx, ly; lx = lx + iw
    end
    local hot = mx >= ix and mx < ix + iw and my >= iy and my < iy + rh
    if hot then hover = { pane = 'curve', legend = i } end
    if on then U.set(U.tint(U.AMBER, 0.25)); gfx.rect(ix, iy, iw, rh, 1)
    elseif ACV.multi[ACV.mkey(cv)] then U.set(U.tint(U.CYAN, 0.2)); gfx.rect(ix, iy, iw, rh, 1) end   -- 31 окт: в дорожках
    U.set(cv.rgb or U.GREEN); gfx.rect(ix + 1, iy + 2, 3, rh - 4, 1)
    U.text(ix + 6, iy, ctx.fit(lab, iw - 8), on and U.AMBER or (cv.write == false and U.GREY or U.TEXT))
  end
  if not hover and lane_hover then hover = { pane = 'curve', legend = lane_hover } end   -- 31 окт: чужая дорожка — сделать активной
  if not hover and mx >= gx and mx < gx + gw and my >= gy and my < gy + gh then
    local row = r0 + (mx - gx) / gw * nr
    hover = { pane = 'curve', curve_t = span.t0 + (span.t1 - span.t0) * (mx - gx) / math.max(1, gw - 1), row = math.floor(row),
      geo = { gx = gx + ox, gy = gy + oy, gw = gw, gh = gh, r0 = r0, nr = nr, ox = ox, oy = oy }, xh = xh_at }   -- 30 окт: геометрия — для мазка мыши
    -- 31 окт: в координатах окна — холст рисуется в буфер вкладки (U.mouse_off), а мазок читает мышь окна
  end
  return hover
end

return ACV
