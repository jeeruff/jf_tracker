-- jf_tracker_undotree.lua — дерево undo (15 окт), как undotree в Vim. Без reaper.* — тест tests/test_undotree.lua.
--
-- Ствол — родной undo REAPER: узел = шаг undo (подпись), live = он на стеке REAPER (туда можно
-- дойти родными undo / redo). Откатился и сделал новую правку — ветка: прежние узлы ниже точки
-- ветвления теряют live, до них — только по снимку (snap — где он в файле; снимок снимается, когда
-- узел покидают через undo). Файл рядом с проектом «Имя.jf-undo»: строки событий дописываются в
-- конец (N узел, C текущий, D узел вне стека, S снимок) — дерево читается повтором событий.

local UT = {}

function UT.new()
  return { nodes = { [0] = { id = 0, label = 'original', kids = {}, live = true, seq = 0, t = 0 } }, cur = 0, seq = 0 }
end

-- новая правка на месте cur: если у cur уже есть живой ребёнок — это ветвление, вся живая линия
-- ниже cur умирает (REAPER её отбросил). → id, список умерших узлов
function UT.add(T, label, t, id)
  local p = T.nodes[T.cur]
  local dead = {}
  local function kill(n)
    for _, k in ipairs(n.kids) do
      local c = T.nodes[k]
      if c.live then c.live = false; dead[#dead + 1] = c.id; kill(c) end
    end
  end
  kill(p)
  T.seq = T.seq + 1
  id = id or T.seq
  if id > T.seq then T.seq = id end
  local n = { id = id, parent = p.id, label = label or '?', kids = {}, live = true, seq = T.seq, t = t or 0 }
  T.nodes[id] = n
  p.kids[#p.kids + 1] = id
  p.last = id
  T.cur = id
  return id, dead
end

-- живой ребёнок (по нему идёт родной redo)
function UT.live_kid(T, id)
  local n = T.nodes[id]
  for i = #n.kids, 1, -1 do local c = T.nodes[n.kids[i]]; if c.live then return c.id end end
end

function UT.undo(T)
  local n = T.nodes[T.cur]
  if n.parent == nil then return false end
  T.nodes[n.parent].last = n.id
  T.cur = n.parent
  return true
end
function UT.redo(T)
  local k = UT.live_kid(T, T.cur)
  if not k then return false end
  T.cur = k
  return true
end

-- путь к узлу: { undo = n, redo = { id… } } родными шагами (цель живая), иначе { restore = id }
function UT.plan(T, target)
  local tn = T.nodes[target]
  if not tn then return nil end
  if target == T.cur then return { undo = 0, redo = {} } end
  if not tn.live then return { restore = target } end
  -- общий предок: подняться от cur, пока не встретим предка цели
  local anc = {}
  local a = tn
  while a do anc[a.id] = true; a = a.parent ~= nil and T.nodes[a.parent] or nil end
  local up, c = 0, T.nodes[T.cur]
  while c and not anc[c.id] do up = up + 1; c = c.parent ~= nil and T.nodes[c.parent] or nil end
  if not c then return { restore = target } end
  local down = {}
  local d = tn
  while d.id ~= c.id do table.insert(down, 1, d.id); d = T.nodes[d.parent] end
  -- вниз — только по живой линии (родной redo идёт по ней)
  local at = c.id
  for _, id in ipairs(down) do
    if UT.live_kid(T, at) ~= id then return { restore = target } end
    at = id
  end
  return { undo = up, redo = down }
end

-- раскладка для панели (как Vim undotree): строки новые сверху, у каждого узла колонка ветки;
-- первый ребёнок продолжает колонку родителя, следующие — новые колонки справа
function UT.layout(T)
  -- 17 окт: кэш — дерево меняет только UT.add (seq растёт); раньше сортировка всех узлов шла каждый кадр
  if T._lay and T._lay_seq == T.seq then return T._lay, T._lay_maxc end
  local ids = {}
  for id in pairs(T.nodes) do ids[#ids + 1] = id end
  table.sort(ids, function(a, b) return T.nodes[a].seq < T.nodes[b].seq end)
  local col, maxc = { [0] = 0 }, 0
  for _, id in ipairs(ids) do
    local n = T.nodes[id]
    if n.parent ~= nil then
      local p = T.nodes[n.parent]
      if p.kids[1] == id then col[id] = col[p.id] else maxc = maxc + 1; col[id] = maxc end
    end
  end
  local rows = {}
  for i = #ids, 1, -1 do local id = ids[i]; rows[#rows + 1] = { id = id, col = col[id], node = T.nodes[id] } end
  T._lay, T._lay_seq, T._lay_maxc = rows, T.seq, maxc
  return rows, maxc
end

-- 16 окт: большой вид (zz) — шкала времени: границы по узлам с временем, шаг меток «круглый»,
-- чтобы подписи не налезали (maxn — сколько подписей помещается)
function UT.span(T)
  local t0, t1
  for _, n in pairs(T.nodes) do
    local t = n.t or 0
    if t > 0 then t0 = (not t0 or t < t0) and t or t0; t1 = (not t1 or t > t1) and t or t1 end
  end
  return t0, t1
end
local STEPS = { 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 10800, 21600, 43200, 86400, 172800, 604800 }
function UT.ticks(t0, t1, maxn)
  if not (t0 and t1) or t1 <= t0 or (maxn or 0) < 1 then return {}, nil end
  local step = STEPS[#STEPS]
  for _, s in ipairs(STEPS) do if (t1 - t0) / s <= maxn then step = s; break end end
  local out = {}
  local t = math.ceil(t0 / step) * step
  while t <= t1 and #out < 200 do out[#out + 1] = t; t = t + step end
  return out, step
end
-- интервал от прошлого шага: +12s / +5m / +2h / +3d
function UT.delta(dt)
  dt = math.floor(dt or 0)
  if dt < 1 then return '' end
  if dt < 60 then return '+' .. dt .. 's' end
  if dt < 3600 then return '+' .. math.floor(dt / 60) .. 'm' end
  if dt < 86400 then return '+' .. math.floor(dt / 3600) .. 'h' end
  return '+' .. math.floor(dt / 86400) .. 'd'
end

-- ── файл событий ──────────────────────────────────────────────────────────
local function esc(s) return (tostring(s or ''):gsub('[\n\r\t]', ' ')) end
function UT.ev_node(n) return ('N\t%d\t%d\t%d\t%s\n'):format(n.id, n.parent or -1, math.floor(n.t or 0), esc(n.label)) end
function UT.ev_cur(id) return ('C\t%d\n'):format(id) end
function UT.ev_dead(id) return ('D\t%d\n'):format(id) end
-- снимок: заголовок с длиной, затем ровно len байт данных
function UT.ev_snap(id, data) return ('S\t%d\t%d\n'):format(id, #data) .. data .. '\n' end

-- повтор событий → дерево; снимки — { [id] = данные } (последний на узел)
function UT.load(text)
  local T = UT.new()
  local snaps = {}
  local i, n = 1, #(text or '')
  while i <= n do
    local e = text:find('\n', i, true) or (n + 1)
    local line = text:sub(i, e - 1)
    i = e + 1
    local tag = line:sub(1, 1)
    if tag == 'N' then
      local id, par, t, label = line:match('^N\t(%-?%d+)\t(%-?%d+)\t(%-?%d+)\t(.*)$')
      id, par = tonumber(id), tonumber(par)
      if id and T.nodes[par] and not T.nodes[id] then T.cur = par; UT.add(T, label, tonumber(t), id) end
    elseif tag == 'C' then
      local id = tonumber(line:match('^C\t(%-?%d+)'))
      if id and T.nodes[id] then T.cur = id end
    elseif tag == 'D' then
      local id = tonumber(line:match('^D\t(%-?%d+)'))
      if id and T.nodes[id] then T.nodes[id].live = false end
    elseif tag == 'S' then
      local id, len = line:match('^S\t(%-?%d+)\t(%d+)')
      id, len = tonumber(id), tonumber(len)
      if id and len then snaps[id] = text:sub(i, i + len - 1); i = i + len + 1 end
    end
  end
  for id in pairs(snaps) do if T.nodes[id] then T.nodes[id].snap = true end end
  return T, snaps
end

-- ── снимок: блоки «тег длина\nданные\n» (chunk-и треков, маркеры, темп) ──
function UT.pack(parts)
  local out = {}
  for _, p in ipairs(parts) do out[#out + 1] = ('%s\t%d\n'):format(p[1], #p[2]) .. p[2] .. '\n' end
  return table.concat(out)
end
function UT.unpack(data)
  local parts, i, n = {}, 1, #(data or '')
  while i <= n do
    local e = data:find('\n', i, true)
    if not e then break end
    local tag, len = data:sub(i, e - 1):match('^(.-)\t(%d+)$')
    len = tonumber(len)
    if not len then break end
    parts[#parts + 1] = { tag, data:sub(e + 1, e + len) }
    i = e + len + 2
  end
  return parts
end


-- ── сессия: дерево проекта поверх истории REAPER ──────────────────────────
-- api: undo_desc() redo_desc() count() do_undo() do_redo() capture() restore(data, label)
--      read(path) → текст | nil, append(path, s), now()
-- Без reaper.* — main даёт api, тест — имитацию стека undo.
function UT.session(api, path)
  local S = { buf = {}, api = api }
  local txt = path and api.read(path)
  if txt then
    S.T, S.snaps = UT.load(txt)
    for id, n in pairs(S.T.nodes) do n.live = (id == S.T.cur) end   -- после открытия стека REAPER у старых узлов нет
    S.path, S.flushed = path, true
  else
    S.T, S.snaps = UT.new(), {}
    local u = api.undo_desc()
    if u ~= '' then S.T.nodes[0].label = u end
  end
  S.path = path
  S.flushed = path ~= nil                    -- проект сохранён — сразу в файл (создастся при первой записи)
  UT.sync(S)
  S.sel = S.T.cur
  return S
end
function UT.sync(S) S.u0, S.r0, S.cc0 = S.api.undo_desc(), S.api.redo_desc(), S.api.count() end
-- путь к файлу появился (проект сохранили) — накопленное туда
function UT.set_path(S, path)
  if path and not S.flushed then
    S.api.append(path, table.concat(S.buf)); S.buf = {}; S.flushed = true
  end
  S.path = path or S.path
end
function UT.write(S, s)
  if S.flushed and S.path then S.api.append(S.path, s) else S.buf[#S.buf + 1] = s end
end
function UT.snap(S, id)
  if S.snaps[id] or not S.T.nodes[id] then return end
  local data = S.api.capture()
  if not data then return end
  S.snaps[id] = data; S.T.nodes[id].snap = true
  UT.write(S, UT.ev_snap(id, data))
end
function UT.edit(S, label)
  local id, dead = UT.add(S.T, label, S.api.now())
  UT.write(S, UT.ev_node(S.T.nodes[id]))
  for _, d in ipairs(dead) do UT.write(S, UT.ev_dead(d)) end
  S.sel = id
  return id
end
-- каждый кадр: что было — откат, повтор или новая правка (по подписям undo REAPER)
function UT.poll(S)
  local api, T = S.api, S.T
  local cc = api.count()
  if cc == S.cc0 then return end
  local u, r = api.undo_desc(), api.redo_desc()
  if u == S.u0 and r == S.r0 then S.cc0 = cc; return end
  if r ~= '' and r == S.u0 then
    -- откат мимо трекера: снимок покинутого узла — шаг вперёд и обратно
    if not S.snaps[T.cur] and not S.in_nav then api.do_redo(); UT.snap(S, T.cur); api.do_undo() end
    if UT.undo(T) then UT.write(S, UT.ev_cur(T.cur)) end
  elseif S.r0 ~= '' and u == S.r0 then
    if UT.redo(T) then UT.write(S, UT.ev_cur(T.cur)) end
  elseif u ~= '' then
    UT.edit(S, u)
  end
  S.sel = T.cur
  UT.sync(S)
end
-- правка трекера (после Undo_EndBlock): узел по подписи — и одинаковые подряд
function UT.hook(S, label)
  if S.api.count() == S.cc0 or S.api.undo_desc() ~= label then return end   -- шага undo не было (ничего не изменилось)
  UT.edit(S, label); UT.sync(S)
end
-- перед откатом трекером: снимок узла, который покидаем
function UT.before_undo(S) UT.poll(S); UT.snap(S, S.T.cur) end
-- к узлу. undo / redo — функции трекера (они зовут before_undo). → текст для статуса
function UT.go(S, id, undo, redo)
  UT.poll(S)
  local T = S.T
  local p = UT.plan(T, id)
  if not p then return nil end
  local lab = (T.nodes[id].label or ''):gsub('^jf_tracker: ', '')
  if p.restore then
    local data = S.snaps[id]
    if not data then return 'undo tree: no snapshot of this branch (it was left before the tree started)' end
    S.api.restore(data, 'jf_tracker: undotree to ' .. lab)
    UT.poll(S)
    return 'undo tree: restored "' .. lab .. '" (u - back)'
  end
  S.in_nav = true
  for _ = 1, p.undo do undo(); UT.poll(S) end
  for _ = 1, #p.redo do redo(); UT.poll(S) end
  S.in_nav = nil
  return T.cur == id and ('undo tree: at "' .. lab .. '"') or 'undo tree: REAPER history went another way - the tree follows it from here'
end

return UT
