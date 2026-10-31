-- jf_tracker_panes.lua — раскладка окна как в tmux / zellij (9 окт).
--
-- Окно = дерево сплитов: узел { ax = 'h'|'v', kids, fr } ('h' — дети рядом,
-- линия раздела вертикальна; 'v' — друг под другом; fr — доли, сумма 1),
-- лист { panes = { id, … }, active } — панель или стек панелей (вкладки).
-- Трекер — лист 'tracker': нельзя закрыть и нельзя стекать. Остальные панели
-- (PN.PANELS) либо в дереве, либо в model.hidden. model.zoom — одна панель
-- на всё окно (tmux z). model.v растёт при каждой мутации — ключ мемо.
--
-- PN.layout(model, W, H, M)    → прямоугольники листов, ярлыков, подсказок,
--                                ручек между соседями, линий границ, порядок
--                                обхода (кольцо фокуса, номера 1..9)
-- PN.hit / focus_dir           → мышь и Cmd+hjkl
-- PN.move / swap / stack / unstack / split / hide / show / resize /
-- equalize / zoom / set_active / cycle — операции tmux / zellij / dwm
-- PN.encode / decode           → строка для ExtState и скринсетов
-- PN.LAYOUTS / PN.preset       → пресеты (tmux next-layout)
-- Без reaper.* и gfx — тест tests/test_panes.lua.

local PN = {}

