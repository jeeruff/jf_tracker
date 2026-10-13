-- jf_tracker_tracks.lua — дерево треков для модуля tracks (13 окт, как файловый менеджер lf).
-- Чистая модель без reaper.*: проект — список { id, d } (d — глубина вложенности, 0 — верх),
-- папка — трек, за которым идёт трек глубже. Операции возвращают новый список; применяет его
-- главный модуль (порядок — ReorderSelectedTracks, папки — I_FOLDERDEPTH из T.folderdepths).
-- Тест: lua tests/test_tracks.lua
local T = {}

-- I_FOLDERDEPTH каждого трека → глубины (REAPER: 1 — папка, -n — закрывает n уровней)
function T.depths(fd)
  local out, d = {}, 0
  for i, v in ipairs(fd) do
    out[i] = d
    d = math.max(0, d + (v > 0 and 1 or v))
  end
  return out
end

-- глубины → I_FOLDERDEPTH (следующий глубже — папка, мельче — закрыть разницу)
function T.folderdepths(list)
  local out = {}
  for i, e in ipairs(list) do
    local nd = list[i + 1] and list[i + 1].d or 0
    out[i] = nd > e.d and 1 or (nd - e.d)
  end
  return out
end

-- приведение: первый на 0, никто не глубже предыдущего + 1
function T.norm(list)
  local prev = -1
  for _, e in ipairs(list) do
    if e.d > prev + 1 then e.d = prev + 1 end
    if e.d < 0 then e.d = 0 end
    prev = e.d
  end
  return list
end

-- блок трека i: он и все дети → i, j
function T.block(list, i)
  local d, j = list[i].d, i
  while list[j + 1] and list[j + 1].d > d do j = j + 1 end
  return i, j
end

-- родитель трека i (индекс) или nil
function T.parent(list, i)
  local d = list[i].d
  for k = i - 1, 1, -1 do if list[k].d < d then return k end end
  return nil
end

-- предыдущий / следующий брат (тот же родитель)
function T.sibling(list, i, dir)
  local d = list[i].d
  if dir < 0 then
    for k = i - 1, 1, -1 do
      if list[k].d < d then return nil end
      if list[k].d == d then return k end
    end
  else
    local _, j = T.block(list, i)
    local k = j + 1
    if list[k] and list[k].d == d then return k end
  end
  return nil
end

function T.is_folder(list, i) return list[i + 1] ~= nil and list[i + 1].d > list[i].d end

local function copy(list) local o = {}; for k, e in ipairs(list) do o[k] = { id = e.id, d = e.d } end; return o end
local function index(list, id) for k, e in ipairs(list) do if e.id == id then return k end end end

-- корни выбора: блоки отмеченных треков без тех, что внутри другого отмеченного блока (по порядку)
function T.roots(list, ids)
  local want = {}
  for _, id in ipairs(ids) do want[id] = true end
  local out, skip_to = {}, 0
  for k, e in ipairs(list) do
    if k > skip_to and want[e.id] then
      out[#out + 1] = e.id
      local _, j = T.block(list, k); skip_to = j
    end
  end
  return out
end

-- вынуть блоки ids (корни) → новый список без них, вынутые блоки (глубины от корня 0)
local function take(list, ids)
  local rest, blocks, cut = {}, {}, {}
  for _, id in ipairs(ids) do
    local i = index(list, id)
    if i then local a, b = T.block(list, i); for k = a, b do cut[k] = true end end
  end
  local cur
  for k, e in ipairs(list) do
    if cut[k] then
      if not cur or (e.d <= cur.d0) then cur = { d0 = e.d, items = {} }; blocks[#blocks + 1] = cur end
      cur.items[#cur.items + 1] = { id = e.id, d = e.d - cur.d0 }
    else rest[#rest + 1] = { id = e.id, d = e.d }; cur = nil end
  end
  return rest, blocks
end

-- >> : блоки ids — в предыдущего брата (он становится папкой, блок — его последним ребёнком)
function T.indent(list, ids)
  local out = copy(list)
  local done = 0
  for _, id in ipairs(T.roots(out, ids)) do
    local i = index(out, id)
    if T.sibling(out, i, -1) then
      local a, b = T.block(out, i)
      for k = a, b do out[k].d = out[k].d + 1 end
      done = done + 1
    end
  end
  return out, done
end

-- << : блоки ids — из папки: встают сразу за блоком родителя, на его уровень
function T.outdent(list, ids)
  local out, done = copy(list), 0
  local roots = T.roots(out, ids)
  for r = #roots, 1, -1 do
    local i = index(out, roots[r])
    local p = T.parent(out, i)
    if p then
      local pid = out[p].id
      local rest, blocks = take(out, { roots[r] })
      local pi = index(rest, pid)
      local _, pj = T.block(rest, pi)
      local d0 = rest[pi].d
      for k = #blocks[1].items, 1, -1 do
        local e = blocks[1].items[k]
        table.insert(rest, pj + 1, { id = e.id, d = d0 + e.d })
      end
      out, done = rest, done + 1
    end
  end
  return out, done
end

-- J / K: блоки ids меняются местами с соседним братом (dir 1 — вниз, -1 — вверх)
function T.move(list, ids, dir)
  local out, done = copy(list), 0
  local roots = T.roots(out, ids)
  local a0, a1 = 1, #roots
  if dir > 0 then a0, a1 = #roots, 1 end
  for r = a0, a1, (dir > 0 and -1 or 1) do
    local i = index(out, roots[r])
    local s = T.sibling(out, i, dir)
    if s then
      local x0, x1 = T.block(out, math.min(i, s))
      local y0, y1 = T.block(out, math.max(i, s))
      local o = {}
      for k = 1, x0 - 1 do o[#o + 1] = out[k] end
      for k = y0, y1 do o[#o + 1] = out[k] end
      for k = x0, x1 do o[#o + 1] = out[k] end
      for k = y1 + 1, #out do o[#o + 1] = out[k] end
      out, done = o, done + 1
    end
  end
  return out, done
end

-- вставить блок новых треков items ({ id, d } с глубинами от 0) за блоком at (after) или перед at,
-- на уровень at; at = nil — в конец, на верхний уровень
function T.insert(list, items, at, after)
  local out = copy(list)
  local pos, d0 = #out + 1, 0
  local i = at and index(out, at)
  if i then
    d0 = out[i].d
    if after then local _, j = T.block(out, i); pos = j + 1 else pos = i end
  end
  for k = #items, 1, -1 do table.insert(out, pos, { id = items[k].id, d = d0 + items[k].d }) end
  return T.norm(out)
end

-- папка вокруг блоков ids: новый трек fid встаёт перед первым из них, блоки — его дети (подряд)
function T.wrap(list, ids, fid)
  local roots = T.roots(list, ids)
  if #roots == 0 then return copy(list) end
  local first = index(list, roots[1])
  local d0 = list[first].d
  local anchor = first > 1 and list[first - 1].id or nil
  local rest, blocks = take(list, roots)
  local pos = 1
  if anchor then pos = index(rest, anchor) + 1 end
  local ins = { { id = fid, d = d0 } }
  for _, b in ipairs(blocks) do for _, e in ipairs(b.items) do ins[#ins + 1] = { id = e.id, d = d0 + 1 + e.d } end end
  for k = #ins, 1, -1 do table.insert(rest, pos, ins[k]) end
  return T.norm(rest)
end

return T
