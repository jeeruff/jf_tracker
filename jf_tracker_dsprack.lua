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

return RK
