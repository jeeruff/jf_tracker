-- jf_tracker_smap.lua — карта сэмплов папки, как граф Obsidian (27 окт 2026).
-- Узлы — файлы папки и подпапок (до SM.MAX), размер узла — размер файла; категории — узлы-хабы:
-- по словам имени (kick, snare, hat, bass, loop …), без совпадения — по подпапке. Раскладка — силовая
-- (Fruchterman–Reingold): несколько шагов за кадр, пока не остынет. Без анализа звука (этап 2 — признаки).
-- Чистый Lua + gfx; список папки даёт вызывающий (list_dir браузера).
local SM = {}
SM.MAX = 300
SM.ITERS = 3                                   -- шагов раскладки за кадр
local R = reaper

-- категории по словам имени: первое совпадение по порядку
SM.CATS = {
  { 'kick', { 'kick', 'kik', 'bd', 'bassdrum' } },
  { 'snare', { 'snare', 'snr', 'sd', 'rim' } },
  { 'hat', { 'hat', 'hh', 'hihat', 'ohh', 'chh' } },
  { 'clap', { 'clap', 'clp', 'snap' } },
  { 'tom', { 'tom' } },
  { 'cymbal', { 'crash', 'ride', 'cymbal', 'cym', 'china', 'splash' } },
  { 'perc', { 'perc', 'shaker', 'tamb', 'conga', 'bongo', 'cowbell', 'block', 'clave' } },
  { 'bass', { 'bass', '808', 'sub' } },
  { 'loop', { 'loop', 'break', 'beat', 'groove', 'bpm' } },
  { 'fx', { 'fx', 'sfx', 'riser', 'impact', 'sweep', 'noise', 'whoosh', 'hit', 'drop' } },
  { 'vox', { 'vox', 'vocal', 'voice', 'acap', 'chant', 'acapella' } },
  { 'synth', { 'synth', 'lead', 'pad', 'chord', 'stab', 'pluck', 'arp', 'keys', 'piano' } },
}
local CAT_BY = {}
for _, c in ipairs(SM.CATS) do for _, w in ipairs(c[2]) do CAT_BY[w] = c[1] end end

