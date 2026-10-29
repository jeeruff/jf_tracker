-- jf_tracker_dsprack.lua — геометрия цепочки DSP без reaper / gfx (28 окт; тест tests/test_dsprack.lua).
-- RK.route_layout — раскладка мини-роутера шапки трека: узлы цепочки маленькими прямоугольниками.
--   nodes: { { k, name, par (0 / 1 — параллельно предыдущему), cont (контейнер), ncend (сколько контейнеров
--   закрывается после узла) }, … }
--   o: { x, y, w, h (область), nw, nh (узел), gx (зазор столбцов), bw (место под скобку), rgap (между рядами) }
-- → boxes { { n, x, y, w, h } }, links { { x1, x2, y } } (черта между столбцами), br { { x, y, h, right } },
--   cut (узлы не влезли по высоте)
local RK = {}

function RK.route_layout(nodes, o)
  local boxes, links, br = {}, {}, {}
  local nw, nh, gx, bw = o.nw, o.nh, o.gx, o.bw
  local rgap = o.rgap or 2
  local x1, y1 = o.x + o.w, o.y + o.h
  local cx, row, band_y, band_h = o.x, 0, o.y, 1
  local prev_x
  local cut = false
  for _, n in ipairs(nodes) do
    local newcol = not ((n.par or 0) > 0 and prev_x)
    if newcol then
      local need = nw + (n.cont and bw or 0)
      if prev_x and cx + need > x1 then   -- не влезло — полоса ниже
        band_y = band_y + band_h * (nh + rgap) + gx; band_h = 1; cx = o.x; prev_x = nil
      end
      if prev_x then links[#links + 1] = { x1 = prev_x + nw, x2 = cx + (n.cont and bw or 0), y = band_y + math.floor(nh / 2) } end
      row = 0
    else row = row + 1; band_h = math.max(band_h, row + 1) end
    local ny = band_y + row * (nh + rgap)
    if ny + nh > y1 then cut = true; break end
    local nx = newcol and cx or prev_x
    if newcol and n.cont then br[#br + 1] = { x = nx, y = ny, h = nh, right = false }; nx = nx + bw end
    boxes[#boxes + 1] = { n = n, x = nx, y = ny, w = nw, h = nh }
    if newcol then prev_x = nx; cx = nx + nw + gx end
    for _ = 1, n.ncend or 0 do
      br[#br + 1] = { x = prev_x + nw + 1, y = band_y, h = nh, right = true }
      cx = cx + bw
    end
  end
  return boxes, links, br, cut
end

-- 29 окт: вертикальный вид — последовательно вниз (строка на модуль), параллельно предыдущему — правее в той же строке;
-- глубина вложения (контейнеры) — отступом. links: { v = true, x, y1, y2 } — вертикальная черта между строками
function RK.route_layout_v(nodes, o)
  local boxes, links, br = {}, {}, {}
  local nw, nh, gx = o.nw, o.nh, o.gx
  local rgap = o.rgap or 2
  local ind = o.ind or math.max(4, o.bw or 4) * 2
  local y1 = o.y + o.h
  local ry = o.y - (nh + rgap)
  local prev, cut = nil, false
  for _, n in ipairs(nodes) do
    local par = (n.par or 0) > 0 and prev
    local bx, by
    if par then bx, by = prev.x + nw + gx, prev.y
    else
      ry = ry + nh + rgap
      bx, by = o.x + (n.depth or 0) * ind, ry
      if prev and by + nh <= y1 then links[#links + 1] = { v = true, x = o.x + (n.depth or 0) * ind + 3, y1 = prev.y + nh, y2 = by } end
    end
    if by + nh > y1 then cut = true; break end
    if bx + nw > o.x + o.w then bx = math.max(o.x, o.x + o.w - nw) end
    local b = { n = n, x = bx, y = by, w = nw, h = nh }
    boxes[#boxes + 1] = b
    if n.cont then br[#br + 1] = { x = bx - 3, y = by, h = nh, right = false } end
    if not par then prev = b else prev = { x = bx, y = by } end
  end
  return boxes, links, br, cut
end
-- 28 окт: блок <FXCHAIN … > чанка трека (слоты цепей) → текст, начало, конец (включительно); нет — nil
function RK.fxchain(chunk)
  local a = chunk:find('\n<FXCHAIN')
  if not a then return nil end
  a = a + 1
  local depth, pos = 0, a
  while pos <= #chunk do
    local e = chunk:find('\n', pos, true) or #chunk
    local t = chunk:sub(pos, e):match('^%s*(.-)%s*$')
    if t:sub(1, 1) == '<' then depth = depth + 1 elseif t == '>' then depth = depth - 1 end
    if depth == 0 then return chunk:sub(a, e), a, e end
    pos = e + 1
  end
  return nil
end

-- 28 окт: подпись узла роутера — первые 3 согласные имени (slixer → slx, Container → Cnt, VST: ReaEQ → RQ);
-- согласных меньше двух — начало имени как есть
function RK.abbrev(name, n)
  n = n or 3
  local s = (name or '?'):gsub('^[%s|=]+', ''):gsub('^%w+i?:%s*', ''):gsub('%s*%(.*$', '')
  local out = {}
  for ch in s:gmatch('%a') do
    if not ch:lower():match('[aeiouy]') then out[#out + 1] = ch end
    if #out >= n then break end
  end
  if #out < 2 then return s:sub(1, n) end
  return table.concat(out)
end

return RK