-- ── реестр панелей ────────────────────────────────────────────────────────
-- key — буква в режиме PANE; hint — ключ строки подсказок (KH.BARS);
-- avail — флаг доступности (панель есть не всегда); side — куда встаёт
-- при показе без истории (сплитом от трекера)
PN.PANELS = {
  { id = 'tracker',    label = 'tracker',    key = 't', hint = 'tracker', fixed = true },
  { id = 'patterns',   label = 'patterns',   key = 'T', hint = 'matrix',  side = 'left' },   -- 19 окт вечер: снова своя панель — кубики + chain (из матрицы убраны)   -- 19 окт: кубики паттернов — в углу матрицы, своя панель — перебор   -- 19 окт: палитра паттернов матрицы — своя панель (над матрицей)
  { id = 'arranger',   label = 'arranger',   key = 'C', hint = 'arranger', side = 'left' },   -- 31 окт: chain + секции/плейлист песни + аранжировки (были в матрице и patterns)
  { id = 'matrix',     label = 'matrix',     key = 'm', hint = 'matrix',  side = 'left' },
  { id = 'browser',    label = 'browser',    key = 'b', hint = 'browser', side = 'right' },
  { id = 'map',        label = 'map',        key = 'w', hint = 'map',     side = 'right' },   -- 27 окт: карта сэмплов (web): папка / базы / проект / pm, мини-lf
  { id = 'inst',       label = 'lib',        key = 'l', hint = 'inst',    side = 'right' },
  { id = 'ctrl',       label = 'main',       key = 'n', hint = 'ctrl',    side = 'top' },
  { id = 'slices',     label = 'slices',     key = 's', hint = 'inst',    side = 'top', avail = 'merged' },   -- 19 окт: слайсы (и слои) — папкой в lib (как lf); панель выключена — вернуть: avail = 'slices_on'
  { id = 'sprops',     label = 'properties', key = 'e', hint = 'sprops',  side = 'right', avail = 'itemtab' },   -- 10 окт: свойства item / слайса — свой модуль (был справа во вкладке item)
  { id = 'nmod',       label = 'note mod',   key = 'N', hint = 'nmod',    side = 'right', avail = 'itemtab' },   -- 12 окт: модуляция, которую запускает нота (слоты инструмента)
  { id = 'mixer',      label = 'mixer',      key = 'x', hint = 'tracker', side = 'bottom', avail = 'mixer' },   -- 11 окт: нижний микшер — свой модуль (полоски под колонками треков)
  { id = 'tracks',     label = 'tracks',     key = 'k', hint = 'tracks',  side = 'left' },    -- 11 окт: Track Manager (как в REAPER): видимость и M S R матрицей
  { id = 'clipboard',  label = 'clipboard',  key = 'y', hint = 'clipboard', side = 'right' },   -- 13 окт: история yank — выбрать, что вставит p
  { id = 'undotree',   label = 'undo',       key = 'U', hint = 'undotree', side = 'right' },
  { id = 'perf',       label = 'performance', key = 'P', hint = 'perf',   side = 'left' },       -- 18 окт: performance / jftop — своя панель (была на месте матрицы)    -- 15 окт: дерево undo (как undotree в Vim)
  { id = 'actions',    label = 'actions',    key = 'A', hint = 'actions', side = 'right' },
  { id = 'reform',     label = 'reform',     key = 'R', hint = 'reform', side = 'right' },   -- 19 окт: reform выделенных нот (идея — Reform для Renoise)
  { id = 'humanizer',  label = 'humanizer',  key = 'H', hint = 'humanizer', side = 'right' },
  { id = 'phrases',    label = 'phrases',    key = 'F', hint = 'phrases', side = 'right' },   -- 31 окт: фразы проекта (ph:NAME)
  { id = 'lfogen',     label = 'lfogen',     key = 'G', hint = 'lfogen',  side = 'right' },   -- 31 окт: генератор кривых (lfo / podkat / follow) — своя панель (был колонкой automation)
  { id = 'renderer',   label = 'bouncer',    key = 'B', hint = 'renderer', side = 'right' },   -- 20 окт: баунс нот, инструмент → сэмплер (gB)   -- 19 окт: тонкий humanizer (help — на ?)
  { id = 'help',       label = 'help',       key = '?', hint = 'help',    side = 'right' },        -- 17 окт: коротко о модуле в фокусе и его клавиши     -- 16 окт: действия REAPER — секции, группы, шорткаты, избранное
  { id = 'notes',      label = 'notes',      key = 'o', hint = 'notes',   side = 'bottom' },
  { id = 'fxb',        label = 'fx',         key = 'f', hint = 'fxb',     side = 'right' },
  { id = 'pm',         label = 'pm',         key = 'p', hint = 'pm',      side = 'right' },   -- 9 окт: проекты — своя панель (был режим браузера)
  { id = 'dsp',        label = 'dsp',        key = 'd', hint = 'dsp',     side = 'bottom' },
  { id = 'retro',      label = 'rec',        key = 'r', hint = 'retro',   side = 'top', tab = true },
  { id = 'sample',     label = 'item',       key = 'i', hint = 'sample',  side = 'top', tab = true },
  { id = 'automation', label = 'automation', key = 'a', hint = 'automation', side = 'top', tab = true },   -- 12 окт: огибающие по времени (был id modulation)
  { id = 'modulation', label = 'modulation', key = 'u', hint = 'modulation', side = 'top', tab = true, avail = 'merged' },   -- 18 окт: страница automation (M) — сама вкладка не показывается   -- 12 окт: матрица LFO / ACS / link REAPER — своя вкладка
  { id = 'midi',       label = 'midi',       key = 'M', hint = 'midi',    side = 'top', tab = true },
  { id = 'harm',       label = 'harmonizer', key = 'h', hint = 'harm',    side = 'top', tab = true },
  { id = 'macros',     label = 'macros',     key = 'q', hint = 'macros',  side = 'top', tab = true },   -- 9 окт: записанные / свои / встроенные макросы
  { id = 'scopes',     label = 'scopes',     key = 'c', hint = 'master',  side = 'top', tab = true },
  { id = 'master',     label = 'master',     key = 'S', hint = 'master',  side = 'top', tab = true },
  { id = 'video',      label = 'video',      key = 'v', hint = 'video',   side = 'top', tab = true },
  { id = 'visor',      label = 'visor',      key = 'V', hint = 'visor',   side = 'top', tab = true },   -- 10 окт: шейдеры ReaVisor из трекера
  { id = 'grid',       label = 'grid',       key = 'g', hint = 'grid',    side = 'top', tab = true },   -- 15 окт: всегда (arc / грид; было за dev-опцией gridtab — в стек вставала невидимой)
  { id = 'hints',      label = 'hints',      key = 'I', hint = 'hints',   side = 'top' },
  { id = 'manual',     label = 'manual',     key = 'Z', hint = 'help',    side = 'right' },   -- 29 окт: вся справка (была на всё окно)
  { id = 'console',    label = 'console',    key = 'E', hint = 'console', side = 'bottom' },   -- 28 окт: Strudel-строки пишут ноты в паттерн (:console, \\ E)   -- 28 окт: что делает модуль под мышью / в фокусе (\\ h)
  { id = 'garden',     label = 'orca',       key = 'O', hint = 'orca',    side = 'top', tab = true, avail = 'dev' },
}
PN.BY, PN.TABS, PN.BYKEY = {}, {}, {}
for _, p in ipairs(PN.PANELS) do
  PN.BY[p.id] = p
  PN.BYKEY[p.key] = p.id
  if p.tab then PN.TABS[#PN.TABS + 1] = p.id end
end

local function leaf(...) return { panes = { ... }, active = 1 } end
local function node(ax, fr, ...) return { ax = ax, kids = { ... }, fr = fr } end
local function is_leaf(n) return n.panes ~= nil end
PN.is_leaf = is_leaf

-- вид по умолчанию (9 окт): слева main над матрицей, сверху вкладки, снизу
-- fx list | dsp, справа lib, slices, браузер; заметки спрятаны
function PN.DEFAULT()
  local tabs = leaf(table.unpack(PN.TABS))
  for i, id in ipairs(tabs.panes) do if id == 'master' then tabs.active = i end end
  return PN.normalize({ v = 1,
    root = node('h', { 0.14, 0.68, 0.18 },
      node('v', { 0.3, 0.7 }, leaf('ctrl'), leaf('matrix')),
      node('v', { 0.22, 0.60, 0.18 },
        tabs,
        node('v', { 0.72, 0.28 }, leaf('tracker'), leaf('mixer')),   -- 11 окт: микшер — модуль под трекером
        leaf('dsp')),
      -- 9 окт: browser | pm | fx — один стек справа внизу
      node('v', { 0.40, 0.20, 0.40 }, leaf('inst'), leaf('slices'), leaf('browser', 'pm', 'fxb'))),
    hidden = { notes = true } })
end

-- ── обход и нормализация ──────────────────────────────────────────────────
local function walk(n, fn, parent, idx)
  fn(n, parent, idx)
  if not is_leaf(n) then for i, k in ipairs(n.kids) do walk(k, fn, n, i) end end
end

-- 10 окт: вкладки стеков по алфавиту (опция tababc) — порядок в самой модели, тогда
-- и ярлыки, и Tab / Ctrl+Tab идут одинаково; активная остаётся активной
function PN.sort_stacks(model)
  walk(model.root, function(n)
    if is_leaf(n) and #n.panes > 1 then
      local act = n.panes[n.active]
      table.sort(n.panes, function(a, b)
        local la, lb = (PN.BY[a] and PN.BY[a].label or a):lower(), (PN.BY[b] and PN.BY[b].label or b):lower()
        if la ~= lb then return la < lb end
        return a < b
      end)
      for k, id in ipairs(n.panes) do if id == act then n.active = k end end
    end
  end)
end

-- лист с id, его родитель и индекс (nil — скрыта / нет)
function PN.find(model, id)
  local lf, par, ix, pi
  walk(model.root, function(n, p, i)
    if lf then return end
    if is_leaf(n) then for k, pid in ipairs(n.panes) do if pid == id then lf, par, ix, pi = n, p, i, k; return end end end
  end)
  return lf, par, ix, pi
end

local function parent_of(model, target)
  local par, ix
  walk(model.root, function(n, p, i) if n == target then par, ix = p, i end end)
  return par, ix
end

local function norm_fr(n)
  local s = 0
  for i = 1, #n.kids do n.fr[i] = math.max(0.02, tonumber(n.fr[i]) or 1); s = s + n.fr[i] end
  for i = 1, #n.kids do n.fr[i] = n.fr[i] / s end
  for i = #n.kids + 1, #n.fr do n.fr[i] = nil end
end

-- рекурсивно: пустые листы долой, узел с одним ребёнком — его ребёнок,
-- узел без детей — nil; доли нормированы
local function prune(n)
  if is_leaf(n) then
    if #n.panes == 0 then return nil end
    n.active = math.max(1, math.min(#n.panes, n.active or 1))
    return n
  end
  local kids, fr = {}, {}
  for i, k in ipairs(n.kids) do
    local kk = prune(k)
    if kk then kids[#kids + 1] = kk; fr[#fr + 1] = n.fr and n.fr[i] or 1 end
  end
  if #kids == 0 then return nil end
  if #kids == 1 then return kids[1] end
  n.kids, n.fr = kids, fr
  norm_fr(n)
  return n
end

function PN.normalize(model)
  model = model or {}
  model.v = model.v or 1
  model.hidden = model.hidden or {}
  local seen = {}
  if model.root then
    walk(model.root, function(n)
      if is_leaf(n) then
        local out = {}
        for _, id in ipairs(n.panes) do
          if PN.BY[id] and not seen[id] then seen[id] = true; out[#out + 1] = id end
        end
        n.panes = out
      end
    end)
    model.root = prune(model.root)
  end
  if not seen.tracker then
    local t = leaf('tracker')
    model.root = model.root and node('h', { 0.3, 0.7 }, model.root, t) or t
    seen.tracker = true
  end
  -- трекер не стекается: из стека — отдельным листом рядом
  local lf, par, ix = PN.find(model, 'tracker')
  if lf and #lf.panes > 1 then
    for k, id in ipairs(lf.panes) do if id == 'tracker' then table.remove(lf.panes, k); break end end
    lf.active = math.max(1, math.min(#lf.panes, lf.active))
    local t = leaf('tracker')
    local wrap = node('v', { 0.3, 0.7 }, lf, t)
    if par then par.kids[ix] = wrap else model.root = wrap end
  end
  local hidden = {}
  for _, p in ipairs(PN.PANELS) do if not seen[p.id] and not p.fixed then hidden[p.id] = true end end
  model.hidden = hidden
  if model.zoom and (not seen[model.zoom]) then model.zoom = nil end
  return model
end

local function bump(model) model.v = (model.v or 1) + 1; return true end

function PN.visible(model, id) return (PN.find(model, id)) ~= nil end
function PN.is_active(model, id)
  local lf, _, _, pi = PN.find(model, id)
  return lf ~= nil and lf.active == pi
end
function PN.active_of(model, id)
  local lf = PN.find(model, id)
  return lf and lf.panes[lf.active]
end
function PN.set_active(model, id)
  local lf, _, _, pi = PN.find(model, id)
  if not lf or lf.active == pi then return false end
  lf.active = pi
  return bump(model)
end
-- следующая / предыдущая панель в стеке листа (по кругу)
function PN.cycle(model, id, dir)
  local lf, _, _, pi = PN.find(model, id)
  if not lf or #lf.panes < 2 then return nil end
  return lf.panes[(pi - 1 + (dir or 1)) % #lf.panes + 1]
end
function PN.stack_of(model, id)
  local lf = PN.find(model, id)
  return lf and lf.panes
end

-- ── раскладка ─────────────────────────────────────────────────────────────
-- M = { rh, cw, pad, tab_h, hint_h, sep, grip, tabw(id) → px, avail(id) → bool }
local function avail(M, id) return not M.avail or M.avail(id) end
-- жив ли узел (есть хоть одна доступная панель)
local function alive(M, n)
  if is_leaf(n) then
    for _, id in ipairs(n.panes) do if avail(M, id) then return true end end
    return false
  end
  for _, k in ipairs(n.kids) do if alive(M, k) then return true end end
  return false
end
-- 20 окт: свёрнутый лист (zm) — по оси родителя только строка вкладок (v) / узкая полоса (h)
local function min_px(M, ax) return ax == 'v' and M.tab_h or 4 * M.cw end
local function leaf_min(M, n, ax)
  if n.min then return min_px(M, ax) end
  if ax == 'v' then
    local m = (n.panes[1] == 'tracker' and 4 or 2) * M.rh
    -- панель может требовать своё (item: все параметры сэмпла) — по всему стеку,
    -- чтобы высота не прыгала при смене вкладки
    if M.minh then for _, id in ipairs(n.panes) do if avail(M, id) then local v = M.minh(id); if v and v > m then m = v end end end end
    return m + M.tab_h + M.hint_h
  end
  return 8 * M.cw
end
local function node_min(M, n, ax)
  if is_leaf(n) then return leaf_min(M, n, ax) end
  local s = 0
  if n.ax == ax then
    for i, k in ipairs(n.kids) do if alive(M, k) then s = s + node_min(M, k, ax) + (i > 1 and M.sep or 0) end end
  else
    for _, k in ipairs(n.kids) do if alive(M, k) then s = math.max(s, node_min(M, k, ax)) end end
  end
  return s
end

local function place_leaf(lay, M, n, x, y, w, h)
  local cell = { node = n, x = x, y = y, w = w, h = h, tabs = {} }
  local tracker = n.panes[1] == 'tracker'
  local th = tracker and 0 or M.tab_h
  local hh = (tracker and M.hint_trk) or ((M.hint_h == 0) and 0 or M.hint_h)   -- 10 окт: строка клавиш — и у трекера (15 окт: tabs — только у него)
  -- активная доступная панель: активная, иначе первая доступная
  local act = n.panes[n.active]
  if not avail(M, act) then for _, id in ipairs(n.panes) do if avail(M, id) then act = id; break end end end
  cell.active_id = act
  if th > 0 then
    cell.tab = { x = x, y = y, w = w, h = th }
    local ws, tot = {}, 0
    for _, id in ipairs(n.panes) do
      if avail(M, id) then ws[id] = (M.tabw and M.tabw(id) or (#PN.BY[id].label * M.cw)) + M.pad + 3; tot = tot + ws[id] end   -- 31 окт: вкладки встык
    end
    local k = tot > w and (w / tot) or 1              -- не влезают — ужать поровну
    local tx = x
    for _, id in ipairs(n.panes) do
      if avail(M, id) then
        local tw = math.max(3 * M.cw, math.floor(ws[id] * k))
        cell.tabs[#cell.tabs + 1] = { id = id, x = tx, y = y, w = tw, h = th }
        tx = tx + tw
      end
    end
  end
  if n.min then hh = 0; cell.min = true end   -- 20 окт: свёрнут — без строки клавиш и тела
  if hh > 0 then cell.hint = { x = x, y = y + h - hh, w = w, h = hh } end
  cell.content = { x = x, y = y + th, w = w, h = n.min and 0 or math.max(0, h - th - hh) }
  lay.cells[#lay.cells + 1] = cell
  for _, id in ipairs(n.panes) do if avail(M, id) then lay.by_panel[id] = cell end end
  if not n.min then lay.rects[act] = cell.content end
  lay.order[#lay.order + 1] = act
  cell.num = #lay.order
end

local function place(lay, M, n, x, y, w, h)
  lay.nodes[n] = { x = x, y = y, w = w, h = h }
  if is_leaf(n) then place_leaf(lay, M, n, x, y, w, h); return end
  local kids, frs, mins = {}, {}, {}
  local fs = 0
  for i, k in ipairs(n.kids) do
    if alive(M, k) then kids[#kids + 1] = k; frs[#frs + 1] = n.fr[i]; fs = fs + n.fr[i]; mins[#mins + 1] = node_min(M, k, n.ax) end
  end
  if #kids == 0 then return end
  local total = (n.ax == 'h' and w or h) - M.sep * (#kids - 1)
  local px, used = {}, 0
  -- 20 окт: свёрнутые листы — свой размер, остальным — остаток по долям
  local fixed, fs2 = 0, 0
  for i, k in ipairs(kids) do if k.min then fixed = fixed + min_px(M, n.ax) else fs2 = fs2 + frs[i] end end
  if fs2 <= 0 then fs2, fixed = fs, 0 end
  for i, k in ipairs(kids) do
    if k.min and fixed > 0 then px[i] = min_px(M, n.ax) else px[i] = math.floor(frs[i] / fs2 * (total - fixed) + 0.5) end
  end
  -- минимумы: добираем у самого большого
  for i = 1, #kids do
    if px[i] < mins[i] then
      local need = mins[i] - px[i]
      local big, bv = nil, -1
      for j = 1, #kids do if j ~= i and not kids[j].min and px[j] - mins[j] > bv then big, bv = j, px[j] - mins[j] end end
      if big and bv > 0 then local d = math.min(need, bv); px[big] = px[big] - d; px[i] = px[i] + d end
    end
  end
  -- последний несвёрнутый — остаток: сумма точная
  local rest = #kids
  for i = #kids, 1, -1 do if not kids[i].min then rest = i; break end end
  for i = 1, #kids do if i ~= rest then used = used + px[i] end end
  px[rest] = math.max(0, total - used)
  local cur = n.ax == 'h' and x or y
  for i, k in ipairs(kids) do
    if n.ax == 'h' then place(lay, M, k, cur, y, px[i], h) else place(lay, M, k, x, cur, w, px[i]) end
    cur = cur + px[i]
    if i < #kids then
      local g = M.grip or 3
      if n.ax == 'h' then
        lay.seps[#lay.seps + 1] = { x = cur, y = y, w = M.sep, h = h }
        lay.grips[#lay.grips + 1] = { node = n, i = i, ax = 'h', x = cur - (g - M.sep) // 2, y = y, w = g, h = h, kid = k, next = kids[i + 1] }
      else
        lay.seps[#lay.seps + 1] = { x = x, y = cur, w = w, h = M.sep }
        lay.grips[#lay.grips + 1] = { node = n, i = i, ax = 'v', x = x, y = cur - (g - M.sep) // 2, w = w, h = g, kid = k, next = kids[i + 1] }
      end
      cur = cur + M.sep
    end
  end
end

function PN.layout(model, W, H, M, Y0)   -- 28 окт: Y0 — отступ сверху (окно без рамки на 1 px выше рабочей области)
  Y0 = Y0 or 0
  local lay = { v = model.v, W = W, H = H, cells = {}, by_panel = {}, rects = {}, order = {}, grips = {}, seps = {}, nodes = {}, M = M }   -- M: минимумы для протяжки ручек
  local z = model.zoom and PN.find(model, model.zoom)
  -- 22 окт: зум нескольких листов друг под другом (zz в DSP: микшер над DSP на всё окно)
  local zl = {}
  for _, id in ipairs(model.zoomv or {}) do local l = PN.find(model, id); if l and alive(M, l) then zl[#zl + 1] = l end end
  if #zl > 0 then
    -- 23 окт: колонка справа (lib, браузер / fx list) — её листы как есть, во всю высоту
    local sl, seen = {}, {}
    for _, id in ipairs(model.zoomside or {}) do local l = PN.find(model, id); if l and alive(M, l) and not seen[l] then seen[l] = true; sl[#sl + 1] = l end end
    local SW = #sl > 0 and math.floor(W * (model.zoomside_w or 0.18)) or 0
    local LW = W - (SW > 0 and SW + M.sep or 0)
    local y0, fr = Y0, model.zoomfr or {}
    for i, l in ipairs(zl) do
      local hh = i == #zl and H - y0 or math.floor((H - Y0 - M.sep * (#zl - 1)) * (fr[i] or 1 / #zl))
      place_leaf(lay, M, l, 0, y0, LW, hh); lay.nodes[l] = { x = 0, y = y0, w = LW, h = hh }
      y0 = y0 + hh + M.sep
    end
    local sy = Y0
    for i, l in ipairs(sl) do
      local hh = i == #sl and H - sy or math.floor((H - Y0 - M.sep * (#sl - 1)) / #sl)
      place_leaf(lay, M, l, LW + M.sep, sy, SW, hh); lay.nodes[l] = { x = LW + M.sep, y = sy, w = SW, h = hh }
      sy = sy + hh + M.sep
    end
  elseif z and alive(M, z) then place_leaf(lay, M, z, 0, Y0, W, H - Y0); lay.nodes[z] = { x = 0, y = Y0, w = W, h = H - Y0 }
  else place(lay, M, model.root, 0, Y0, W, H - Y0) end
  -- трекер — первым в кольце (номер 1), остальные по обходу
  for i, id in ipairs(lay.order) do
    if id == 'tracker' and i > 1 then table.remove(lay.order, i); table.insert(lay.order, 1, id); break end
  end
  for i, id in ipairs(lay.order) do local c = lay.by_panel[id]; if c then c.num = i end end
  return lay
end

local function inr(r, x, y) return r and x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h end
PN.inr = inr

-- мышь: ручка → ярлык → строка ярлыков → подсказка → содержимое
function PN.hit(lay, x, y, out)
  out = out or {}
  for k in pairs(out) do out[k] = nil end
  for _, g in ipairs(lay.grips) do if inr(g, x, y) then out.kind, out.grip = 'grip', g; return out end end
  for _, c in ipairs(lay.cells) do
    if inr(c, x, y) then
      out.cell, out.id = c, c.active_id
      if c.tab and inr(c.tab, x, y) then
        out.kind = 'tabbar'
        for i, t in ipairs(c.tabs) do if inr(t, x, y) then out.kind, out.id, out.index = 'tab', t.id, i; break end end
      elseif c.hint and inr(c.hint, x, y) then out.kind = 'hint'
      else out.kind = 'panel' end
      return out
    end
  end
  return nil
end

-- сосед по направлению (tmux select-pane -LDUR): лист за ребром с
-- наибольшим перекрытием; dir — 'l' 'r' 'u' 'd'
function PN.focus_dir(lay, id, dir)
  local c = lay.by_panel[id]
  if not c then return nil end
  local best, bo = nil, 0
  for _, o in ipairs(lay.cells) do
    if o ~= c then
      local ov, adj
      if dir == 'l' or dir == 'r' then
        ov = math.min(c.y + c.h, o.y + o.h) - math.max(c.y, o.y)
        adj = dir == 'l' and (o.x + o.w <= c.x and o.x + o.w >= c.x - 8) or (dir == 'r' and o.x >= c.x + c.w and o.x <= c.x + c.w + 8)
      else
        ov = math.min(c.x + c.w, o.x + o.w) - math.max(c.x, o.x)
        adj = dir == 'u' and (o.y + o.h <= c.y and o.y + o.h >= c.y - 8) or (dir == 'd' and o.y >= c.y + c.h and o.y <= c.y + c.h + 8)
      end
      if adj and ov > bo then best, bo = o, ov end
    end
  end
  return best and best.active_id
end

-- ── операции ──────────────────────────────────────────────────────────────
local AX = { l = 'h', r = 'h', u = 'v', d = 'v' }
local SG = { l = -1, r = 1, u = -1, d = 1 }

-- убрать панель из дерева (лист / узлы схлопываются); возвращает лист,
-- который занял место (для «рядом с тем, откуда пришли»)
local function detach(model, id)
  local lf, par, ix, pi = PN.find(model, id)
  if not lf then return nil end
  table.remove(lf.panes, pi)
  if #lf.panes > 0 then
    if lf.active > #lf.panes then lf.active = #lf.panes elseif lf.active > pi then lf.active = lf.active - 1 end
    return lf
  end
  -- лист опустел
  if not par then model.root = nil; return nil end
  table.remove(par.kids, ix); table.remove(par.fr, ix)
  if #par.kids == 1 then
    local only = par.kids[1]
    local gp, gi = parent_of(model, par)
    if gp then gp.kids[gi] = only else model.root = only end
    return only
  end
  norm_fr(par)
  return par.kids[math.min(ix, #par.kids)]
end

-- вставить лист рядом с anchor (узел дерева) со стороны dir: в родителе той
-- же оси — соседом, иначе — обернуть anchor узлом; share — доля новичка
local function insert_beside(model, anchor, newleaf, dir, share)
  share = share or 0.3
  local ax, sg = AX[dir], SG[dir]
  local par, ix = parent_of(model, anchor)
  if par and par.ax == ax then
    local pos = sg < 0 and ix or ix + 1
    local f = par.fr[ix]
    table.insert(par.kids, pos, newleaf)
    table.insert(par.fr, pos, f * share)
    par.fr[sg < 0 and pos + 1 or ix] = f * (1 - share)
    norm_fr(par)
    return
  end
  local wrap = sg < 0 and node(ax, { share, 1 - share }, newleaf, anchor) or node(ax, { 1 - share, share }, anchor, newleaf)
  if par then par.kids[ix] = wrap else model.root = wrap end
end

-- панель из стека — отдельным листом рядом (zellij break-out)
local function breakout(model, id, dir)
  local lf = PN.find(model, id)
  if not lf or #lf.panes < 2 then return false end
  detach(model, id)
  insert_beside(model, lf, leaf(id), dir or 'd', 0.5)
  return true
end

-- перенос по направлению (i3 / zellij move): своп с соседом в родителе той
-- же оси → иначе подняться к предку этой оси и встать рядом с веткой,
-- откуда пришли → у края окна — новый сплит с краю
function PN.move(model, id, dir)
  local lf, par, ix = PN.find(model, id)
  if not lf or not AX[dir] then return false end
  if #lf.panes > 1 then breakout(model, id, dir); return bump(model) end
  if not par then return false end                           -- единственный лист
  local ax, sg = AX[dir], SG[dir]
  if par.ax == ax and par.kids[ix + sg] then
    par.kids[ix], par.kids[ix + sg] = par.kids[ix + sg], par.kids[ix]
    return bump(model)
  end
  -- вынуть и подняться (detach опустошает лист — вставляется новый); родитель
  -- остался (2+ детей) — подъём с него самого, иначе — с того, кто занял место
  local came = detach(model, id)
  lf = leaf(id)
  local cur = (#par.kids >= 2 and parent_of(model, par) ~= nil or model.root == par) and par or came
  while cur do
    local p, i = parent_of(model, cur)
    if not p then break end
    if p.ax == ax then
      local pos = sg < 0 and i or i + 1
      local n = #p.kids
      table.insert(p.kids, pos, lf)
      for k = 1, #p.fr do p.fr[k] = p.fr[k] * n / (n + 1) end
      table.insert(p.fr, pos, 1 / (n + 1))
      norm_fr(p)
      return bump(model)
    end
    cur = p
  end
  -- корень другой оси — обернуть
  local root = model.root
  model.root = sg < 0 and node(ax, { 0.2, 0.8 }, lf, root) or node(ax, { 0.8, 0.2 }, root, lf)
  return bump(model)
end

-- поменять две панели местами (tmux swap-pane), стеки — по месту панели
function PN.swap(model, a, b)
  if a == b then return false end
  local la, _, _, pa = PN.find(model, a)
  local lb, _, _, pb = PN.find(model, b)
  if not (la and lb) or la == lb then return false end
  if a == 'tracker' and #lb.panes > 1 or b == 'tracker' and #la.panes > 1 then return false end
  la.panes[pa], lb.panes[pb] = b, a
  return bump(model)
end

-- панель — в стек листа другой панели (zellij stack)
function PN.stack(model, id, into)
  if id == 'tracker' or into == 'tracker' or id == into then return false end
  local lt = PN.find(model, into)
  if not lt then return false end
  if model.hidden[id] then model.hidden[id] = nil else detach(model, id) end
  lt = PN.find(model, into)                                  -- после detach дерево могло сложиться
  lt.panes[#lt.panes + 1] = id
  lt.active = #lt.panes
  return bump(model)
end
function PN.unstack(model, id, dir)
  if breakout(model, id, dir) then return bump(model) end
  return false
end

-- панель (скрытая или видимая) — сплитом от листа панели at со стороны dir
function PN.split(model, at, id, dir, share)
  if id == at or not AX[dir] then return false end
  if not PN.find(model, at) then return false end
  if id == 'tracker' then return false end
  if model.hidden[id] then model.hidden[id] = nil else detach(model, id) end
  local la = PN.find(model, at)
  insert_beside(model, la, leaf(id), dir, share or 0.3)
  return bump(model)
end

function PN.hide(model, id)
  if id == 'tracker' or not PN.find(model, id) then return false end
  detach(model, id)
  model.hidden[id] = true
  if model.zoom == id then model.zoom = nil end
  return bump(model)
end
-- 11 окт: полоски микшера стоят под колонками трекера — модуль mixer живёт только
-- прямо под трекером, отдельным листом; ушёл в стек / вбок — возвращается (true — вернули)
function PN.pin_mixer(model)
  local lf, par, ix = PN.find(model, 'mixer')
  if not lf then return false end
  local tl = PN.find(model, 'tracker')
  -- 16 окт: и вкладкой в стеке (с dsp и т.п.), если этот стек — прямо под трекером: колонки те же
  -- 16 окт (вечер): «прямо под трекером» — сосед сверху в вертикальном ряду СОДЕРЖИТ трекер (сам лист
  -- или колонку, где трекер внизу) — раньше требовался сам лист трекера, и миксер выталкивало
  local function holds(n)
    if not n then return false end
    if n == tl then return #tl.panes == 1 end
    if n.kids then
      if n.ax == 'v' then return holds(n.kids[#n.kids]) end           -- в колонке — нижний
      for _, k in ipairs(n.kids) do if holds(k) then return true end end
    end
    return false
  end
  -- 16 окт (ночь): стек мог оказаться в горизонтальном узле (рядом встали properties у вкладки item) —
  -- поднимаемся по предкам до вертикального ряда, где сосед сверху держит трекер
  local node, p2, i2 = lf, par, ix
  while p2 do
    if p2.ax == 'v' and i2 and i2 > 1 and holds(p2.kids[i2 - 1]) then return false end
    node = p2
    p2, i2 = parent_of(model, node)
  end
  detach(model, 'mixer')
  insert_beside(model, PN.find(model, 'tracker'), leaf('mixer'), 'd', 0.28)
  return bump(model)
end
-- 11 окт: properties обязательны отдельной панелью — пока видна вкладка item (sample):
-- скрыт или лежит в одном стеке с item → встаёт справа от item; true — что-то поменяли
function PN.pin_sprops(model)
  local sl = PN.find(model, 'sample')
  if not sl then return false end
  local pl = PN.find(model, 'sprops')
  if pl and pl ~= sl then return false end
  if pl then detach(model, 'sprops') else model.hidden['sprops'] = nil end
  insert_beside(model, PN.find(model, 'sample'), leaf('sprops'), 'r', 0.4)
  return bump(model)
end
-- 11 окт: модули, появившиеся позже раскладки (в строке скринсета их нет совсем —
-- ни в дереве, ни в H:) — встают на своё место по умолчанию; true — что-то добавили
local function stack_keep(m, id, into)
  local cur = PN.active_of(m, into)
  if not PN.stack(m, id, into) then return false end
  if cur then PN.set_active(m, cur) end
  return true
end
-- 13 окт: панель id — вкладкой в стек панели into (активная вкладка не меняется); уже там — ничего
function PN.keep_in(m, id, into)
  if not PN.visible(m, into) then return false end
  local a, b = PN.find(m, id), PN.find(m, into)
  if a and a == b then return false end
  if a then detach(m, id) end
  m.hidden[id] = true
  return stack_keep(m, id, into)
end
PN.LATE = {
  { 'sprops', function(m) return PN.visible(m, 'sample') and PN.split(m, 'sample', 'sprops', 'r', 0.4) end },
  { 'mixer', function(m) return PN.split(m, 'tracker', 'mixer', 'd', 0.28) end },
  -- 12 окт: note mod — вкладкой в стеке properties (item = волна / свойства / модуляция)
  { 'nmod', function(m) return PN.visible(m, 'sprops') and stack_keep(m, 'nmod', 'sprops') end },
  { 'visor', function(m) return PN.visible(m, 'matrix') and stack_keep(m, 'visor', 'matrix') end },
  -- 12 окт: вкладка automation отделилась от modulation — старая строка знает только modulation
  { 'automation', function(m) return PN.visible(m, 'modulation') and stack_keep(m, 'automation', 'modulation') end },
  { 'macros', function(m)
    for _, at in ipairs({ 'sample', 'retro', 'automation' }) do if PN.visible(m, at) then return stack_keep(m, 'macros', at) end end
  end },
}
function PN.add_new(model, raw)
  if type(raw) ~= 'string' or raw == '' then return false end
  local any = false
  for _, it in ipairs(PN.LATE) do
    if not raw:find('%f[%w]' .. it[1] .. '%f[^%w]') and not PN.visible(model, it[1]) then
      model.hidden[it[1]] = true
      if it[2](model) then any = true end
    end
  end
  return any
end
local SIDE_DIR = { left = 'l', right = 'r', top = 'u', bottom = 'd' }
-- показать: at — панель, рядом с которой (по умолчанию трекер со стороны
-- PANELS[id].side); share — доля новичка
function PN.show(model, id, at, share)
  if not model.hidden[id] then return false end
  local p = PN.BY[id]
  if not p then return false end
  return PN.split(model, at or 'tracker', id, SIDE_DIR[p.side] or 'd', share or 0.25)
end
function PN.toggle(model, id, at, share)
  if model.hidden[id] then return PN.show(model, id, at, share) end
  return PN.hide(model, id)
end

-- размер: доля листа в ближайшем предке оси ax меняется на delta, сосед —
-- на −delta (tmux resize-pane); ax 'h' — ширина, 'v' — высота
function PN.resize(model, id, ax, delta)
  local lf = PN.find(model, id)
  if not lf then return false end
  local cur = lf
  while true do
    local p, i = parent_of(model, cur)
    if not p then return false end
    if p.ax == ax and #p.kids > 1 then
      local j = p.kids[i + 1] and i + 1 or i - 1
      local d = math.max(-(p.fr[i] - 0.05), math.min(p.fr[j] - 0.05, delta))
      p.fr[i], p.fr[j] = p.fr[i] + d, p.fr[j] - d
      return bump(model)
    end
    cur = p
  end
end
-- ручка мышью: граница i узла grip.node сдвигается на dpx (lay — для размера узла)
function PN.drag_grip(model, lay, grip, dpx)
  local r = lay.nodes[grip.node]
  if not r then return false end
  local size = grip.ax == 'h' and r.w or r.h
  if size <= 0 then return false end
  local p, i = grip.node, grip.i
  -- 22 окт: упёрлись в минимум соседа — дальше не тянуть: раскладка добирала его минимум у самого большого
  -- соседа, и ехал чужой край (тянешь вниз — растёт вверх). Запас сжатия — по цепочке до листа у ручки
  local M = lay.M
  if M then
    local function room(n, last)
      local r2 = lay.nodes[n]
      if not r2 then return 0 end
      local sz = grip.ax == 'h' and r2.w or r2.h
      local free = sz - node_min(M, n, grip.ax)
      if not is_leaf(n) and n.ax == grip.ax then
        local edge
        for k = (last and #n.kids or 1), (last and 1 or #n.kids), (last and -1 or 1) do if lay.nodes[n.kids[k]] then edge = n.kids[k]; break end end
        if edge then free = math.min(free, room(edge, last)) end
      end
      return math.max(0, free)
    end
    local k1, k2 = grip.kid or p.kids[i], grip.next or p.kids[i + 1]
    if dpx < 0 then dpx = math.max(dpx, -room(k1, true)) else dpx = math.min(dpx, room(k2, false)) end
    if math.abs(dpx) < 0.5 then return false end
  end
  local d = dpx / size
  d = math.max(-(p.fr[i] - 0.05), math.min(p.fr[i + 1] - 0.05, d))
  p.fr[i], p.fr[i + 1] = p.fr[i] + d, p.fr[i + 1] - d
  -- 22 окт: сосед по ручке — узел той же оси (трекер над микшером в одном узле): сдвиг получает только его
  -- лист у ручки, остальные внутри стоят на месте (было: делился по долям — тянешь низ микшера, едет его верх)
  local px = d * size
  local function keep(n, delta, last)
    if not n or is_leaf(n) or n.ax ~= grip.ax then return end
    local ids, sz, fs, tot = {}, {}, 0, 0
    for k, kid in ipairs(n.kids) do
      local r2 = lay.nodes[kid]
      if r2 then ids[#ids + 1] = k; sz[#sz + 1] = grip.ax == 'h' and r2.w or r2.h; fs = fs + n.fr[k]; tot = tot + sz[#sz] end
    end
    if #ids < 2 or tot <= 0 then return end
    local e = last and #ids or 1
    sz[e] = math.max(1, sz[e] + delta)
    local t2 = 0; for _, v in ipairs(sz) do t2 = t2 + v end
    for j, k in ipairs(ids) do n.fr[k] = sz[j] / t2 * fs end
    keep(n.kids[ids[e]], delta, last)
  end
  if math.abs(px) >= 0.5 then
    local k1, k2 = grip.kid or p.kids[i], grip.next or p.kids[i + 1]
    keep(k1, px, true)       -- сторона до ручки: растёт / сжимается её последний лист
    keep(k2, -px, false)     -- после ручки: первый
  end
  return bump(model)
end
function PN.equalize(model, id)
  local lf, par = PN.find(model, id)
  if not par then return false end
  for i = 1, #par.kids do par.fr[i] = 1 / #par.kids end
  return bump(model)
end
-- 20 окт: zm — свернуть лист панели до строки вкладок / развернуть; трекер не сворачивается
function PN.minimize(model, id)
  local lf = PN.find(model, id)
  if not lf or id == 'tracker' then return false end
  lf.min = not lf.min or nil
  return bump(model), lf.min == true
end
function PN.zoom(model, id)
  if id and not PN.find(model, id) then return false end
  model.zoom = (id and model.zoom ~= id) and id or nil
  model.zoomv, model.zoomfr, model.zoomside = nil, nil, nil
  return bump(model)
end
-- 22 окт: зум нескольких панелей друг под другом (ids сверху вниз, fr — доли); ещё раз — назад.
-- Скрытые / закрытые пропускаются; не на экране ни одной — false
function PN.zoom_multi(model, ids, fr, side)
  if model.zoomv then model.zoomv, model.zoomfr, model.zoomside = nil, nil, nil; return bump(model) end
  model.zoomside = side
  local have, hf = {}, {}
  for i, id in ipairs(ids) do if PN.find(model, id) then have[#have + 1] = id; hf[#hf + 1] = fr and fr[i] or 1 end end
  if #have == 0 then return false end
  local sum = 0; for _, f in ipairs(hf) do sum = sum + f end
  for i = 1, #hf do hf[i] = hf[i] / sum end
  model.zoom, model.zoomv, model.zoomfr = nil, have, hf
  return bump(model)
end
-- 22 окт: лист панели id (весь стек, со всеми вкладками) — полосой во всю ширину окна снизу (share — доля
-- высоты); соседи по бокам поднимаются и занимают его место (zx в DSP). Возврат — сохранённой строкой (encode)
function PN.span_bottom(model, id, share)
  local lf = PN.find(model, id)
  if not lf or id == 'tracker' then return false end
  if model.root == lf then return false end
  local copy = { panes = {}, active = lf.active, min = lf.min }
  for i, pid in ipairs(lf.panes) do copy.panes[i] = pid end
  lf.panes = {}
  model.root = node('v', { 1 - (share or 0.3), share or 0.3 }, model.root, copy)
  PN.normalize(model)
  return bump(model)
end

-- 22 окт: полоса span_bottom на месте? — корень v, последний ребёнок — лист с id (его панели — вкладки полосы)
function PN.spanned_bottom(model, id)
  local r = model.root
  if not r or is_leaf(r) or r.ax ~= 'v' then return nil end
  local lf = r.kids[#r.kids]
  if not is_leaf(lf) then return nil end
  for _, pid in ipairs(lf.panes) do if pid == id then return lf end end
  return nil
end
-- 22 окт: обратно без снимка (после перезапуска снимка zx нет, а полоса в сохранённой раскладке осталась):
-- полоса снизу снимается, её вкладки встают на свои места по умолчанию (PANELS side), одним стеком
function PN.unspan_bottom(model, id)
  local lf = PN.spanned_bottom(model, id)
  if not lf then return false end
  local r = model.root
  table.remove(r.kids, #r.kids); table.remove(r.fr, #r.fr)
  PN.normalize(model)   -- корень с одним ребёнком складывается; панели полосы помечены hidden
  local first
  for _, pid in ipairs(lf.panes) do
    if first then PN.stack(model, pid, first)
    elseif PN.show(model, pid) then first = pid end
  end
  if first then PN.set_active(model, id) end
  return bump(model)
end

-- имя → id: id, подпись или буква режима PANE
function PN.parse_name(s)
  s = (s or ''):lower()
  if PN.BY[s] then return s end
  for _, p in ipairs(PN.PANELS) do if p.label == s then return p.id end end
  if s == 'lib' then return 'inst' elseif s == 'main' then return 'ctrl' elseif s == 'fx' or s == 'fxlist' then return 'fxb'
  elseif s == 'rec' then return 'retro' elseif s == 'item' then return 'sample' elseif s == 'auto' then return 'automation' elseif s == 'mod' then return 'modulation'
  elseif s == 'harmonizer' then return 'harm' elseif s == 'orca' then return 'garden' end
  return nil
end

-- ── текст ─────────────────────────────────────────────────────────────────
-- h[.14:matrix|.68:v[…|tracker|…]|…] H:notes,video Z:dsp — без ; табов и
-- переводов (тип s: скринсетов)
local function fmt(f) return (('%.3f'):format(f):gsub('0+$', ''):gsub('%.$', '')) end
local function enc(n)
  if is_leaf(n) then
    local t = {}
    for i, id in ipairs(n.panes) do t[i] = id .. (i == n.active and '*' or '') end
    return table.concat(t, ',') .. (n.min and '~' or '')   -- 20 окт: ~ — свёрнут (zm)
  end
  local t = {}
  for i, k in ipairs(n.kids) do t[i] = fmt(n.fr[i]) .. ':' .. enc(k) end
  return n.ax .. '[' .. table.concat(t, '|') .. ']'
end
function PN.encode(model)
  local h = {}
  for _, p in ipairs(PN.PANELS) do if model.hidden[p.id] then h[#h + 1] = p.id end end
  return enc(model.root) .. ' H:' .. table.concat(h, ',') .. ' Z:' .. (model.zoom or '')
end

-- разбор: рекурсивный спуск; любая ошибка → nil
local function dec(s, pos)
  local ax = s:sub(pos, pos)
  if (ax == 'h' or ax == 'v') and s:sub(pos + 1, pos + 1) == '[' then
    local n = { ax = ax, kids = {}, fr = {} }
    pos = pos + 2
    while true do
      local f, p2 = s:match('^([%d%.]+):()', pos)
      if not f then return nil end
      local kid, p3 = dec(s, p2)
      if not kid then return nil end
      n.kids[#n.kids + 1], n.fr[#n.fr + 1] = kid, tonumber(f) or 1
      pos = p3
      local c = s:sub(pos, pos)
      if c == '|' then pos = pos + 1 elseif c == ']' then return n, pos + 1 else return nil end
    end
  end
  local body, p2 = s:match('^([%w_%*,]+~?)()', pos)
  if not body then return nil end
  local lf = { panes = {}, active = 1 }
  if body:sub(-1) == '~' then lf.min = true; body = body:sub(1, -2) end
  for tok in body:gmatch('[^,]+') do
    local id, star = tok:match('^(%w+)(%*?)$')
    if not id then return nil end
    lf.panes[#lf.panes + 1] = id
    if star == '*' then lf.active = #lf.panes end
  end
  return lf, p2
end
function PN.decode(s)
  if type(s) ~= 'string' or s == '' then return PN.DEFAULT() end
  local tree, rest = s:match('^(%S+)%s*(.*)$')
  local root = tree and dec(tree, 1)
  if not root then return PN.DEFAULT() end
  local model = { v = 1, root = root, hidden = {} }
  local z = rest:match('Z:(%w+)')
  if z and z ~= '' then model.zoom = z end
  local ok, m = pcall(PN.normalize, model)
  if not ok or not m or not PN.find(m, 'tracker') then return PN.DEFAULT() end
  return m
end

-- ── пресеты (tmux next-layout) ────────────────────────────────────────────
local function all_tabs() local t = leaf(table.unpack(PN.TABS)); return t end
PN.LAYOUTS = { 'main-left', 'main-right', 'wide', 'widetracker', 'stack', 'tracker' }
local BUILD = {
  ['main-left'] = PN.DEFAULT,
  ['main-right'] = function()
    local m = PN.DEFAULT()
    local r = m.root
    r.kids[1], r.kids[3] = r.kids[3], r.kids[1]
    r.fr[1], r.fr[3] = r.fr[3], r.fr[1]
    return m
  end,
  wide = function()
    return PN.normalize({ v = 1, root = node('v', { 0.24, 0.56, 0.20 },
      node('h', { 0.2, 0.55, 0.25 }, leaf('matrix'), all_tabs(), leaf('inst')),
      leaf('tracker'),
      node('h', { 0.2, 0.15, 0.4, 0.25 }, leaf('ctrl'), leaf('fxb'), leaf('dsp'), leaf('browser'))), hidden = {} })
  end,
  -- 27 окт: трекер во всю ширину сверху, под ним микшер во всю ширину; снизу три стека вкладок — слева модули песни,
  -- в центре dsp и его соседи, справа lib и browser (баг «трекер уехал наверх» стал раскладкой)
  widetracker = function()
    return PN.normalize({ v = 1, root = node('v', { 0.5, 0.14, 0.36 },
      leaf('tracker'), leaf('mixer'),
      node('h', { 0.18, 0.64, 0.18 },
        leaf('matrix', 'patterns', 'ctrl', 'notes', 'visor', 'renderer', 'harm', 'humanizer', 'reform'),
        leaf('dsp', 'automation', 'sample', 'macros', 'midi', 'nmod', 'retro', 'sprops'),
        leaf('inst', 'tracks', 'slices', 'browser', 'clipboard', 'fxb', 'help', 'undotree'))), hidden = {} })
  end,
  stack = function()
    local st = leaf('matrix', 'inst', 'browser', 'ctrl', 'dsp', 'fxb', 'notes', 'slices', table.unpack(PN.TABS))
    return PN.normalize({ v = 1, root = node('h', { 0.75, 0.25 }, leaf('tracker'), st), hidden = {} })
  end,
  tracker = function() return PN.normalize({ v = 1, root = leaf('tracker'), hidden = {} }) end,
}
-- пресет с теми же скрытыми панелями, что в cur (кроме 'tracker' — там
-- скрыто всё)
function PN.preset(name, cur)
  local b = BUILD[name]
  if not b then return nil end
  local m = b()
  if cur and name ~= 'tracker' then for id in pairs(cur.hidden or {}) do PN.hide(m, id) end end
  m.v = (cur and cur.v or 0) + 1
  return m
end
function PN.next_preset(cur_name)
  for i, n in ipairs(PN.LAYOUTS) do if n == cur_name then return PN.LAYOUTS[i % #PN.LAYOUTS + 1] end end
  return PN.LAYOUTS[1]
end


-- 28 окт: описание модуля для панели hints (\ h): что это, как с ним работать — коротко. Модуль может отдать живое
-- описание сам: ctx.about_fn[id] = function() return 'текст' end (API модулей; иначе — строка отсюда)
PN.ABOUT = {
  tracker = 'The song as rows and columns over real REAPER items: note, instrument, volume, delay and command fields per track, envelope and MIDI lanes beside them. NORMAL moves and edits with Vim keys (h j k l, w b, d y p, counts), INSERT types notes from the keyboard, VISUAL selects a block. Every edit is one REAPER undo step.',
  patterns = 'The pattern codes of the song as a grid of cubes: a letter is a family (A, B, C ...), a number its variant (A1, A2 ...). Bright - in the song, grey - not made yet, green - playing, xN - how many times it repeats. Click or Enter jumps there; Shift / v selects several to glue, split, copy, rename or remove. The chain row under the grid is the song order as text, edited with Vim keys (h l w b, x dw dd, y p P), Space plays it, C types it.',
  matrix = 'The song as slots: one row per pattern (region), columns are the tracks. Shows =START and =END, sections on the left, the length and signature of each pattern; a free bar after the song makes a new pattern. Wheel on =START / =END moves them a bar (what is after =END moves along). Enter on a cell lists the patterns that sound on that track.',
  browser = 'Files on disk with preview: folders on the left (like lf), the list in the middle, the wave on the right. j k move, l / Enter go in or put the file into the lib, h back, / search, m marks files for a playlist or a lib folder. Tabs: files, zoxide (your most used folders + what you heard), db, pm projects, proj sources, libs, presets.',
  map = 'Every sound file of the browser folder as a map: graph, cards or a galaxy, grouped by name and ordered dark to bright. Click or Space plays, double click marks, x random. Filters bottom left (no quiet, no long, no loops ...), history and marked files on the right; marked files go to the lib or a lib folder.',
  inst = 'The lib: the instruments of the cursor track (samples, synths, slices, kits). The number is what the instrument field of a note means; Enter / click selects it for typing, the slicer and properties follow. Audio, instruments, automation and MIDI clips are separate groups.',
  ctrl = 'The main module: quick on / off of the tracker parts (dsp, browser, matrix, envelopes, scopes, wave, meters ...), help, notes, tutorial, options and screensets. Each button shows its key in the status line.',
  slices = 'The slices of the selected sample: a row per slice with its key, start and length; the wave above with the slice edges. Click hears a slice, keys play them in order (1 F1 2 ...).',
  sprops = 'Properties of the selected item / instrument: pitch, rate, volume, pan, fades, stretch, beatsync, take FX. J K row, H L value, R resets.',
  nmod = 'Note mod: per-note modulation curves of the cursor instrument (pitch, volume, filter ...), drawn once and replayed by every note.',
  mixer = 'Faders under the tracker, one per track: volume, pan, mute / solo / arm, sends; the master on the right. Drag or wheel a fader, double click resets.',
  tracks = 'Every REAPER track in a list, like the Track Manager: show / hide in the tracker, mute, solo, arm, colour, folders.',
  clipboard = 'The yank history: everything copied with y / yy. Pick an older entry to paste it with p.',
  undotree = 'The undo history as a tree: every edit a node, branches when you undo and do something else. Enter goes back to that state.',
  perf = 'Where the time goes: each part of the frame in ms (rows, headers, DSP, panes ...), the garbage made per frame. For finding slow spots.',
  actions = 'Every REAPER action, searchable (fuzzy): type, Enter runs it in the main section or the last MIDI editor; recent ones on top.',
  reform = 'Reform the selected notes: shape their timing, velocity and length with curves (stretch, gravity, bounce, tuplets ...) and see the result before applying.',
  arranger = 'The order of the song in one place: the seq (patterns as text: A1 A1 B1x2 …), a scheme of the whole song, the sections row and the song playlist made of them, the arrangements (named sets of the lanes that play).',
  phrases = 'The phrases of the project: a piece of a track saved as one note. Enter puts it at the cursor (the note transposes it, velocity scales it), e edits its source - every instance follows.',
  lfogen = 'The curve generator: an LFO, a podkat (a ramp before every note) or an audio follower written into the envelope at the tracker cursor - as points or as an automation item.',
  humanizer = 'Small random timing, velocity, length, pitch and pan for inserted notes (insert on) or the selection; each part with its own range.',
  renderer = 'The bouncer: render notes or a pattern of an instrument to audio and put it back as a sample in the lib.',
  help = 'The keys of the module you came from, as a list: the last used ones on top, the pressed key lights up. \\ ? opens the whole help.',
  console = 'A live pattern language (Strudel mini-notation) inside the tracker: a line t2: n("c [e g] <a b>").fast(2) writes its notes into the pattern at the cursor on track 2 (no tN: - the cursor track); Enter evaluates the line again and rewrites that track in the pattern. s("1 3 ~ 5") - slices, .vel("1 0.5"), .cmd("0R42") - tracker commands, .i(3) - instrument; t2: ~ or hush - clear. Enter line, Cmd+Enter all, Shift+Enter new line, Up / Down history, Esc back.',
  manual = 'The whole manual of jf_tracker: sections on the left, / searches everything, j k lines, J K sections, o opens it in the browser, Esc back to the tracker.',
  hints = 'This pane: what the module under the mouse (or in focus) is and how to use it.',
  notes = 'Text notes of the project, kept in the project file.',
  fxb = 'All installed effects and instruments: a tree of groups (favourites, recent, types, categories, developers) and the list. / searches plugins and their presets, Enter adds to the cursor track, drag onto DSP inserts there (upper half serial, lower parallel), * favourite, x excludes from the search.',
  pm = 'Project cards of jf_pm: your REAPER projects with status, tempo and date; open one or take tracks / regions from it.',
  dsp = 'The FX chain of the cursor track as blocks: meters in / out, gain compensation, delta solo per effect, presets, pictures for the stock plugins. Containers are racks between [ ], parallel branches have a colour line. h l block, j k parameter, + - value, dd delete, cc pack into a container, c= c| parallel / serial, zf fold.',
  retro = 'The retro sampler: what you played recently is kept; take the last seconds as a sample after the fact.',
  sample = 'The item tab: the wave of the item under the cursor with slices, start / end, zoom and the edge aim; s slices it, the slice keys play.',
  automation = 'Automation of the cursor track over time: envelopes as curves, points and automation items; draw, move and shape them.',
  modulation = 'Modulation of FX parameters: LFOs and links of the cursor track, shown with their curves.',
  midi = 'MIDI of the cursor track: CC, pitch bend and program changes as lanes.',
  harm = 'The harmonizer: the key of the song, its chords by degree (click writes one), what chord sounds now, staff and tab views, progressions and just intonation.',
  macros = 'Macros: recorded (q), saved and built-in; play one at the cursor, give it a key, edit its body.',
  scopes = 'Scopes of the tracks: oscilloscope, spectrum or spectrogram per track (JSFX bridge).',
  master = 'The master track: its chain, meters and loudness.',
  video = 'Video of the project in a tab.',
  visor = 'ReaVisor shaders driven by the tracker.',
  grid = 'monome grid / arc: the grid as tracks, the arc rings follow the DSP.',
}
function PN.about(id, ctx)
  local fn = ctx and ctx.about_fn and ctx.about_fn[id]
  if fn then local ok, t = pcall(fn); if ok and t then return t end end
  return PN.ABOUT[id]
end

return PN