-- слова имени: по не-буквам и по смене регистра (KickHard → kick hard); цифры отдельно
local function tokens(name)
  local base = (name:gsub('%.[%w]+$', ''))
  base = base:gsub('(%l)(%u)', '%1 %2')
  local out = {}
  for t in base:lower():gmatch('[%a]+') do out[#out + 1] = t end
  for t in base:lower():gmatch('%d+') do out[#out + 1] = t end
  return out
end
SM.tokens = tokens
function SM.category(name, sub)
  for _, t in ipairs(tokens(name)) do
    if CAT_BY[t] then return CAT_BY[t] end
    for w, c in pairs(CAT_BY) do if #w >= 3 and t:sub(1, #w) == w then return c end end   -- kick01, snares
  end
  return sub and ('/' .. sub) or 'other'
end

local function file_size(path)
  local f = io.open(path, 'rb')
  if not f then return 0 end
  local n = f:seek('end') or 0
  f:close()
  return n
end

-- граф папки: files { path, name, size, cat }, hubs { name, n }; позиции — в единицах (-1..1)
function SM.build(root, list_dir)
  local G = { root = root, nodes = {}, hubs = {}, edges = {}, t = 0, temp = 0.12 }
  local function walk(path, sub, depth)
    if #G.nodes >= SM.MAX then return end
    for _, e in ipairs(list_dir(path)) do
      if #G.nodes >= SM.MAX then break end
      local p = (path == '/' and '' or path) .. '/' .. e.name
      if e.dir then
        if depth < 3 then walk(p, sub or e.name, depth + 1) end
      else
        G.nodes[#G.nodes + 1] = { path = p, name = e.name, size = file_size(p), cat = SM.category(e.name, sub) }
      end
    end
  end
  walk(root, nil, 0)
  return SM.finish(G)
end
-- 27 окт: граф из готового списка (вкладка proj): files { path, name, sub } — sub — запасная группа (трек)
function SM.from_files(key, files)
  local G = { root = key, nodes = {}, hubs = {}, edges = {}, t = 0, temp = 0.12 }
  for _, f in ipairs(files) do
    if #G.nodes >= SM.MAX then break end
    G.nodes[#G.nodes + 1] = { path = f.path, name = f.name, size = file_size(f.path), cat = SM.category(f.name, f.sub) }
  end
  return SM.finish(G)
end
function SM.finish(G)
  local hubi = {}
  for _, n in ipairs(G.nodes) do
    local h = hubi[n.cat]
    if not h then h = { name = n.cat, n = 0, hub = true }; G.hubs[#G.hubs + 1] = h; hubi[n.cat] = h end
    h.n = h.n + 1
    n.h = h
  end
  -- начальные места: хабы по кругу, файлы — рядом со своим хабом
  local nh = #G.hubs
  for i, h in ipairs(G.hubs) do
    local a = 2 * math.pi * (i - 1) / math.max(1, nh)
    h.x, h.y = 0.6 * math.cos(a), 0.6 * math.sin(a)
  end
  local mx = 1
  for _, n in ipairs(G.nodes) do mx = math.max(mx, n.size) end
  for i, n in ipairs(G.nodes) do
    local a = i * 2.39996                          -- золотой угол: кольцо без наложений
    n.x, n.y = n.h.x + 0.15 * math.cos(a), n.h.y + 0.15 * math.sin(a)
    n.r = 0.25 + 0.75 * math.sqrt(n.size / mx)     -- 0.25..1 — доля наибольшего радиуса
  end
  G.all = {}
  for _, h in ipairs(G.hubs) do G.all[#G.all + 1] = h end
  for _, n in ipairs(G.nodes) do G.all[#G.all + 1] = n end
  return G
end

-- шаг раскладки: отталкивание всех от всех, пружины файл—хаб, тяга к центру; temp — шаг, остывает
function SM.step(G)
  if G.temp < 0.002 then return false end
  local all = G.all
  local n = #all
  local k = 0.9 / math.sqrt(math.max(1, n))
  local k2 = k * k
  for i = 1, n do all[i].dx, all[i].dy = 0, 0 end
  for i = 1, n do
    local a = all[i]
    for j = i + 1, n do
      local b = all[j]
      local dx, dy = a.x - b.x, a.y - b.y
      local d2 = dx * dx + dy * dy + 1e-6
      local f = k2 / d2 * ((a.hub and b.hub) and (2 - 1.5 * (G.grav or 0.5)) or 1)   -- 27 окт: gravity — хабы друг от друга слабее
      a.dx, a.dy = a.dx + dx * f, a.dy + dy * f
      b.dx, b.dy = b.dx - dx * f, b.dy - dy * f
    end
  end
  for _, nd in ipairs(G.nodes) do
    local h = nd.h
    local dx, dy = nd.x - h.x, nd.y - h.y
    local d = math.sqrt(dx * dx + dy * dy) + 1e-6
    local f = d / k * 0.6
    nd.dx, nd.dy = nd.dx - dx / d * f * d, nd.dy - dy / d * f * d
    h.dx, h.dy = h.dx + dx / d * f * d * 0.2, h.dy + dy / d * f * d * 0.2
  end
  for _, a in ipairs(all) do
    local gc = 0.02 + 0.5 * (G.grav or 0.5) ^ 2   -- 27 окт: gravity — тяга к центру (группы не разлетаются)
    a.dx, a.dy = a.dx - a.x * gc, a.dy - a.y * gc
    local d = math.sqrt(a.dx * a.dx + a.dy * a.dy) + 1e-9
    local s = math.min(d, G.temp) / d
    a.x, a.y = a.x + a.dx * s, a.y + a.dy * s
  end
  G.temp = G.temp * 0.97
  return true
end

-- ── 27 окт: вид NEBULA — без связей: группы в ровных квадрантах (сетка), точки летают внутри своего:
-- тянутся к центру, отталкиваются друг от друга, чуть дрейфуют; подпись сектора — как граница туманности в sci-fi
function SM.neb_init(G)
  if G.neb then return end
  G.neb = true
  table.sort(G.hubs, function(a, b) return a.n > b.n end)
  for i, h in ipairs(G.hubs) do h.cell = i; h.mass = 0 end
  for i, n in ipairs(G.nodes) do
    local a = i * 2.39996
    n.qx, n.qy, n.vx, n.vy = 0.5 * math.cos(a) * ((i % 7) / 7), 0.5 * math.sin(a) * ((i % 5) / 5), 0, 0
    n.ph = (i * 0.618) % 1 * 6.283
    n.h.mass = n.h.mass + n.size
  end
end
function SM.neb_step(G, grav)
  local by = {}
  for _, n in ipairs(G.nodes) do local l = by[n.h]; if not l then l = {}; by[n.h] = l end; l[#l + 1] = n end
  local kc = 0.004 + 0.03 * (grav or 0.5)
  for _, l in pairs(by) do
    local rr = 0.9 / math.sqrt(math.max(1, #l))
    for i = 1, #l do
      local a = l[i]
      local fx, fy = -a.qx * kc, -a.qy * kc
      for j = 1, #l do
        if j ~= i then
          local b = l[j]
          local dx, dy = a.qx - b.qx, a.qy - b.qy
          local d2 = dx * dx + dy * dy + 1e-4
          if d2 < rr * rr * 4 then local f = 0.0006 * rr * rr / d2; fx, fy = fx + dx * f, fy + dy * f end
        end
      end
      a.vx, a.vy = (a.vx + fx) * 0.85, (a.vy + fy) * 0.85
      a.qx = math.max(-0.95, math.min(0.95, a.qx + a.vx))
      a.qy = math.max(-0.95, math.min(0.95, a.qy + a.vy))
    end
  end
end
local GREEK = { 'ALPHA', 'BETA', 'GAMMA', 'DELTA', 'EPSILON', 'ZETA', 'ETA', 'THETA', 'IOTA', 'KAPPA', 'LAMBDA', 'MU', 'NU', 'XI', 'OMICRON', 'PI', 'RHO', 'SIGMA', 'TAU', 'UPSILON' }
local function mb(b) return b >= 1048576 and ('%.1f MB'):format(b / 1048576) or ('%d KB'):format(math.floor(b / 1024 + 0.5)) end
function SM.draw_nebula(U, L, G, x, y, w, h, V, playing, fit, col, mx, my, inside)
  SM.neb_init(G)
  SM.neb_step(G, V.grav)
  local nh = #G.hubs
  local cols = math.max(1, math.ceil(math.sqrt(nh * w / math.max(1, h))))
  local rows = math.max(1, math.ceil(nh / cols))
  local top = y + L.rh + 4
  local cw, ch = w / cols, (y + h - top) / rows
  local t = R and R.time_precise and R.time_precise() or os.clock()
  local hv, hd
  local rmax = math.max(2, math.min(7, math.min(cw, ch) * 0.03)) * (0.4 + 1.6 * (V.dim or 0.5))
  for _, hb in ipairs(G.hubs) do
    local i = hb.cell - 1
    local qx0, qy0 = x + (i % cols) * cw, top + math.floor(i / cols) * ch
    local c = col(hb)
    -- граница сектора: уголки и пунктир по краям — тускло
    local bx0, by0, bx1, by1 = math.floor(qx0 + 3), math.floor(qy0 + 3), math.floor(qx0 + cw - 4), math.floor(qy0 + ch - 4)
    U.set(U.mix(c, U.BG, 0.8))
    for px = bx0 + 10, bx1 - 10, 6 do gfx.rect(px, by0, 2, 1, 1); gfx.rect(px, by1, 2, 1, 1) end
    for py = by0 + 10, by1 - 10, 6 do gfx.rect(bx0, py, 1, 2, 1); gfx.rect(bx1, py, 1, 2, 1) end
    U.set(U.mix(c, U.BG, 0.35))
    for _, cn in ipairs({ { bx0, by0, 1, 1 }, { bx1, by0, -1, 1 }, { bx0, by1, 1, -1 }, { bx1, by1, -1, -1 } }) do
      gfx.rect(math.min(cn[1], cn[1] + cn[3] * 8), cn[2], 9, 1, 1); gfx.rect(cn[1], math.min(cn[2], cn[2] + cn[4] * 8), 1, 9, 1)
    end
    local lab = ('NEB-%02d // %s'):format(hb.cell, (hb.name:gsub('^/', '')):upper())
    U.text(bx0 + 6, by0 + 3, fit(lab, bx1 - bx0 - 12), c)
    local sub = ('%s SECTOR  %d BODIES  MASS %s'):format(GREEK[(hb.cell - 1) % #GREEK + 1], hb.n, mb(hb.mass or 0))
    if by1 - by0 > 3 * L.rh then U.text(bx0 + 6, by1 - L.rh - 2, fit(sub, bx1 - bx0 - 12), U.mix(c, U.BG, 0.45)) end
    if inside and mx >= bx0 and mx < bx1 and my >= by0 and my < by0 + L.rh + 3 then hv = { hub = hb } end
    hb.qx0, hb.qy0 = qx0, qy0
  end
  for _, n in ipairs(G.nodes) do
    local hb = n.h
    local i = hb.cell - 1
    local qx0, qy0 = x + (i % cols) * cw, top + math.floor(i / cols) * ch
    local dx, dy = 0.03 * math.sin(t * 0.4 + n.ph), 0.03 * math.cos(t * 0.33 + n.ph * 1.7)   -- дрейф
    local px = qx0 + cw / 2 + (n.qx + dx) * (cw / 2 - 10)
    local py = qy0 + ch / 2 + 6 + (n.qy + dy) * (ch / 2 - 18)
    local r = math.max(1, n.r * rmax)
    local on = playing == n.path
    local c = col(hb)
    U.set(on and U.AMBER or U.mix(c, U.TEXT, 0.15), on and 1 or 0.85); gfx.circle(px, py, r, 1, 1)
    U.set(c, 0.18); gfx.circle(px, py, r + 2, 1, 1)   -- свечение
    gfx.a = 1
    if inside then
      local d = (mx - px) ^ 2 + (my - py) ^ 2
      if d <= (r + 3) ^ 2 and (not hd or d < hd) then hv, hd = { node = n, px = px, py = py, r = r }, d end
    end
  end
  return hv
end

-- рисование в прямоугольнике; V = { zoom, px, py } (вид, общий для вызывающего); playing — путь, что звучит;
-- → hover { node = n } | { hub = h } | nil
local HUE = { kick = 1, snare = 2, hat = 3, clap = 4, tom = 5, cymbal = 6, perc = 7, bass = 8, loop = 9, fx = 10, vox = 11, synth = 12 }
function SM.draw(U, L, G, x, y, w, h, V, playing, fit)
  for _ = 1, SM.ITERS do if not SM.step(G) then break end end
  U.set(U.BG); gfx.rect(x, y, w, h, 1)
  U.set(U.LINE); gfx.rect(x, y, w, h, 0)
  if #G.nodes == 0 then U.text(x + L.pad, y + 2, fit('map: no sound files here', w - 2 * L.pad), U.DIM); return nil end
  -- 27 окт: вписать в прямоугольник по фактическому размаху узлов (раскладка расползается); зум и сдвиг — поверх
  local x0, x1, y0, y1 = math.huge, -math.huge, math.huge, -math.huge
  for _, a in ipairs(G.all) do x0, x1, y0, y1 = math.min(x0, a.x), math.max(x1, a.x), math.min(y0, a.y), math.max(y1, a.y) end
  local ox, oy = (x0 + x1) / 2, (y0 + y1) / 2
  local sc = math.min(0.44 * w / math.max(0.05, (x1 - x0) / 2), 0.44 * h / math.max(0.05, (y1 - y0) / 2)) * (V.zoom or 1)
  local cx, cy = x + w / 2 + (V.px or 0), y + h / 2 + (V.py or 0)
  local function X(n) return cx + (n.x - ox) * sc end
  local function Y(n) return cy + (n.y - oy) * sc end
  local function inr(px, py) return px >= x and px < x + w and py >= y and py < y + h end
  local PAL = { U.AMBER, U.CYAN, U.GREEN, U.RED, U.YELLOW, U.PINK or U.RED }
  local function col(hb)
    local i = HUE[hb.name] or (#hb.name % 6 + 1)
    return PAL[(i - 1) % #PAL + 1]
  end
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local inside = mx >= x and mx < x + w and my >= y and my < y + h
  local hv, hd
  if V.style == 'nebula' then
    hv = SM.draw_nebula(U, L, G, x, y, w, h, V, playing, fit, col, mx, my, inside)
    if hv and hv.node then
      local lab = hv.node.name
      local tw = U.measure(lab) + 2 * L.pad
      local tx = math.min(x + w - tw - 1, math.max(x + 1, hv.px + 8))
      local ty = math.min(y + h - L.rh - 1, math.max(y + 1, hv.py - L.rh - 4))
      U.set(U.PANEL); gfx.rect(tx, ty, tw, L.rh, 1); U.set(U.AMBER); gfx.rect(tx, ty, tw, L.rh, 0)
      U.text(tx + L.pad, ty, lab, U.TEXT)
    end
  else
  local rmax = math.max(3, math.min(10, sc * 0.035)) * (0.4 + 1.6 * (V.dim or 0.5))   -- 27 окт: dimension (пока — размер точек; после анализа — сколько спектра покрывает звук)
  -- рёбра файл—хаб
  for _, n in ipairs(G.nodes) do   -- за рамку не рисовать: линия — только если оба конца внутри
    local ax, ay, bx, by = X(n), Y(n), X(n.h), Y(n.h)
    if inr(ax, ay) and inr(bx, by) then U.set(U.mix(col(n.h), U.BG, 0.75)); gfx.line(ax, ay, bx, by, 1) end
  end
  for _, n in ipairs(G.nodes) do
    local nx, ny, r = X(n), Y(n), math.max(2, n.r * rmax)
    if nx >= x + r and nx < x + w - r and ny >= y + r and ny < y + h - r then
      local on = playing == n.path
      U.set(on and U.AMBER or U.mix(col(n.h), U.TEXT, 0.25)); gfx.circle(nx, ny, r, 1, 1)
      if inside then
        local d = (mx - nx) ^ 2 + (my - ny) ^ 2
        if d <= (r + 3) ^ 2 and (not hd or d < hd) then hv, hd = { node = n }, d end
      end
    end
  end
  for _, hb in ipairs(G.hubs) do
    local nx, ny = X(hb), Y(hb)
    local r = math.max(4, math.min(14, rmax * (1 + math.sqrt(hb.n) * 0.25)))
    if nx >= x + r and nx < x + w - r and ny >= y + r and ny < y + h - r then
      U.set(col(hb)); gfx.circle(nx, ny, r, 0, 1); gfx.circle(nx, ny, r - 1, 0, 1)
      local lab = hb.name .. ' ' .. hb.n
      local room = x + w - (nx + r + 2) - 2
      if room > U.measure('mm') and ny - L.rh / 2 >= y then U.text(nx + r + 2, ny - L.rh / 2, fit(lab, room), col(hb)) end
      if inside and (mx - nx) ^ 2 + (my - ny) ^ 2 <= (r + 3) ^ 2 then hv = { hub = hb } end
    end
  end
  if hv and hv.node then
    local n = hv.node
    U.set(U.TEXT); gfx.circle(X(n), Y(n), math.max(2, n.r * rmax) + 2, 0, 1)
    local lab = n.name
    local tw = U.measure(lab) + 2 * L.pad
    local tx = math.min(x + w - tw - 1, math.max(x + 1, X(n) + 8))
    local ty = math.min(y + h - L.rh - 1, math.max(y + 1, Y(n) - L.rh - 4))
    U.set(U.PANEL); gfx.rect(tx, ty, tw, L.rh, 1)
    U.set(U.AMBER); gfx.rect(tx, ty, tw, L.rh, 0)
    U.text(tx + L.pad, ty, lab, U.TEXT)
  end
  end
  local info = ('map: %d files, %d groups%s'):format(#G.nodes, #G.hubs, #G.nodes >= SM.MAX and (' (first ' .. SM.MAX .. ')') or '')
  -- 27 окт: кнопка вида: graph / nebula (два положения)
  do
    local lab = V.style == 'nebula' and 'nebula' or 'graph'
    local bw = U.measure('nebula') + 2 * L.pad
    local bx, by = x + L.pad, y + 2
    local hot = mx >= bx and mx < bx + bw and my >= by and my < by + L.rh
    U.set(hot and U.tint(U.AMBER, 0.3) or U.BG); gfx.rect(bx, by, bw, L.rh - 1, 1)
    U.set(hot and U.AMBER or U.LINE); gfx.rect(bx, by, bw, L.rh - 1, 0)
    U.text(bx + L.pad, by, lab, hot and U.AMBER or U.TEXT)
    if hot then hv = { style = true } end
    U.text(bx + bw + L.pad, y + 2, fit(info, w - bw - 3 * L.pad), U.GREY)
  end
  -- 27 окт: ползунки справа сверху — gravity (тяга к центру), dimension (размер; после анализа — покрытие спектра)
  local sw = math.min(L.cw * 10, math.floor(w * 0.25))
  local lw = U.measure('dimension ')
  if w > lw + sw + 2 * L.pad + U.measure('map: 300 files') then
    for k, sl in ipairs({ { 'gravity', 'grav' }, { 'dimension', 'dim' } }) do
      local sy = y + 2 + (k - 1) * L.rh
      local sx = x + w - sw - L.pad
      local v = V[sl[2]] or 0.5
      local hot = mx >= sx - lw and mx < sx + sw and my >= sy and my < sy + L.rh
      U.text(sx - lw, sy, sl[1], hot and U.AMBER or U.GREY)
      U.set(U.DIM); gfx.rect(sx, sy + math.floor(L.rh / 2) - 1, sw, 2, 1)
      U.set(hot and U.AMBER or U.TEXT); gfx.rect(sx, sy + 3, math.max(1, math.floor(sw * v + 0.5)), L.rh - 6, 1)
      if hot then hv = { slider = sl[2], x = sx, w = sw } end
    end
  end
  return hv
end

return SM
