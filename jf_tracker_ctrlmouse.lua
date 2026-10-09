-- jf_tracker_ctrlmouse.lua — мышь с Ctrl (8 окт): универсальная ручка.
--
-- Держишь Control — движение мыши меняет значение, без щелчка (относительно:
-- сдвинул мышь — значение сдвинулось, работает в любом месте экрана).
-- Вверх — больше; Shift — мелко. Что меняется (запоминается в момент нажатия
-- Ctrl и держится, пока он зажат): выделенные цели → цель под мышью → цель
-- в фокусе клавиатуры. Ровно две выделенные — XY: по горизонтали первая,
-- по вертикали вторая.
-- Выделение: Cmd+щелчок — добавить / убрать, Shift+щелчок — диапазон
-- параметров одного эффекта от прошлого щелчка.
--
-- Цель: { kind = 'fx', tid, fx, p, name } — параметр эффекта (нормированное
-- 0..1); { kind = 'trk', tid, what = 'vol' | 'pan' | 'width' …, name } —
-- громкость (дБ) / панорама трека. tid — GUID трека (ключ), сам объект
-- трека — t.track / t.col, их ставит main.
-- Чтение / запись — через io = { get(t), set(t, v) } в единицах вида
-- (CM.UNIT). Без reaper.* — тест tests/test_ctrlmouse.lua.

local CM = { sel = {}, order = {}, anchor = nil, latch = nil }

-- шаг на пиксель, пределы
CM.UNIT = {
  fx    = { step = 0.004, lo = 0,   hi = 1 },     -- 250 px — весь ход
  vol   = { step = 0.25,  lo = -60, hi = 12 },    -- дБ
  pan   = { step = 0.005, lo = -1,  hi = 1 },
  width = { step = 0.005, lo = -1,  hi = 1 },
  panl  = { step = 0.005, lo = -1,  hi = 1 },
  panr  = { step = 0.005, lo = -1,  hi = 1 },
}
CM.FINE = 0.1

function CM.key(t)
  if t.kind == 'fx' then return 'fx|' .. tostring(t.tid) .. '|' .. tostring(t.fx) .. '|' .. tostring(t.p) end
  return 'trk|' .. tostring(t.tid) .. '|' .. tostring(t.what)
end
function CM.unit(t) return CM.UNIT[t.kind == 'fx' and 'fx' or t.what] or CM.UNIT.fx end
function CM.has(t) return CM.sel[CM.key(t)] ~= nil end
function CM.count() return #CM.order end

