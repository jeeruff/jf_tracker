-- jf_tracker_aiedit.lua — редактор точек automation item (5 окт).
--
-- Вкладка modulation, страница item: кривая пула во всю ширину.
-- Строка инструментов: free (точки: клик — новая, тянуть — двигать, правый
-- клик — удалить) | step sin tri saw+ saw- sqr — рисование протяжкой по
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
A.GRIDS = { { '1/2', 2 }, { '1/4', 1 }, { '1/8', 0.5 }, { '1/16', 0.25 }, { '1/32', 0.125 }, { 'off', 0 } }

local function shape01(name, x)
  if name == 'sin' then return 0.5 - 0.5 * math.cos(2 * math.pi * x)
  elseif name == 'tri' then return 1 - math.abs(2 * x - 1)
  elseif name == 'saw+' then return x
  elseif name == 'saw-' then return 1 - x
  elseif name == 'sqr' then return x < 0.5 and 1 or 0 end
  return 1
end

local function pts_of(t)
  local out = {}
  for p = 0, R.CountEnvelopePointsEx(t.env, t.idx) - 1 do
    local _, tm, v, sh, ten = R.GetEnvelopePointEx(t.env, t.idx, p)
    out[#out + 1] = { i = p, t = tm, v = v, sh = sh, ten = ten }
  end
  return out
end

-- время ↔ сетка (в QN)
local function snap_t(tm, g)
  if not g or g <= 0 then return tm end
  local q = R.TimeMap2_timeToQN(0, tm)
  return R.TimeMap2_QNToTime(0, math.floor(q / g + 0.5) * g)
end
local function cell_of(tm, g, t0, t1)
  if not g or g <= 0 then return t0, t1 end
  local q = R.TimeMap2_timeToQN(0, tm)
  local q0 = math.floor(q / g) * g
  return math.max(t0, R.TimeMap2_QNToTime(0, q0)), math.min(t1, R.TimeMap2_QNToTime(0, q0 + g))
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

function A.draw(U, L, x, y, w, h, t, fit, row_time, row_of)
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
  local pick, bx = buttons(U, L, x + L.pad, y, tl, A.tool, mx, my, press)
  if pick then A.tool = pick; press = false end
  local gl = {}
  for _, g in ipairs(A.GRIDS) do gl[#gl + 1] = { g[1], g[2] } end
  local gpick = buttons(U, L, bx + 3 * L.pad, y, gl, A.grid, mx, my, press)
  if gpick then A.grid = gpick; press = false end
  local gx, gy, gw, gh = x + L.pad + 4, y + L.rh + 6, w - 2 * L.pad - 8, h - L.rh - 10
  if gw < 20 or gh < 12 then return nil end
  U.set(U.BG); gfx.rect(gx, gy, gw, gh, 1)
  local t0, t1 = t.pos, t.pos + t.len
  local lo, hi = t.min or 0, t.max or 1
  if hi - lo < 1e-9 then hi = lo + 1 end
  local function X(tm) return gx + math.floor((tm - t0) / (t1 - t0) * (gw - 1) + 0.5) end
  local function Y(v) return gy + gh - 1 - math.floor(math.max(0, math.min(1, (v - lo) / (hi - lo))) * (gh - 1) + 0.5) end
  local function T(px) return t0 + math.max(0, math.min(1, (px - gx) / math.max(1, gw - 1))) * (t1 - t0) end
  local function N(py) return math.max(0, math.min(1, (gy + gh - 1 - py) / math.max(1, gh - 1))) end
  local function V(py) return lo + N(py) * (hi - lo) end
  -- сетка: линии по шагу (доли — ярче)
  if A.grid > 0 then
    local q0, q1 = R.TimeMap2_timeToQN(0, t0), R.TimeMap2_timeToQN(0, t1)
    local n = (q1 - q0) / A.grid
    if n < gw / 3 then
      local q = math.ceil(q0 / A.grid - 1e-9) * A.grid
      while q <= q1 + 1e-9 do
        local px = X(R.TimeMap2_QNToTime(0, q))
        U.set(math.abs(q - math.floor(q + 0.5)) < 1e-9 and U.LINE or U.DIM); gfx.rect(px, gy, 1, gh, 1)
        q = q + A.grid
      end
    end
  end
  U.set(U.LINE); gfx.rect(gx, gy, gw, gh, 0)
  local pts = pts_of(t)
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
  U.set(U.CYAN)
  local px, py
  for _, p in ipairs(cs and cs.snap or pts) do
    local qx, qy = X(p.t), Y(tf(p))
    if px then gfx.line(px, py, qx, qy) end
    px, py = qx, qy
  end
  local hot
  if A.tool == 'free' and not cs then
    for _, p in ipairs(pts) do
      local qx, qy = X(p.t), Y(p.v)
      local near = math.abs(mx - qx) <= 4 and math.abs(my - qy) <= 4
      if near then hot = p end
      U.set((near or (A.drag and A.drag.i == p.i)) and U.AMBER or U.CYAN); gfx.rect(qx - 2, qy - 2, 5, 5, 1)
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
      for _, p in ipairs(cs.snap) do R.SetEnvelopePointEx(t.env, t.idx, p.i, p.t, tf(p), nil, nil, nil, true) end
      R.Envelope_SortPointsEx(t.env, t.idx)
      A.corner = nil
      commit('automation item scale')
    end
    return { status = 'scale: drag the corner - the edge ramps from the other corner' }
  end
  if press and chot then
    A.corner = { which = chot, tl = 1, tr = 1, bl = 0, br = 0, snap = pts }
    return nil
  end
  if A.tool == 'free' then
    if A.drag then
      if cap & 1 == 1 then
        R.SetEnvelopePointEx(t.env, t.idx, A.drag.i, snap_t(T(mx), A.grid), V(my), nil, nil, nil, true)
        R.Envelope_SortPointsEx(t.env, t.idx)
        local best, bd
        for _, p in ipairs(pts_of(t)) do local d = math.abs(X(p.t) - mx) + math.abs(Y(p.v) - my); if not bd or d < bd then best, bd = p.i, d end end
        A.drag.i = best or A.drag.i
      else A.drag = nil; commit('automation item point') end
    elseif inside and press then
      if hot then A.drag = { i = hot.i }
      else
        R.InsertEnvelopePointEx(t.env, t.idx, snap_t(T(mx), A.grid), V(my), 0, 0, false, true)
        R.Envelope_SortPointsEx(t.env, t.idx)
        commit('automation item point')
        for _, p in ipairs(pts_of(t)) do if math.abs(X(p.t) - X(snap_t(T(mx), A.grid))) <= 1 then A.drag = { i = p.i } end end
      end
    elseif inside and rpress and hot then
      R.DeleteEnvelopePointEx(t.env, t.idx, hot.i)
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
      A.tool == 'free' and 'click add, drag move, right click delete' or 'drag paints the grid cells, the mouse height is the level',
      A.grid > 0 and ('%g QN'):format(A.grid) or 'off') }
  end
  return nil
end

return A
