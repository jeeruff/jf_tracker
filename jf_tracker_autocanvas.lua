-- jf_tracker_autocanvas.lua — холст автоматизации (15 окт): страница curve вкладки automation.
--
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

local ACV = { row = 0, anchor = nil, grid = 4, cur = 1, seed = 1 }
local U, ctx, LG

function ACV.init(u, c, lg) U, ctx, LG = u, c, lg end

-- буква → форма заливки (мнемоники: flat, ramp, Ramp down, sine, triangle, square, noise)
ACV.SHAPES = { f = 'flat', r = 'ramp+', R = 'ramp-', s = 'sin', t = 'tri', q = 'sqr', n = 'rnd' }
-- форма LFO REAPER: 0 sin 1 sqr 2 saw< 3 saw> 4 tri 5 rnd (как SHAPES в jf_tracker_modmatrix)
ACV.LFO_SHAPE = { s = 0, q = 1, R = 2, r = 3, t = 4, n = 5 }
ACV.LFO_NAMES = { [0] = 'sin', 'sqr', 'saw<', 'saw>', 'tri', 'rnd' }

local function clamp01(v) return math.max(0, math.min(1, v)) end
local function rnd(k, seed)
  local x = math.sin((k + 1) * 12.9898 + seed * 78.233) * 43758.5453
  return x - math.floor(x)
end

-- подпись сетки: доля такта (lpb строк на долю, 4 доли) или строки
function ACV.grid_label(grid, lpb)
  local bar = (lpb or 4) * 4
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
  local g = math.max(1, grid or 1)
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
  if c == 27 then
    if ACV.anchor then ACV.anchor = nil; return true end
    return { op = 'leave' }
  elseif ch == 'h' or c == 1818584692 then ACV.row = ACV.row - 1; clamp_row(); return true
  elseif ch == 'l' or c == 1919379572 then ACV.row = ACV.row + 1; clamp_row(); return true
  elseif ch == 'H' then ACV.row = ACV.row - math.max(1, ACV.grid); clamp_row(); return true
  elseif ch == 'L' then ACV.row = ACV.row + math.max(1, ACV.grid); clamp_row(); return true
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
    if ch == '[' then g = math.max(1, g // 2) else g = math.min((st.lpb or 4) * 4, g * 2) end
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
  local lw = side and math.min(math.floor(w * 0.3), cw * 28) or 0
  local top = rh + 2                                              -- строка заголовка (сетка, отрезок)
  if not side then top = top + rh end                             -- легенда — второй строкой
  local gx, gy, gw, gh = 0, top, w - lw - (side and L.pad or 0), h - top - 2
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
  -- заголовок: активная кривая, отрезок, сетка
  local head = ('%s   %s   grid %s%s'):format(act.name or 'curve', span.label or '', ACV.grid_label(ACV.grid, span.lpb),
    ACV.anchor and ('   v %d..%d'):format(math.min(ACV.anchor, ACV.row), math.max(ACV.anchor, ACV.row)) or '')
  U.text(x + pad, y + 1, ctx.fit(head, w - 2 * pad), focused and U.AMBER or U.CYAN)
  -- поле
  U.set(U.BG); gfx.rect(gx, gy, gw, gh, 1)
  -- сетка: клетки тускло, такты ярче; уровни 25 / 50 / 75
  local bar = (span.lpb or 4) * 4
  local g = math.max(1, ACV.grid)
  for row = r0, r1 - 1 do
    local d = row - r0
    if d % g == 0 then U.set(U.mix(U.LINE, U.BG, (d % bar == 0) and 0.2 or 0.6)); gfx.rect(rx(row), gy, 1, gh, 1) end
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
  for i, cv in ipairs(curves) do if i ~= ACV.cur then trace(i, U.mix(cv.rgb or U.GREEN, U.BG, 0.5), 1) end end
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
  -- точки активной
  U.set(act.rgb or U.GREEN)
  for _, p in ipairs(act.points or {}) do
    local row = span.row_of and span.row_of(p[1]) or r0
    if row >= r0 and row <= r1 then gfx.rect(rx(row) - 1, vy(p[2]) - 1, 3, 3, 1) end
  end
  -- курсор холста: строка янтарём, кружок на активной кривой; плейхед зелёным
  local cx = rx(ACV.row)
  U.set(U.AMBER, focused and 0.9 or 0.5); gfx.rect(cx, gy, 1, gh, 1); gfx.a = 1
  local cv_now = cache.ys[ACV.cur] and cache.ys[ACV.cur][math.max(0, math.min(gw - 1, cx - gx))] or 0
  U.set(U.AMBER); gfx.circle(cx, vy(cv_now), 3, 1, 1)
  if span.play_row and span.play_row >= r0 and span.play_row < r1 then U.set(U.GREEN); gfx.rect(rx(span.play_row), gy, 1, gh, 1) end
  U.set(U.LINE); gfx.rect(gx, gy, gw, gh, 0)
  -- легенда: имя и значение в строке курсора; активная янтарём
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local hover
  local lx, ly = lay.side and (gx + gw + pad) or (x + pad), lay.side and gy or (y + rh + 1)
  local lw = lay.side and lay.lw or (w - 2 * pad)
  for i, cv in ipairs(curves) do
    local on = i == ACV.cur
    local val = cache.ys[i] and cache.ys[i][math.max(0, math.min(gw - 1, cx - gx))] or 0
    if cv.kind == 'lfo' and cv.mod and cv.mod.v then val = cv.mod.v['lfo.strength'] or 0 elseif cv.kind == 'acs' and cv.mod and cv.mod.v then val = cv.mod.v['acs.strength'] or 0 end
    local lab = ('%s %3d%%'):format(cv.name or '?', math.floor(val * 100 + 0.5))
    local ix, iy, iw
    if lay.side then
      if i > lay.legend_rows then break end
      ix, iy, iw = lx, ly + (i - 1) * rh, lw
    else
      iw = U.measure(lab) + 2 * pad + 6
      if lx + iw > x + w - pad then break end
      ix, iy = lx, ly; lx = lx + iw
    end
    local hot = mx >= ix and mx < ix + iw and my >= iy and my < iy + rh
    if hot then hover = { pane = 'curve', legend = i } end
    if on then U.set(U.tint(U.AMBER, 0.25)); gfx.rect(ix, iy, iw, rh, 1) end
    U.set(cv.rgb or U.GREEN); gfx.rect(ix + 1, iy + 2, 3, rh - 4, 1)
    U.text(ix + 6, iy, ctx.fit(lab, iw - 8), on and U.AMBER or (cv.write == false and U.GREY or U.TEXT))
  end
  if not hover and mx >= gx and mx < gx + gw and my >= gy and my < gy + gh then
    local row = r0 + (mx - gx) / gw * nr
    hover = { pane = 'curve', curve_t = span.t0 + (span.t1 - span.t0) * (mx - gx) / math.max(1, gw - 1), row = math.floor(row) }
  end
  return hover
end

return ACV
