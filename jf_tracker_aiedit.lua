-- jf_tracker_aiedit.lua — редактор точек automation item (5 окт).
--
-- Вкладка modulation, страница item: кривая пула во всю ширину, сетка строк
-- трекера. Мышь: клик по пустому — новая точка, тянуть точку — время и
-- значение, правый клик по точке — удалить. Значения 0..1 между min и max
-- огибающей (как у генератора: raw = min + v·(max − min)). Undo — одним шагом
-- на отпускание кнопки. Генератор справа пишет в этот же item (main).
--
-- t = { env, idx, pos, len, label, min, max }; row_time(row) → секунды;
-- row_of(t) → строка (дробная).

local A = { drag = nil, prev = 0 }
local R = reaper

local function pts_of(t)
  local out = {}
  for p = 0, R.CountEnvelopePointsEx(t.env, t.idx) - 1 do
    local _, tm, v = R.GetEnvelopePointEx(t.env, t.idx, p)
    out[#out + 1] = { i = p, t = tm, v = v }
  end
  return out
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
  U.text(x + L.pad, y, fit(('item %s  -  click: point, drag: move, right click: delete; the generator on the right writes here'):format(t.label or ''), w - 2 * L.pad), U.AMBER)
  local gx, gy, gw, gh = x + L.pad, y + L.rh + 2, w - 2 * L.pad, h - L.rh - 4
  if gw < 20 or gh < 12 then return nil end
  U.set(U.BG); gfx.rect(gx, gy, gw, gh, 1)
  local t0, t1 = t.pos, t.pos + t.len
  local lo, hi = t.min or 0, t.max or 1
  if hi - lo < 1e-9 then hi = lo + 1 end
  local function X(tm) return gx + math.floor((tm - t0) / (t1 - t0) * (gw - 1) + 0.5) end
  local function Y(v) return gy + gh - 1 - math.floor(math.max(0, math.min(1, (v - lo) / (hi - lo))) * (gh - 1) + 0.5) end
  local function T(px) return t0 + math.max(0, math.min(1, (px - gx) / math.max(1, gw - 1))) * (t1 - t0) end
  local function V(py) return lo + math.max(0, math.min(1, (gy + gh - 1 - py) / math.max(1, gh - 1))) * (hi - lo) end
  -- сетка строк трекера: такты ярче
  if row_of and row_time then
    local r0, r1 = math.ceil(row_of(t0) - 1e-6), math.floor(row_of(t1) + 1e-6)
    local step = math.max(1, math.ceil((r1 - r0) / math.max(1, gw / 6)))
    for r = r0, r1, step do
      local px = X(row_time(r))
      U.set(U.DIM); gfx.rect(px, gy, 1, gh, 1)
    end
  end
  U.set(U.LINE); gfx.rect(gx, gy, gw, gh, 0)
  local pts = pts_of(t)
  -- кривая и точки
  U.set(U.CYAN)
  local px, py
  for _, p in ipairs(pts) do
    local qx, qy = X(p.t), Y(p.v)
    if px then gfx.line(px, py, qx, qy) end
    px, py = qx, qy
  end
  local hot
  for _, p in ipairs(pts) do
    local qx, qy = X(p.t), Y(p.v)
    local near = math.abs(mx - qx) <= 4 and math.abs(my - qy) <= 4
    if near then hot = p end
    U.set((near or (A.drag and A.drag.i == p.i)) and U.AMBER or U.CYAN); gfx.rect(qx - 2, qy - 2, 5, 5, 1)
  end
  local inside = mx >= gx and mx < gx + gw and my >= gy and my < gy + gh
  if A.drag then
    if cap & 1 == 1 then
      R.SetEnvelopePointEx(t.env, t.idx, A.drag.i, T(mx), V(my), nil, nil, nil, true)
      R.Envelope_SortPointsEx(t.env, t.idx)
      -- после сортировки номер мог смениться: ищем ближайшую к мыши
      local best, bd
      for _, p in ipairs(pts_of(t)) do local d = math.abs(X(p.t) - mx) + math.abs(Y(p.v) - my); if not bd or d < bd then best, bd = p.i, d end end
      A.drag.i = best or A.drag.i
    else
      A.drag = nil
      R.Undo_OnStateChange('automation item point')
      R.UpdateArrange()
    end
  elseif inside and press then
    if hot then A.drag = { i = hot.i }
    else
      R.InsertEnvelopePointEx(t.env, t.idx, T(mx), V(my), 0, 0, false, true)
      R.Envelope_SortPointsEx(t.env, t.idx)
      R.Undo_OnStateChange('automation item point')
      for _, p in ipairs(pts_of(t)) do if math.abs(X(p.t) - mx) <= 1 then A.drag = { i = p.i } end end
    end
  elseif inside and rpress and hot then
    R.DeleteEnvelopePointEx(t.env, t.idx, hot.i)
    R.Envelope_SortPointsEx(t.env, t.idx)
    R.Undo_OnStateChange('automation item point delete')
    R.UpdateArrange()
  end
  if inside then
    local v = (V(my) - lo) / (hi - lo)
    return { status = ('item point: %.3f s, %.0f%%  -  click add, drag move, right click delete'):format(T(mx) - t0, v * 100) }
  end
  return nil
end

return A