local function add(t)
  local k = CM.key(t)
  if CM.sel[k] then return end
  CM.sel[k] = t; CM.order[#CM.order + 1] = t
end
local function remove(t)
  local k = CM.key(t)
  if not CM.sel[k] then return end
  CM.sel[k] = nil
  for i, e in ipairs(CM.order) do if CM.key(e) == k then table.remove(CM.order, i); break end end
end
function CM.clear() CM.sel, CM.order, CM.anchor = {}, {}, nil end

-- Cmd+щелчок: true — добавлена, false — убрана
function CM.toggle(t)
  CM.anchor = t
  if CM.has(t) then remove(t); return false end
  add(t); return true
end

-- Shift+щелчок: диапазон от якоря до t в списке list (параметры одного
-- эффекта по порядку: { {p = i, name = …}, … }); якорь другого эффекта или
-- нет якоря — просто добавить t. Возвращает число добавленных.
function CM.range(t, list)
  local a = CM.anchor
  if not (a and t.kind == 'fx' and a.kind == 'fx' and a.tid == t.tid and a.fx == t.fx and list) then
    local had = CM.has(t); add(t); CM.anchor = t; return had and 0 or 1
  end
  local ia, it
  for i, e in ipairs(list) do if e.p == a.p then ia = i end; if e.p == t.p then it = i end end
  if not (ia and it) then add(t); CM.anchor = t; return 1 end
  local n0 = #CM.order
  for i = math.min(ia, it), math.max(ia, it) do
    local e = list[i]
    add({ kind = 'fx', tid = t.tid, fx = t.fx, p = e.p, name = e.name, track = t.track })
  end
  CM.anchor = t
  return #CM.order - n0
end

-- нажатие Ctrl: что крутить. hover / focus — цели или nil
function CM.press(hover, focus, mx, my)
  local list
  if #CM.order > 0 then list = {}; for i, e in ipairs(CM.order) do list[i] = e end
  elseif hover then list = { hover }
  elseif focus then list = { focus } end
  if not list then CM.latch = nil; return nil end
  CM.latch = { list = list, mx = mx, my = my, xy = #list == 2 and #CM.order == 2, moved = false }
  return CM.latch
end

-- кадр с зажатым Ctrl: сдвиг мыши → значения. Возвращает изменённые цели
local function clamp(v, u) return math.max(u.lo, math.min(u.hi, v)) end
function CM.move(mx, my, fine, io)
  local L = CM.latch
  if not L then return nil end
  local dx, dy = mx - L.mx, L.my - my                 -- вверх — больше
  L.mx, L.my = mx, my
  if dx == 0 and dy == 0 then return nil end
  local k = fine and CM.FINE or 1
  local out = {}
  for i, t in ipairs(L.list) do
    local d = L.xy and (i == 1 and dx or dy) or dy
    if d ~= 0 then
      local u = CM.unit(t)
      local v0 = io.get(t)
      if v0 then
        local v = clamp(v0 + d * u.step * k, u)
        if v ~= v0 then io.set(t, v); out[#out + 1] = t; L.moved = true end
      end
    end
  end
  return out
end

function CM.release()
  local L = CM.latch
  CM.latch = nil
  return L
end

-- жест «треки» (Control+Option, 8 окт): окно по горизонтали — N зон, по
-- одной на трек; ведёшь вбок — выбор трека, мышь пошла вертикально —
-- фейдер выбранного (замок оси), снова явно вбок — опять выбор.
-- g = CM.gesture (nil до начала); возвращает g с полями ti (1..N), mode
-- 'pick' | 'fader', dy (пиксели вверх этого кадра в режиме fader)
CM.G_LOCK, CM.G_UNLOCK = 4, 14          -- px: вертикаль включает фейдер, вбок — снова выбор
-- ti0 (9 окт) — трек, с которого начать (под мышью / курсором): зоны
-- сдвигаются так, чтобы точка старта попала в него, дальше — вбок от него
function CM.gesture_step(g, mx, my, n, w, ti0)
  n = math.max(1, n)
  local function zone0(x) return math.floor(x / math.max(1, w) * n) + 1 end
  local function zone(x) return math.max(1, math.min(n, zone0(x) + (g and g.off or 0))) end
  if not g then
    local t = ti0 and math.max(1, math.min(n, ti0)) or math.max(1, math.min(n, zone0(mx)))
    return { ti = t, off = t - zone0(mx), mode = 'pick', mx = mx, my = my, ax = 0, ay = 0, dy = 0 }
  end
  local dx, dy = mx - g.mx, g.my - my
  g.mx, g.my, g.dy = mx, my, 0
  if g.mode == 'pick' then
    g.ti = zone(mx)
    if math.abs(dy) > math.abs(dx) then g.ay = g.ay + dy else g.ay = 0 end
    if math.abs(g.ay) >= CM.G_LOCK then g.mode, g.ax = 'fader', 0; g.dy = g.ay; g.ay = 0 end
  else
    if math.abs(dx) > 2 * math.abs(dy) then g.ax = g.ax + dx else g.ax = 0; g.dy = dy end
    if math.abs(g.ax) >= CM.G_UNLOCK then g.mode, g.ay = 'pick', 0; g.ti = zone(mx) end
  end
  return g
end

-- пан-пэд (Control+Option, трек выбран, + Cmd): всё окно — XY. x — пан /
-- баланс (лево … право), y — ширина: верх +1, середина 0, низ −1 (каналы
-- меняются местами). Двойной пан: левый = баланс − ширина, правый = баланс +
-- ширина (в центре оба по центру, вверх — расходятся, вниз — перекрещиваются)
function CM.panpad(mx, my, w, h)
  local function c(v) return math.max(-1, math.min(1, v)) end
  local pan = c((mx / math.max(1, w)) * 2 - 1)
  local width = c(1 - (my / math.max(1, h)) * 2)
  return pan, width, c(pan - width), c(pan + width)
end

return CM
