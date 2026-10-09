-- jf_tracker_aiedit.lua — редактор точек automation item (5 окт).
--
-- Вкладка modulation, страница item: кривая пула во всю ширину.
-- Строка инструментов: free (точки: клик — новая, тянуть — двигать, правый
-- клик — удалить; Opt+клик / протяжка — ластик, Cmd+протяжка — от руки) | step sin tri saw+ saw- sqr — рисование протяжкой по
-- ячейкам сетки, как в Ableton: ячейка под мышью заполняется формой, высота
-- мыши — уровень. Сетка 1/2 … 1/32 (доли такта по 4/4: 1/4 = доля) или off;
-- точки прилипают к ней. Углы графика — ручки скалирования: правый верхний
-- вниз — значения уменьшаются слева направо (рампа границ), и так для всех
-- четырёх. Значения 0..1 между min и max огибающей. Undo — шаг на отпускание.
--
-- t = { env, idx, pos, len, label, min, max }; row_time / row_of — строки трекера.

local A = { drag = nil, prev = 0, tool = 'free', grid = 0.25, corner = nil, painted = false }
local R = reaper
A.TOOLS = { 'free', 'step', 'sin', 'tri', 'saw+', 'saw-', 'sqr' }
A.GRIDS = { { '1/2', 2 }, { '1/4', 1 }, { '1/8', 0.5 }, { '1/16', 0.25 }, { '1/32', 0.125 }, { '1/64', 0.0625 }, { '1/128', 0.03125 }, { 'off', 0 } }   -- до 1/128 (6 окт)
A.swing_qn = nil             -- свинг сетки проекта (main ставит edit.swing_qn), 6 окт

local function shape01(name, x)
  if name == 'sin' then return 0.5 - 0.5 * math.cos(2 * math.pi * x)
  elseif name == 'tri' then return 1 - math.abs(2 * x - 1)
  elseif name == 'saw+' then return x
  elseif name == 'saw-' then return 1 - x
  elseif name == 'sqr' then return x < 0.5 and 1 or 0 end
  return 1
end

-- 6 окт: точки одного полного прохода пула (флаг 0x10000000) — не всех
-- повторов лупа; иначе кривая уезжала за график
local FULL = 0x10000000
local function pts_of(t)
  local out = {}
  local ai = t.idx | FULL
  for p = 0, R.CountEnvelopePointsEx(t.env, ai) - 1 do
    local _, tm, v, sh, ten = R.GetEnvelopePointEx(t.env, ai, p)
    out[#out + 1] = { i = p, t = tm, v = v, sh = sh, ten = ten }
  end
  return out
end
-- один проход пула в секундах проекта (луп / playrate), иначе длина item
-- огибающая take (9 окт, t.take; idx = −1): время точек — от начала item,
-- во времени источника (× playrate); A.toff / A.trate переводят его в
-- проектное для сетки
A.toff, A.trate = 0, 1
local function tq(tm) return R.TimeMap2_timeToQN(0, A.toff + tm / A.trate) end
local function qt(q) return (R.TimeMap2_QNToTime(0, q) - A.toff) * A.trate end
function A.span(t)
  if t.take then
    local it = R.ValidatePtr(t.take, 'MediaItem_Take*') and R.GetMediaItemTake_Item(t.take)
    if not it then return 0, 1, 1 end
    local rate = R.GetMediaItemTakeInfo_Value(t.take, 'D_PLAYRATE')
    if not rate or rate <= 0 then rate = 1 end
    A.toff, A.trate = R.GetMediaItemInfo_Value(it, 'D_POSITION'), rate
    local one = math.max(1e-3, R.GetMediaItemInfo_Value(it, 'D_LENGTH') * rate)
    return 0, one, one
  end
  A.toff, A.trate = 0, 1
  local pos = R.GetSetAutomationItemInfo(t.env, t.idx, 'D_POSITION', 0, false)
  local len = R.GetSetAutomationItemInfo(t.env, t.idx, 'D_LENGTH', 0, false)
  local pq = R.GetSetAutomationItemInfo(t.env, t.idx, 'D_POOL_QNLEN', 0, false) or 0
  local rate = R.GetSetAutomationItemInfo(t.env, t.idx, 'D_PLAYRATE', 0, false) or 1
  local one = len
  if pq > 1e-6 and rate > 1e-6 then
    local q0 = R.TimeMap2_timeToQN(0, pos)
    one = R.TimeMap2_QNToTime(0, q0 + pq / rate) - pos
  end
  return pos, math.max(1e-3, math.min(len, one)), len
end
-- шкала огибающей (6 окт): громкость — фейдерная; правка идёт в сырых
-- значениях между min и max, переведёнными в шкалу (как рисует REAPER)
function A.range(t)
  local mode = R.GetEnvelopeScalingMode(t.env)
  local lo, hi = t.min or 0, t.max or 1
  -- t.min / t.max уже в шкале огибающей (модель, 6 окт)
  if hi - lo < 1e-9 then hi = lo + 1 end
  return lo, hi
end

-- время ↔ сетка (в QN)
local function snap_t(tm, g)
  if not g or g <= 0 then return tm end
  local q = tq(tm)
  local qq = math.floor(q / g + 0.5) * g
  if A.swing_qn then qq = A.swing_qn(qq) end                 -- свинг сетки проекта (6 окт)
  return qt(qq)
end
local function cell_of(tm, g, t0, t1)
  if not g or g <= 0 then return t0, t1 end
  local q = tq(tm)
  local q0 = math.floor(q / g) * g
  return math.max(t0, qt(q0)), math.min(t1, qt(q0 + g))
end

-- кнопки строки инструментов; возвращает выбранное под мышью
local function buttons(U, L, x, y, list, cur, mx, my, press)
  local bx = x
  for _, b in ipairs(list) do
    local lbl, val = b[1], b[2]
    local bw = U.measure(lbl) + 2 * L.pad
    local on = val == cur
    local hot = mx >= bx and mx < bx + bw and my >= y and my < y + L.rh
    U.set(on and U.tint(U.AMBER, 0.3) or (hot and U.PANEL or U.BG)); gfx.rect(bx, y, bw, L.rh, 1)
    U.set(on and U.AMBER or (hot and U.TEXT or U.LINE)); gfx.rect(bx, y, bw, L.rh, 0)
    U.text(bx + L.pad, y + 1, lbl, on and U.AMBER or (hot and U.TEXT or U.GREY))
    if hot and press then return val, bx + bw end
    bx = bx + bw + 2
  end
  return nil, bx
end

function A.draw(U, L, x, y, w, h, t, fit, row_time, row_of, lanes)
  local mx, my, cap = gfx.mouse_x, gfx.mouse_y, gfx.mouse_cap
  local press = cap & 1 == 1 and A.prev & 1 == 0
  local rpress = cap & 2 == 2 and A.prev & 2 == 0
  A.prev = cap
  U.set(U.PANEL); gfx.rect(x, y, w, h, 1)
  if not (t and t.env and R.ValidatePtr(t.env, 'TrackEnvelope*')) then
    U.text(x + L.pad, y, fit('automation item: double click one in the automation list of the slices module', w - 2 * L.pad), U.GREY)
    return nil
  end
  -- строка инструментов и сетки
  local tl = {}
  for _, n in ipairs(A.TOOLS) do tl[#tl + 1] = { n, n } end
  -- 6 окт: строка кнопок — ниже, над ней скобка с подписью группы envelope
  local by = y + L.rh
  local pick, bx = buttons(U, L, x + L.pad, by, tl, A.tool, mx, my, press)
  if pick then A.tool = pick; press = false end
  local gl = {}
  for _, g in ipairs(A.GRIDS) do gl[#gl + 1] = { g[1], g[2] } end
  local gpick, gx2 = buttons(U, L, bx + 3 * L.pad, by, gl, A.grid, mx, my, press)
  if gpick then A.grid = gpick; press = false end
  -- clear envelope (6 окт): все точки пула долой
  local ex0 = gx2 + 3 * L.pad
  local cpick, ex1 = buttons(U, L, ex0, by, { { 'clear', 'clear' }, { 'save', 'save' }, { 'load', 'load' } }, nil, mx, my, press)
  -- скобка над группой: ┌── envelope ──┐ (линия с усами, подпись посередине)
  do
    local lbl = 'envelope'
    local lw = U.measure(lbl)
    local x1 = (cpick and (ex0 + U.measure('clear') + U.measure('save') + U.measure('load') + 6 * L.pad + 4)) or ex1 - 2
    local cy = y + math.floor(L.rh / 2)
    local mid = math.floor((ex0 + x1 - lw) / 2)
    U.set(U.LINE)
    gfx.rect(ex0, cy, math.max(0, mid - L.pad - ex0), 1, 1); gfx.rect(mid + lw + L.pad, cy, math.max(0, x1 - mid - lw - L.pad), 1, 1)
    gfx.rect(ex0, cy, 1, L.rh - math.floor(L.rh / 2), 1); gfx.rect(x1 - 1, cy, 1, L.rh - math.floor(L.rh / 2), 1)
    U.text(mid, y, lbl, U.GREY)
  end
  if cpick == 'save' then if A.on_save then A.on_save() end; cpick = nil; press = false
  elseif cpick == 'load' then if A.on_load then A.on_load() end; cpick = nil; press = false end
  if cpick then
    local p0, one = A.span(t)
    R.DeleteEnvelopePointRangeEx(t.env, t.idx, p0 - 1, p0 + one + 1)
    R.Envelope_SortPointsEx(t.env, t.idx)
    R.Undo_OnStateChange(t.take and 'take envelope clear' or 'automation item clear'); R.UpdateArrange()
    press = false
  end
  local gx, gy, gw, gh = x + L.pad + 4, y + 2 * L.rh + 6, w - 2 * L.pad - 8, h - 2 * L.rh - 10
  if gw < 20 or gh < 12 then return nil end
  -- несколько пулов (6 окт): стопка узких лейнов; правится активный,
  -- клик по другому делает активным его (A.on_pick)
  local act_label
  if lanes and #lanes > 1 then
    local act
    for i, a in ipairs(lanes) do if a.env == t.env and a.pool == t.pool then act = i end end
    if act then
      local gap = 3
      local n = math.max(1, math.min(#lanes, math.floor((gh + gap) / (3 * L.rh + gap))))
      local i0 = math.max(1, math.min(act - math.floor(n / 2), #lanes - n + 1))
      local lh = math.floor((gh - (n - 1) * gap) / n)
      local agy
      for k = 0, n - 1 do
        local i = i0 + k
        local a = lanes[i]
        local ly = gy + k * (lh + gap)
        local name = ('%d/%d %s %s'):format(i, #lanes, a.envname or '', a.label or '')
        if i == act then agy = ly; act_label = name
        else
          U.set(U.BG); gfx.rect(gx, ly, gw, lh, 1)
          local lo, hi = a.min or 0, a.max or 1; if hi - lo < 1e-9 then hi = lo + 1 end
          local p0, one = A.span(a)
          U.set(U.tint(a.col or U.CYAN, 0.45))
          local px, py
          for _, q in ipairs(a.pts or {}) do
            local qx = gx + math.floor(math.max(0, math.min(1, (q[1] - p0) / one)) * (gw - 1) + 0.5)
            local qy = ly + lh - 1 - math.floor(math.max(0, math.min(1, (q[2] - lo) / (hi - lo))) * (lh - 1) + 0.5)
            if px then gfx.line(px, py, qx, qy) end
            px, py = qx, qy
          end
          local hot = mx >= gx and mx < gx + gw and my >= ly and my < ly + lh
          U.set(hot and U.TEXT or U.LINE); gfx.rect(gx, ly, gw, lh, 0)
          U.text(gx + 3, ly + 1, fit(name, gw - 6), hot and U.TEXT or U.GREY)
          if hot and press and A.on_pick then A.on_pick(a); return nil end
        end
      end
      gy, gh = agy, lh
    end
  end
  U.set(U.BG); gfx.rect(gx, gy, gw, gh, 1)
  local pos0, one = A.span(t)
  local t0, t1 = pos0, pos0 + one
  local lo, hi = A.range(t)
  local FI = t.idx | FULL
  local function X(tm) return gx + math.max(0, math.min(gw - 1, math.floor((tm - t0) / (t1 - t0) * (gw - 1) + 0.5))) end   -- по рамке графика
  local function Y(v) return gy + gh - 1 - math.floor(math.max(0, math.min(1, (v - lo) / (hi - lo))) * (gh - 1) + 0.5) end
  local function T(px) return t0 + math.max(0, math.min(1, (px - gx) / math.max(1, gw - 1))) * (t1 - t0) end
  local function N(py) return math.max(0, math.min(1, (gy + gh - 1 - py) / math.max(1, gh - 1))) end
  local function V(py) return lo + N(py) * (hi - lo) end
  -- сетка: линии по шагу (доли — ярче)
  if A.grid > 0 then
    local q0, q1 = tq(t0), tq(t1)
    local n = (q1 - q0) / A.grid
    if n < gw / 3 then
      local q = math.ceil(q0 / A.grid - 1e-9) * A.grid
      while q <= q1 + 1e-9 do
        local px = X(qt(q))
        U.set(math.abs(q - math.floor(q + 0.5)) < 1e-9 and U.LINE or U.DIM); gfx.rect(px, gy, 1, gh, 1)
        q = q + A.grid
      end
    end
  end
  U.set(U.LINE); gfx.rect(gx, gy, gw, gh, 0)
  if act_label then U.text(gx + 3, gy + 1, fit(act_label, gw - 6), U.AMBER) end
  local pts = pts_of(t)
  local opt, cmdk = cap & 16 == 16, cap & 4 == 4
  -- скалирование углами: во время протяжки — превью преобразования
  local cs = A.corner
  local function tf(p)
    if not cs then return p.v end
    local f = (p.t - t0) / (t1 - t0)
    local top = cs.tl + (cs.tr - cs.tl) * f
    local bot = cs.bl + (cs.br - cs.bl) * f
    local nv = (p.v - lo) / (hi - lo)
    return lo + (bot + nv * (top - bot)) * (hi - lo)
  end
  U.set(t.col or U.CYAN)                 -- цвет огибающей (как в REAPER), 6 окт
  local px, py
  for _, p in ipairs(cs and cs.snap or pts) do
    local qx, qy = X(p.t), Y(tf(p))
    if px then gfx.line(px, py, qx, qy) end
    px, py = qx, qy
  end
  local hot
  if (A.tool == 'free' or opt) and not cs then
    for _, p in ipairs(pts) do
      local qx, qy = X(p.t), Y(p.v)
      local near = math.abs(mx - qx) <= 4 and math.abs(my - qy) <= 4
      if near then hot = p end
      U.set((near or (A.drag and A.drag.i == p.i)) and U.AMBER or (t.col or U.CYAN)); gfx.circle(qx, qy, (near or (A.drag and A.drag.i == p.i)) and 4 or 3, (A.selpt == p.i) and 1 or 0, 1)   -- кружок, как в REAPER; выбранная — залита
    end
  end
  -- ручки углов
  local CN = { { 'tl', gx, gy }, { 'tr', gx + gw - 1, gy }, { 'bl', gx, gy + gh - 1 }, { 'br', gx + gw - 1, gy + gh - 1 } }
  local chot
  for _, c in ipairs(CN) do
    local cy = c[3]
    if cs then local n = cs[c[1]]; cy = gy + gh - 1 - math.floor(n * (gh - 1) + 0.5) end
    local near = math.abs(mx - c[2]) <= 6 and math.abs(my - cy) <= 6
    if near then chot = c[1] end
    U.set((near or (cs and cs.which == c[1])) and U.AMBER or U.GREY); gfx.rect(c[2] - 3, cy - 3, 7, 7, 0)
  end
  local inside = mx >= gx - 6 and mx < gx + gw + 6 and my >= gy - 6 and my < gy + gh + 6
  local function commit(desc) R.Undo_OnStateChange(desc); R.UpdateArrange() end
  -- угол тянется
  if cs then
    if cap & 1 == 1 then cs[cs.which] = N(my)
    else
      for _, p in ipairs(cs.snap) do R.SetEnvelopePointEx(t.env, FI, p.i, p.t, tf(p), nil, nil, nil, true) end
      R.Envelope_SortPointsEx(t.env, t.idx)
      A.corner = nil
      commit('automation item scale')
    end
    return { status = 'scale: drag the corner - the edge ramps from the other corner' }
  end
  -- 6 окт: модификаторы поверх любого инструмента. Opt — ластик: клик или
  -- протяжка стирает точки в пройденной полосе времени; Cmd — рисование от
  -- руки (точка на каждые 3 px, старые в пройденной полосе заменяются).
  -- Режим виден по курсору REAPER (eraser / env_pencil / env_addpt / pencil)
  if inside or A.erase or A.free then
    gfx.setcursor(0, (opt or A.erase) and 'eraser' or ((cmdk or A.free) and 'env_pencil'
      or (A.tool == 'free' and (hot and 'hand' or 'env_addpt') or 'pencil')))
    A.cursor = true
  elseif A.cursor then gfx.setcursor(32512); A.cursor = nil end
  if A.erase or (inside and press and opt) then
    if cap & 1 == 1 then
      local xa = A.erase and A.erase.x or mx
      local ta, tb = T(math.min(xa, mx) - 3), T(math.max(xa, mx) + 3)
      local n = A.erase and A.erase.n or 0
      for k = #pts, 1, -1 do
        local p = pts[k]
        if p.t >= ta and p.t <= tb then R.DeleteEnvelopePointEx(t.env, FI, p.i); n = n + 1 end
      end
      R.Envelope_SortPointsEx(t.env, t.idx)
      A.erase = { x = mx, n = n }; A.selpt = nil
    else
      if A.erase.n > 0 then commit('automation item erase') end
      A.erase = nil
    end
    return { status = 'erase: Opt+click / drag removes the points it passes' }
  end
  if A.free or (inside and press and cmdk) then
    if cap & 1 == 1 then
      local tm, v = T(mx), V(my)
      local last = A.free and A.free.t
      if not last or math.abs(X(tm) - X(last)) >= 3 then
        local e = 1e-7
        if not last then R.DeleteEnvelopePointRangeEx(t.env, t.idx, tm - e, tm + e)
        elseif tm > last then R.DeleteEnvelopePointRangeEx(t.env, t.idx, last + e, tm + e)
        else R.DeleteEnvelopePointRangeEx(t.env, t.idx, tm - e, last - e) end
        R.InsertEnvelopePointEx(t.env, t.idx, tm, v, 0, 0, false, true)
        R.Envelope_SortPointsEx(t.env, t.idx)
        A.free = { t = tm }
      end
    else A.free = nil; commit('automation item freehand') end
    return { status = 'freehand: Cmd+drag draws the curve' }
  end
  if press and chot then
    A.corner = { which = chot, tl = 1, tr = 1, bl = 0, br = 0, snap = pts }
    return nil
  end
  if A.tool == 'free' then
    if A.drag then
      if cap & 1 == 1 then
        R.SetEnvelopePointEx(t.env, FI, A.drag.i, snap_t(T(mx), A.grid), V(my), nil, nil, nil, true)
        R.Envelope_SortPointsEx(t.env, t.idx)
        local best, bd
        for _, p in ipairs(pts_of(t)) do local d = math.abs(X(p.t) - mx) + math.abs(Y(p.v) - my); if not bd or d < bd then best, bd = p.i, d end end
        A.drag.i = best or A.drag.i
      else A.drag = nil; commit('automation item point') end
    elseif inside and press then
      if hot then A.drag = { i = hot.i }; A.selpt = hot.i                   -- выбранная точка: её форма — в свойствах (6 окт)
      else
        R.InsertEnvelopePointEx(t.env, t.idx, snap_t(T(mx), A.grid), V(my), 0, 0, false, true)
        R.Envelope_SortPointsEx(t.env, t.idx)
        commit('automation item point')
        for _, p in ipairs(pts_of(t)) do if math.abs(X(p.t) - X(snap_t(T(mx), A.grid))) <= 1 then A.drag = { i = p.i } end end
      end
    elseif inside and rpress and hot then
      R.DeleteEnvelopePointEx(t.env, FI, hot.i)
      R.Envelope_SortPointsEx(t.env, t.idx)
      commit('automation item point delete')
    end
  else
    -- рисование формой по ячейкам сетки (как в Ableton)
    if cap & 1 == 1 and (inside or A.painted) and not (press and not inside) then
      local c0, c1 = cell_of(T(mx), A.grid, t0, t1)
      if A.grid <= 0 then c0, c1 = math.max(t0, T(mx) - (t1 - t0) / 32), math.min(t1, T(mx) + (t1 - t0) / 32) end
      local lvl = N(my)
      R.DeleteEnvelopePointRangeEx(t.env, t.idx, c0 - 1e-6, c1 - 1e-6)
      if A.tool == 'step' then
        R.InsertEnvelopePointEx(t.env, t.idx, c0, lo + lvl * (hi - lo), 1, 0, false, true)
      else
        local n = A.tool == 'sqr' and 2 or 8
        for k = 0, n - 1 do
          local f = k / n
          local tm = c0 + f * (c1 - c0)
          R.InsertEnvelopePointEx(t.env, t.idx, tm, lo + lvl * shape01(A.tool, f) * (hi - lo), A.tool == 'sqr' and 1 or 0, 0, false, true)
        end
      end
      R.Envelope_SortPointsEx(t.env, t.idx)
      A.painted = true
    elseif A.painted and cap & 1 == 0 then
      A.painted = false
      commit('automation item draw ' .. A.tool)
    end
  end
  if inside then
    return { status = ('%s  %.3f s  %.0f%%  -  %s; corners scale, grid %s'):format(A.tool, snap_t(T(mx), A.grid) - t0, N(my) * 100,
      (A.tool == 'free' and 'click add, drag move, right click delete' or 'drag paints the grid cells, the mouse height is the level') .. ', Opt erase, Cmd freehand',
      A.grid > 0 and ('%g QN'):format(A.grid) or 'off') }
  end
  return nil
end

-- свойства item (6 окт): loop, повторы пула, playrate, offset, baseline,
-- amplitude. Колесо по строке — шаг, клик по слайдеру — значение
local PROPS = {
  { k = 'loop', label = 'loop' },
  { k = 'rep', label = 'repeats', min = 1, max = 32 },
  { k = 'D_PLAYRATE', label = 'rate', min = 0.25, max = 4 },
  { k = 'D_STARTOFFS', label = 'offset', min = 0, max = 4 },
  { k = 'D_BASELINE', label = 'baseline', min = 0, max = 1 },
  { k = 'D_AMPLITUDE', label = 'amplitude', min = -1, max = 1 },
}
function A.props(U, L, x, y, w, h, t, fit)
  if not (t and t.env and R.ValidatePtr(t.env, 'TrackEnvelope*')) then return nil end
  if t.take then                                            -- огибающая take: свойств automation item нет
    U.set(U.LINE); gfx.rect(x - 2, y, 1, h, 1)
    U.text(x + L.pad, y, fit('take envelope', w - L.pad), U.GREY)
    U.text(x + L.pad, y + L.rh, fit(t.label or '', w - L.pad), U.TEXT)
    return nil
  end
  local function get(k) return R.GetSetAutomationItemInfo(t.env, t.idx, k, 0, false) end
  local function put(k, v) R.GetSetAutomationItemInfo(t.env, t.idx, k, v, true) end
  local pos, one, len = A.span(t)
  local mx, my, cap = gfx.mouse_x, gfx.mouse_y, gfx.mouse_cap
  U.set(U.LINE); gfx.rect(x - 2, y, 1, h, 1)
  U.text(x + L.pad, y, fit('item properties', w - L.pad), U.GREY)
  local lw = U.measure('amplitude ') + L.pad
  local hover
  for i, p in ipairs(PROPS) do
    local ry = y + i * L.rh
    if ry + L.rh > y + h then break end
    local v, vt
    if p.k == 'loop' then v = get('D_LOOPSRC') ~= 0; vt = v and 'on' or 'off'
    elseif p.k == 'rep' then v = math.max(1, math.floor(len / one + 0.5)); vt = tostring(v)
    else v = get(p.k); vt = ('%.2f'):format(v) end
    local hot = mx >= x and mx < x + w and my >= ry and my < ry + L.rh
    if hot then U.set(U.tint(U.AMBER, 0.15)); gfx.rect(x, ry, w, L.rh, 1) end
    U.text(x + L.pad, ry, p.label, hot and U.AMBER or U.GREY)
    U.text(x + lw, ry, vt, U.TEXT)
    local sx = x + lw + U.measure('-0.00') + L.pad
    local sw = math.max(0, w - (sx - x) - L.pad)
    if p.min and sw > 8 then
      local fr = (p.k == 'rep' and (v - p.min) or (v - p.min)) / (p.max - p.min)
      U.set(U.DIM); gfx.rect(sx, ry + math.floor(L.rh / 2) - 1, sw, 2, 1)
      U.set(U.TEXT); gfx.rect(sx, ry + 4, math.max(1, math.floor(math.max(0, math.min(1, fr)) * sw + 0.5)), L.rh - 8, 1)
    end
    -- ввод: колесо — шаг; клик по слайдеру — значение; loop — клик
    local function apply(nv)
      if p.k == 'loop' then put('D_LOOPSRC', nv and 1 or 0)
      elseif p.k == 'rep' then put('D_LOOPSRC', 1); put('D_LENGTH', one * nv)
      elseif p.k == 'D_PLAYRATE' then
        local n = math.max(1, math.floor(len / one + 0.5))
        put('D_PLAYRATE', nv); local _, one2 = A.span(t); put('D_LENGTH', one2 * n)   -- повторы сохраняются
      else put(p.k, nv) end
      R.UpdateArrange(); R.Undo_OnStateChange('automation item ' .. p.label)
    end
    if hot then
      local wv = gfx.mouse_wheel
      if wv ~= 0 then
        local d = wv > 0 and 1 or -1
        if p.k == 'loop' then apply(not v)
        elseif p.k == 'rep' then apply(math.max(p.min, math.min(p.max, v + d)))
        elseif p.k == 'D_PLAYRATE' then apply(math.max(p.min, math.min(p.max, v * 2 ^ (d / 12))))
        else apply(math.max(p.min, math.min(p.max, v + d * (p.max - p.min) / 50))) end
        gfx.mouse_wheel = 0
      end
      local press = cap & 1 == 1 and (A.pprev or 0) & 1 == 0
      if press then
        if p.k == 'loop' then apply(not v)
        elseif p.min and mx >= sx and sw > 8 then
          local fr = math.max(0, math.min(1, (mx - sx) / sw))
          local nv = p.min + fr * (p.max - p.min)
          if p.k == 'rep' then nv = math.floor(nv + 0.5) end
          apply(nv)
        end
      end
      hover = { status = ('%s: wheel - step, click the slider - value'):format(p.label) }
    end
  end
  -- выбранная точка (6 окт): форма сегмента до следующей и натяжение (bez)
  local FI = t.idx | 0x10000000
  local np = R.CountEnvelopePointsEx(t.env, FI)
  if A.selpt and A.selpt < np then
    local _, pt, pv, psh, pten = R.GetEnvelopePointEx(t.env, FI, A.selpt)
    local ry = y + (#PROPS + 1) * L.rh + 4
    if ry + 3 * L.rh <= y + h then
      local lo, hi = A.range(t)
      U.set(U.LINE); gfx.rect(x, ry - 3, w, 1, 1)
      U.text(x + L.pad, ry, fit(('point %d  %.0f%%'):format(A.selpt + 1, (pv - lo) / (hi - lo) * 100), w - L.pad), U.AMBER)
      -- формы REAPER: 0 lin 1 square 2 slow 3 fast start 4 fast end 5 bezier
      local SH = { 'lin', 'sqr', 'slo', 'fas', 'fae', 'bez' }
      local bx, sy = x + L.pad, ry + L.rh
      local press = cap & 1 == 1 and (A.pprev or 0) & 1 == 0
      for k, nm in ipairs(SH) do
        local bw = U.measure(nm) + 2 * L.pad
        if bx + bw > x + w then bx = x + L.pad; sy = sy + L.rh end
        local on = (psh or 0) == k - 1
        local hot = mx >= bx and mx < bx + bw and my >= sy and my < sy + L.rh
        U.set(on and U.tint(U.AMBER, 0.3) or (hot and U.PANEL or U.BG)); gfx.rect(bx, sy, bw, L.rh - 1, 1)
        U.set((on or hot) and U.AMBER or U.LINE); gfx.rect(bx, sy, bw, L.rh - 1, 0)
        U.text(bx + L.pad, sy, nm, (on or hot) and U.AMBER or U.GREY)
        if hot and press then R.SetEnvelopePointEx(t.env, FI, A.selpt, nil, nil, k - 1, nil, nil, false); R.Undo_OnStateChange('envelope point shape'); R.UpdateArrange() end
        if hot then hover = { status = 'segment shape from this point to the next (as in REAPER)' } end
        bx = bx + bw + 2
      end
      -- натяжение (bezier): колесо / клик по дорожке
      if (psh or 0) == 5 then
        local ty2 = sy + L.rh
        U.text(x + L.pad, ty2, 'tension', U.GREY)
        local tx0 = x + lw; local tw = math.max(8, w - lw - L.pad)
        local fr = ((pten or 0) + 1) / 2
        U.set(U.DIM); gfx.rect(tx0, ty2 + math.floor(L.rh / 2) - 1, tw, 2, 1)
        U.set(U.AMBER); gfx.rect(tx0 + math.floor(fr * (tw - 1)), ty2 + 3, 2, L.rh - 6, 1)
        local hot = mx >= x and mx < x + w and my >= ty2 and my < ty2 + L.rh
        if hot then
          local nt
          if cap & 1 == 1 and mx >= tx0 then nt = math.max(-1, math.min(1, (mx - tx0) / tw * 2 - 1)) end
          if gfx.mouse_wheel ~= 0 then nt = math.max(-1, math.min(1, (pten or 0) + (gfx.mouse_wheel > 0 and 0.05 or -0.05))); gfx.mouse_wheel = 0 end
          if nt then R.SetEnvelopePointEx(t.env, FI, A.selpt, nil, nil, nil, nt, nil, false); R.UpdateArrange() end
          hover = { status = 'bezier tension: drag / wheel' }
        end
      end
    end
  end
  A.pprev = cap
  return hover
end

-- файл кривой (6 окт): .jfcurve — строки «pt доля_времени значение форма натяжение»,
-- время и значение 0..1 (значение — в шкале огибающей между min и max), так
-- кривая ложится на item любой длины и любую огибающую
function A.save(t, path)
  local pos, one = A.span(t)
  local lo, hi = A.range(t)
  local f = io.open(path, 'w'); if not f then return false end
  f:write('# jf_tracker curve\n')
  for _, p in ipairs(pts_of(t)) do
    f:write(('pt %.6f %.6f %d %.4f\n'):format((p.t - pos) / one, (p.v - lo) / (hi - lo), p.sh or 0, p.ten or 0))
  end
  f:close()
  return true
end
function A.load(t, path)
  local f = io.open(path, 'r'); if not f then return 0 end
  local pos, one = A.span(t)
  local lo, hi = A.range(t)
  local list = {}
  for line in f:lines() do
    local a, b, sh, ten = line:match('^pt%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)')
    if a then list[#list + 1] = { tonumber(a), tonumber(b), tonumber(sh) or 0, tonumber(ten) or 0 } end
  end
  f:close()
  R.DeleteEnvelopePointRangeEx(t.env, t.idx, pos - 1, pos + one + 1)
  for _, p in ipairs(list) do
    R.InsertEnvelopePointEx(t.env, t.idx, pos + p[1] * one, lo + math.max(0, math.min(1, p[2])) * (hi - lo), p[3], p[4], false, true)
  end
  R.Envelope_SortPointsEx(t.env, t.idx)
  R.Undo_OnStateChange('automation item load curve'); R.UpdateArrange()
  return #list
end

return A
