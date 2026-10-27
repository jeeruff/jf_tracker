-- jf_tracker_smap.lua — карта сэмплов папки, как граф Obsidian (27 окт 2026).
-- Узлы — файлы папки и подпапок (до SM.MAX), размер узла — размер файла; категории — узлы-хабы:
-- по словам имени (kick, snare, hat, bass, loop …), без совпадения — по подпапке. Раскладка — силовая
-- (Fruchterman–Reingold): несколько шагов за кадр, пока не остынет. Без анализа звука (этап 2 — признаки).
-- Чистый Lua + gfx; список папки даёт вызывающий (list_dir браузера).
local SM = {}
-- 27 окт (2): без лимита в 300 — папка сканируется по кусочкам между кадрами (SM.scan), размеры файлов — тоже
-- (SM.size_tick); раскладка считает только хабы (их десятки), файлы — спиралью Фибоначчи вокруг своего хаба;
-- точки рисуются в свой буфер gfx (SM.IMG) и перерисовываются, только когда меняется вид
SM.LIMIT = 500000                              -- предохранитель
SM.SCAN_S = 0.004                              -- сканирования за кадр, с
SM.SIZE_MAX = 20000                            -- размеры файлов (радиус точки) — пока файлов не больше
SM.ITERS = 40                                  -- шагов раскладки хабов за кадр (их мало)
SM.U = 0.02                                    -- шаг спирали: расстояние между соседними точками
SM.K0 = 4                                      -- пустое место у центра хаба (под его кольцо)
SM.IMG = 87                                    -- буфер точек (номера картинок — список в jf_tracker_draw.lua)
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
local function now() return R and R.time_precise and R.time_precise() or os.clock() end

-- граф папки и всех подпапок: G.building, пока SM.scan не обошёл дерево
function SM.build(root, list_dir)
  return { root = root, nodes = {}, hubs = {}, t = 0, temp = 0.12, ver = 0, building = true, ndirs = 0,
           stack = { { root, nil } }, list_dir = list_dir }
end
-- обход дерева в пределах бюджета времени; → true, когда готово (тогда же SM.finish)
function SM.scan(G, budget)
  if not G.building then return true end
  local t0 = now()
  local st = G.stack
  while #st > 0 do
    local top = table.remove(st)
    local path, sub = top[1], top[2]
    G.ndirs = G.ndirs + 1
    for _, e in ipairs(G.list_dir(path, true)) do
      local p = (path == '/' and '' or path) .. '/' .. e.name
      if e.dir then st[#st + 1] = { p, sub or e.name }
      elseif #G.nodes < SM.LIMIT then G.nodes[#G.nodes + 1] = { path = p, name = e.name, cat = SM.category(e.name, sub) } end
    end
    if now() - t0 > budget then return false end
  end
  G.building, G.stack, G.list_dir = false, nil, nil
  SM.finish(G)
  return true
end
-- 27 окт: граф из готового списка (db / proj / pm): files { path, name, sub } — sub — запасная группа
function SM.from_files(key, files)
  local G = { root = key, nodes = {}, hubs = {}, t = 0, temp = 0.12, ver = 0 }
  for _, f in ipairs(files) do
    if #G.nodes >= SM.LIMIT then break end
    G.nodes[#G.nodes + 1] = { path = f.path, name = f.name, cat = SM.category(f.name, f.sub) }
  end
  return SM.finish(G)
end
-- место файла в хабе: k-й по спирали Фибоначчи (диск без наложений, плотность ровная)
local function place(n, k)
  local a, rr = k * 2.39996, SM.U * math.sqrt(k + SM.K0)
  n.ox, n.oy = rr * math.cos(a), rr * math.sin(a)
end
function SM.finish(G)
  local hubi = {}
  G.bypath = {}
  for _, n in ipairs(G.nodes) do
    local h = hubi[n.cat]
    if not h then h = { name = n.cat, n = 0, hub = true, list = {}, mass = 0 }; G.hubs[#G.hubs + 1] = h; hubi[n.cat] = h end
    h.n = h.n + 1
    h.list[#h.list + 1] = n
    n.h, n.k, n.r = h, h.n, 0.5
    place(n, h.n)
    G.bypath[n.path] = n
  end
  for _, h in ipairs(G.hubs) do h.R = SM.U * math.sqrt(h.n + SM.K0) + SM.U end
  -- хабы по кругу — радиус по общей площади
  local nh, tot = #G.hubs, 0
  for _, h in ipairs(G.hubs) do tot = tot + h.R * h.R end
  local ring = math.sqrt(tot) * 1.2
  for i, h in ipairs(G.hubs) do
    local a = 2 * math.pi * (i - 1) / math.max(1, nh)
    h.x, h.y = ring * math.cos(a), ring * math.sin(a)
  end
  G.all = G.hubs
  G.szi = #G.nodes <= SM.SIZE_MAX and 1 or nil   -- 27 окт: больше — без размеров (открывать каждый файл на сетевом диске — минуты)
  G.ver = (G.ver or 0) + 1
  -- 27 окт (2): хабов немного — раскладка сразу до покоя (точки потом не перерисовываются каждый кадр)
  for _ = 1, 800 do if not SM.step(G) then break end end
  return G
end
-- размеры файлов по кусочкам: радиус точки — доля наибольшего; → true, когда все
function SM.size_tick(G, budget)
  if not G.szi or G.building then return true end
  local t0, nodes = now(), G.nodes
  while G.szi <= #nodes do
    local n = nodes[G.szi]
    n.size = file_size(n.path)
    n.h.mass = n.h.mass + n.size
    G.szi = G.szi + 1
    if now() - t0 > budget then return false end
  end
  local mx = 1
  for _, n in ipairs(nodes) do mx = math.max(mx, n.size or 0) end
  for _, n in ipairs(nodes) do n.r = 0.25 + 0.75 * math.sqrt((n.size or 0) / mx) end
  G.szi = nil
  G.ver = G.ver + 1
  return true
end

-- шаг раскладки хабов: не налезают дисками, слабо отталкиваются, тянутся к центру (gravity); temp остывает
function SM.step(G)
  if G.building or G.temp < 0.002 then return false end
  local hs = G.hubs
  local n = #hs
  local mean = 0
  for _, h in ipairs(hs) do mean = mean + h.R end
  mean = mean / math.max(1, n)
  local grav = G.grav or 0.5
  for i = 1, n do hs[i].dx, hs[i].dy = 0, 0 end
  for i = 1, n do
    local a = hs[i]
    for j = i + 1, n do
      local b = hs[j]
      local dx, dy = a.x - b.x, a.y - b.y
      local d = math.sqrt(dx * dx + dy * dy) + 1e-9
      local need = a.R + b.R + SM.U * 3
      local f = (mean * mean * 4) / (d * d) * (2 - 1.5 * grav) * 0.02   -- 27 окт: gravity — хабы друг от друга слабее
      if d < need then f = f + (need - d) / d * 0.5 end
      a.dx, a.dy = a.dx + dx * f, a.dy + dy * f
      b.dx, b.dy = b.dx - dx * f, b.dy - dy * f
    end
  end
  local gc = 0.02 + 0.5 * grav ^ 2
  local stepmax = G.temp * math.max(mean, 0.05) * 8
  for _, a in ipairs(hs) do
    a.dx, a.dy = a.dx - a.x * gc * 0.1, a.dy - a.y * gc * 0.1
    local d = math.sqrt(a.dx * a.dx + a.dy * a.dy) + 1e-12
    local s = math.min(d, stepmax) / d
    a.x, a.y = a.x + a.dx * s, a.y + a.dy * s
  end
  G.temp = G.temp * 0.97
  return true
end

local GREEK = { 'ALPHA', 'BETA', 'GAMMA', 'DELTA', 'EPSILON', 'ZETA', 'ETA', 'THETA', 'IOTA', 'KAPPA', 'LAMBDA', 'MU', 'NU', 'XI', 'OMICRON', 'PI', 'RHO', 'SIGMA', 'TAU', 'UPSILON' }
local function mb(b) return b >= 1048576 and ('%.1f MB'):format(b / 1048576) or ('%d KB'):format(math.floor(b / 1024 + 0.5)) end
-- ── 27 окт: вид CARDS (был первой nebula) — группы в ровных квадрантах (сетка), точки внутри своего — спиралью;
-- без анимации (пользователь: дёргание не помогает искать) — точки в буфере; gravity сжимает облако к центру сектора
function SM.neb_layout(G, x, y, w, h, L)
  local nh = #G.hubs
  if not G.neb then
    G.neb = true
    table.sort(G.hubs, function(a, b) return a.n > b.n end)
    for i, hb in ipairs(G.hubs) do hb.cell = i end
  end
  local cols = math.max(1, math.ceil(math.sqrt(nh * w / math.max(1, h))))
  local rows = math.max(1, math.ceil(nh / cols))
  local top = y + L.rh + 4
  return cols, rows, top, w / cols, (y + h - top) / rows
end
function SM.draw_cards(U, L, G, x, y, w, h, V, playing, fit, col, mx, my, inside)
  local cols, rows, top, cw, ch = SM.neb_layout(G, x, y, w, h, L)
  local hv, hd
  local rmax = math.max(2, math.min(7, math.min(cw, ch) * 0.03)) * (0.4 + 1.6 * (V.dim or 0.5))
  local spread = 0.95 - 0.45 * (V.grav or 0.5)
  local function pos(n)
    local hb = n.h
    local i = hb.cell - 1
    local qx0, qy0 = x + (i % cols) * cw, top + math.floor(i / cols) * ch
    local rr = math.sqrt((n.k - 0.5) / hb.n) * spread
    local a = n.k * 2.39996
    local qx, qy = rr * math.cos(a), rr * math.sin(a)
    return qx0 + cw / 2 + qx * (cw / 2 - 10), qy0 + ch / 2 + 6 + qy * (ch / 2 - 18)
  end
  -- точки — в буфер, пока вид тот же
  local function dots(ox, oy)
    for _, hb in ipairs(G.hubs) do
      local c = col(hb)
      U.set(U.mix(c, U.TEXT, 0.15), 0.85)
      for _, n in ipairs(hb.list) do
        local px, py = pos(n)
        local r = n.r * rmax
        if r < 1.5 then gfx.rect(px - ox, py - oy, 2, 2, 1) else gfx.circle(px - ox, py - oy, r, 1, 1) end
      end
    end
    gfx.a = 1
  end
  SM.buffered(G, ('cards|%d|%d|%d|%d|%.3f|%.3f|%d'):format(x, y, w, h, V.dim or 0.5, V.grav or 0.5, G.ver), x, y, w, h, U, function() dots(x, y) end)
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
    -- ближайшая точка — только в секторе под мышью
    if inside and not hv and mx >= qx0 and mx < qx0 + cw and my >= qy0 and my < qy0 + ch then
      for _, n in ipairs(hb.list) do
        local px, py = pos(n)
        local d = (mx - px) ^ 2 + (my - py) ^ 2
        local r = math.max(1, n.r * rmax)
        if d <= (r + 3) ^ 2 and (not hd or d < hd) then hv, hd = { node = n, px = px, py = py, r = r }, d end
      end
    end
  end
  local pn = playing and G.bypath and G.bypath[playing]
  if pn then local px, py = pos(pn); U.set(U.AMBER); gfx.circle(px, py, math.max(2, pn.r * rmax) + 1, 1, 1) end
  return hv
end


-- ── 27 окт (2): вид NEBULA — одна галактика из всех сэмплов (звёздная карта): звёзды — по плотности спиральной
-- галактики, облако режется на прямоугольные секторы по числу файлов групп (kd-разбиение: каждая группа — свой
-- кусок неба, плотность галактики сохраняется); секторы — рамки поверх облака с подписью «KICK SECTOR 34»
SM.NEB_MAX = 24000                             -- звёзд на экране (у каждой группы — доля, минимум одна)
local function rnd(k) local v = math.sin(k * 12.9898 + 78.233) * 43758.5453; return v - math.floor(v) end
local function galaxy_star(k)
  -- две спиральные ветви + ядро; детерминированно по номеру
  local u, v, wv = rnd(k), rnd(k + 0.37), rnd(k + 0.71)
  local r = u ^ 0.65
  local arm = (wv < 0.5) and 0 or math.pi
  local a = arm + r * 5.2 + (v - 0.5) * (0.9 - 0.5 * r) * 2
  if wv > 0.85 then a = v * 2 * math.pi; r = u ^ 1.6 * 0.5 end   -- ядро / гало
  local sx, sy = r * math.cos(a), r * math.sin(a) * 0.78
  return sx + (rnd(k + 0.13) - 0.5) * 0.06, sy + (rnd(k + 0.91) - 0.5) * 0.06
end
function SM.neb_build(G)
  if G.gal then return end
  local total = #G.nodes
  local show = math.min(total, SM.NEB_MAX)
  -- доля звёзд у группы: пропорционально, минимум одна; звёзды — первые файлы группы
  local stars, k = {}, 0
  for _, hb in ipairs(G.hubs) do
    local m = math.max(1, math.floor(hb.n * show / math.max(1, total) + 0.5))
    hb.stars = {}
    for j = 1, math.min(m, hb.n) do
      k = k + 1
      local sx, sy = galaxy_star(k)
      stars[#stars + 1] = { x = sx, y = sy }
    end
  end
  -- kd-разбиение: группы делятся на две половины с близкой суммой звёзд, звёзды — по длинной оси прямоугольника
  local function part(pts, hubs, x0, y0, x1, y1)
    if #hubs == 1 then
      local hb = hubs[1]
      hb.rect = { x0, y0, x1, y1 }
      for _, p in ipairs(pts) do hb.stars[#hb.stars + 1] = p end
      return
    end
    local sum, need = 0, 0
    for _, hb in ipairs(hubs) do need = need + hb.m end
    local A, B, ca = {}, {}, 0
    for _, hb in ipairs(hubs) do
      if ca + hb.m <= need / 2 or #A == 0 then A[#A + 1] = hb; ca = ca + hb.m else B[#B + 1] = hb end
    end
    if #B == 0 then B[1] = table.remove(A); ca = ca - B[1].m end
    local horiz = (x1 - x0) >= (y1 - y0)
    table.sort(pts, function(p, q) if horiz then return p.x < q.x end; return p.y < q.y end)
    local pa, pb = {}, {}
    for i, p in ipairs(pts) do if i <= ca then pa[#pa + 1] = p else pb[#pb + 1] = p end end
    local a, b = pts[ca], pts[ca + 1]
    local cut
    if horiz then cut = (a and b) and (a.x + b.x) / 2 or (x0 + x1) / 2 else cut = (a and b) and (a.y + b.y) / 2 or (y0 + y1) / 2 end
    if horiz then part(pa, A, x0, y0, cut, y1); part(pb, B, cut, y0, x1, y1)
    else part(pa, A, x0, y0, x1, cut); part(pb, B, x0, cut, x1, y1) end
  end
  for _, hb in ipairs(G.hubs) do hb.m = #hb.stars; hb.stars = {} end
  local hubs = {}
  for _, hb in ipairs(G.hubs) do hubs[#hubs + 1] = hb end
  table.sort(hubs, function(a, b) return a.m > b.m end)
  part(stars, hubs, -1.05, -0.85, 1.05, 0.85)
  -- звезда — файл группы (первые по порядку): по ней наведение и клик
  for _, hb in ipairs(G.hubs) do for j, st in ipairs(hb.stars) do st.n = hb.list[j] end end
  G.gal = true
end
-- 27 окт (2): вид СИСТЕМЫ — сектор (группа / папка) на весь вид: все её файлы диском, подписи без наложений;
-- кнопка galaxy / Esc — назад к галактике
function SM.draw_system(U, L, G, hb, x, y, w, h, V, playing, fit, col, mx, my, inside)
  local top = y + L.rh + 4
  local gw, gh = w - 8, y + h - top - 4
  local zoom = V.zoom or 1
  local cx, cy = x + w / 2 + (V.px or 0), top + gh / 2 + (V.py or 0)
  local rad = math.min(gw, gh) / 2 * 0.92 * zoom
  local c = col(hb)
  local n = hb.n
  local function pos(nd)
    local rr = math.sqrt((nd.k - 0.5) / n) * rad
    local a = nd.k * 2.39996
    return cx + rr * math.cos(a), cy + rr * math.sin(a)
  end
  local rdot = math.max(1.5, math.min(5, rad / math.sqrt(n) * 0.35)) * (0.4 + 1.6 * (V.dim or 0.5))
  local function paint()
    U.set(U.mix(c, U.BG, 0.85)); gfx.circle(cx - x, cy - y, rad, 0, 1)
    U.set(U.mix(c, U.TEXT, 0.25))
    for _, nd in ipairs(hb.list) do
      local px, py = pos(nd)
      local r = math.max(1, nd.r * rdot)
      px, py = px - x, py - y
      if px >= 0 and px < w and py >= 0 and py < h then if r < 1.5 then gfx.rect(px, py, 2, 2, 1) else gfx.circle(px, py, r, 1, 1) end end
    end
  end
  SM.buffered(G, ('sys|%s|%d|%d|%d|%d|%.4f|%.1f|%.1f|%.3f|%d'):format(hb.name, x, y, w, h, zoom, cx, cy, V.dim or 0.5, G.ver), x, y, w, h, U, paint)
  -- подписи файлов: ближе к центру — первыми, без наложений
  local placed = {}
  local function free(ax, ay, aw, ah)
    for _, q in ipairs(placed) do if ax < q[1] + q[3] and q[1] < ax + aw and ay < q[2] + q[4] and q[2] < ay + ah then return false end end
    return true
  end
  local hv, hd
  local budget = 400
  for _, nd in ipairs(hb.list) do
    local px, py = pos(nd)
    if px >= x and px < x + w and py >= top and py < y + h then
      if inside then
        local d = (mx - px) ^ 2 + (my - py) ^ 2
        if d <= 64 and (not hd or d < hd) then hv, hd = { node = nd, px = px, py = py, r = 3 }, d end
      end
      if budget > 0 then
        local lab = (nd.name:gsub('%.[%w]+$', ''))
        local lw = math.min(U.measure(lab), L.cw * 14)
        local lx, ly = px + 4, py - L.rh / 2
        if lx + lw < x + w - 2 and ly >= top and ly + L.rh < y + h and free(lx - 6, ly, lw + 6, L.rh) then
          placed[#placed + 1] = { lx - 6, ly, lw + 6, L.rh }
          U.text(lx, ly, fit(lab, lw), U.mix(c, U.TEXT, 0.4))
          budget = budget - 1
        end
      end
    end
  end
  -- заголовок системы и кнопка назад
  local title = ('%s SYSTEM  %d BODIES'):format((hb.name:gsub('^/', '')):upper(), n)
  local bx, by = x + L.pad, top
  local bw = U.measure('galaxy') + 2 * L.pad
  local hot = inside and mx >= bx and mx < bx + bw and my >= by and my < by + L.rh
  U.set(hot and U.tint(U.AMBER, 0.3) or U.BG); gfx.rect(bx, by, bw, L.rh - 1, 1)
  U.set(hot and U.AMBER or U.LINE); gfx.rect(bx, by, bw, L.rh - 1, 0)
  U.text(bx + L.pad, by, 'galaxy', hot and U.AMBER or U.TEXT)
  if hot then hv = { back = true } end
  U.text(bx + bw + L.pad, by, fit(title, w - bw - 3 * L.pad), c)
  local pn = playing and G.bypath and G.bypath[playing]
  if pn and pn.h == hb then local px, py = pos(pn); U.set(U.AMBER); gfx.circle(px, py, 4, 1, 1) end
  if hv and hv.node then U.set(U.TEXT); gfx.circle(hv.px, hv.py, 5, 0, 1) end
  return hv
end
function SM.draw_nebula(U, L, G, x, y, w, h, V, playing, fit, col, mx, my, inside)
  if V.sys then
    for _, hb in ipairs(G.hubs) do if hb.name == V.sys then return SM.draw_system(U, L, G, hb, x, y, w, h, V, playing, fit, col, mx, my, inside) end end
    V.sys = nil
  end
  SM.neb_build(G)
  local top = y + L.rh + 4
  local gw, gh = w - 8, y + h - top - 4
  local zoom = V.zoom or 1
  local cx, cy = x + w / 2 + (V.px or 0), top + gh / 2 + (V.py or 0)
  local s1 = math.min(gw / 2.1, gh / 1.7) * zoom   -- одинаковый масштаб по осям: галактика не вытягивается в узкой панели
  local sx, sy = s1, s1
  local function X(v) return cx + v * sx end
  local function Y(v) return cy + v * sy end
  local rmax = math.max(0.8, math.min(3, math.min(sx, sy) * 0.006)) * (0.4 + 1.6 * (V.dim or 0.5))
  local function paint()
    local ox, oy = x, y
    -- кольца-ориентиры галактики (как на картах): тускло
    U.set(U.mix(U.TEXT, U.BG, 0.9))
    for _, rr in ipairs({ 0.25, 0.5, 0.75, 1.0 }) do gfx.circle(X(0) - ox, Y(0) - oy, rr * math.min(sx, sy * 1.28), 0, 1) end
    for _, hb in ipairs(G.hubs) do
      U.set(U.mix(col(hb), U.TEXT, 0.35))
      for _, st in ipairs(hb.stars) do
        local px, py = X(st.x) - ox, Y(st.y) - oy
        local r = (st.n and st.n.r or 0.5) * rmax
        if px >= 0 and px < w and py >= 0 and py < h then
          if r < 1.3 then gfx.rect(px, py, 1, 1, 1) else gfx.circle(px, py, r, 1, 1) end
        end
      end
    end
  end
  SM.buffered(G, ('neb|%d|%d|%d|%d|%.4f|%.1f|%.1f|%.3f|%d'):format(x, y, w, h, zoom, cx, cy, V.dim or 0.5, G.ver), x, y, w, h, U, paint)
  -- секторы — рамки поверх облака: уголки, подпись в левом верхнем углу; крупные первыми, подписи без наложений
  local hv, hd
  local order = {}
  for _, hb in ipairs(G.hubs) do order[#order + 1] = hb end
  table.sort(order, function(a, b) return a.n > b.n end)
  local placed = {}
  local function free(ax, ay, aw, ah)
    for _, q in ipairs(placed) do if ax < q[1] + q[3] and q[1] < ax + aw and ay < q[2] + q[4] and q[2] < ay + ah then return false end end
    return true
  end
  local function clipx(v) return math.max(x + 1, math.min(x + w - 2, v)) end
  local function clipy(v) return math.max(top, math.min(y + h - 2, v)) end
  for _, hb in ipairs(order) do
    local rc = hb.rect
    if rc then
      local bx0, by0, bx1, by1 = math.floor(X(rc[1])), math.floor(Y(rc[2])), math.floor(X(rc[3])), math.floor(Y(rc[4]))
      local vis = bx1 > x and bx0 < x + w and by1 > top and by0 < y + h
      if vis then
        local c = col(hb)
        local hot = inside and mx >= bx0 and mx < bx1 and my >= by0 and my < by1
        local cx0, cy0, cx1, cy1 = clipx(bx0), clipy(by0), clipx(bx1), clipy(by1)
        U.set(U.mix(c, U.BG, hot and 0.25 or 0.65))
        gfx.rect(cx0, cy0, cx1 - cx0, 1, 1); gfx.rect(cx0, cy1, cx1 - cx0, 1, 1)
        gfx.rect(cx0, cy0, 1, cy1 - cy0, 1); gfx.rect(cx1, cy0, 1, cy1 - cy0 + 1, 1)
        local lab = ('%s SECTOR %d'):format((hb.name:gsub('^/', '')):upper(), hb.n)
        local lw = math.min(U.measure(lab), cx1 - cx0 - 6)
        if lw > U.measure('MM') and cy1 - cy0 > L.rh + 2 and (hot or free(cx0 + 3, cy0 + 2, lw, L.rh)) then
          placed[#placed + 1] = { cx0 + 3, cy0 + 2, lw, L.rh }
          if hot then U.set(U.BG); gfx.rect(cx0 + 2, cy0 + 2, lw + 2, L.rh, 1) end
          U.text(cx0 + 3, cy0 + 2, fit(lab, cx1 - cx0 - 6), hot and c or U.mix(c, U.BG, 0.2))
        end
        if hot then
          hv = hv or { hub = hb, sector = true }
          for _, st in ipairs(hb.stars) do
            local px, py = X(st.x), Y(st.y)
            local d = (mx - px) ^ 2 + (my - py) ^ 2
            if st.n and d <= 36 and (not hd or d < hd) then hv, hd = { node = st.n, px = px, py = py, r = 2 }, d end
          end
        end
      end
    end
  end
  -- что звучит — подсветка звезды
  local pn = playing and G.bypath and G.bypath[playing]
  if pn and pn.h.stars then
    for _, st in ipairs(pn.h.stars) do if st.n == pn then U.set(U.AMBER); gfx.circle(X(st.x), Y(st.y), 3, 1, 1) end end
  end
  if hv and hv.node then U.set(U.TEXT); gfx.circle(hv.px, hv.py, 4, 0, 1) end
  return hv
end

-- точки в свой буфер: перерисовка, только когда меняется ключ вида; иначе — копия буфера
function SM.buffered(G, key, x, y, w, h, U, paint)
  w, h = math.max(1, math.floor(w)), math.max(1, math.floor(h))
  if G.bkey ~= key or SM.bowner ~= G then
    local d0 = gfx.dest
    gfx.setimgdim(SM.IMG, -1, -1); gfx.setimgdim(SM.IMG, w, h)
    gfx.dest = SM.IMG
    U.set(U.BG); gfx.rect(0, 0, w, h, 1)
    paint()
    gfx.dest = d0
    G.bkey, SM.bowner = key, G
  end
  gfx.a = 1
  gfx.blit(SM.IMG, 1, 0, 0, 0, w, h, x, y, w, h)
end

-- рисование в прямоугольнике; V = { zoom, px, py, grav, dim, style } (вид, общий для вызывающего); playing — путь, что звучит;
-- → hover { node = n } | { hub = h } | { style = true } | { slider = … } | nil
local HUE = { kick = 1, snare = 2, hat = 3, clap = 4, tom = 5, cymbal = 6, perc = 7, bass = 8, loop = 9, fx = 10, vox = 11, synth = 12 }
SM.EDGES_MAX = 4000                            -- рёбра файл—хаб — пока файлов не больше (иначе сплошная заливка)
function SM.draw(U, L, G, x, y, w, h, V, playing, fit)
  if G.building then SM.scan(G, SM.SCAN_S) end
  if not G.building then SM.size_tick(G, SM.SCAN_S) end
  G.grav = V.grav
  for _ = 1, SM.ITERS do if not SM.step(G) then break end end
  U.set(U.BG); gfx.rect(x, y, w, h, 1)
  U.set(U.LINE); gfx.rect(x, y, w, h, 0)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local inside = mx >= x and mx < x + w and my >= y and my < y + h
  if G.building then
    U.text(x + L.pad, y + 2, fit(('map: scanning... %d files in %d folders'):format(#G.nodes, G.ndirs or 0), w - 2 * L.pad), U.AMBER)
    return nil
  end
  if #G.nodes == 0 then U.text(x + L.pad, y + 2, fit('map: no sound files here', w - 2 * L.pad), U.DIM); return nil end
  local PAL = { U.AMBER, U.CYAN, U.GREEN, U.RED, U.YELLOW, U.PINK or U.RED }
  local function col(hb)
    local i = HUE[hb.name] or (#hb.name % 6 + 1)
    return PAL[(i - 1) % #PAL + 1]
  end
  local hv, hd
  if V.style == 'nebula' then
    hv = SM.draw_nebula(U, L, G, x, y, w, h, V, playing, fit, col, mx, my, inside)
  elseif V.style == 'cards' then
    hv = SM.draw_cards(U, L, G, x, y, w, h, V, playing, fit, col, mx, my, inside)
  else
    -- 27 окт: вписать в прямоугольник по дискам хабов; зум и сдвиг — поверх
    local x0, x1, y0, y1 = math.huge, -math.huge, math.huge, -math.huge
    for _, a in ipairs(G.hubs) do x0, x1, y0, y1 = math.min(x0, a.x - a.R), math.max(x1, a.x + a.R), math.min(y0, a.y - a.R), math.max(y1, a.y + a.R) end
    local ox, oy = (x0 + x1) / 2, (y0 + y1) / 2
    local sc = math.min(0.46 * w / math.max(0.05, (x1 - x0) / 2), 0.46 * (h - L.rh) / math.max(0.05, (y1 - y0) / 2)) * (V.zoom or 1)
    local cx, cy = x + w / 2 + (V.px or 0), y + L.rh / 2 + h / 2 + (V.py or 0)
    local function HX(hb) return cx + (hb.x - ox) * sc end
    local function HY(hb) return cy + (hb.y - oy) * sc end
    -- 27 окт: dimension (пока — размер точек; после анализа — сколько спектра покрывает звук)
    local rmax = math.max(0.7, math.min(10, sc * SM.U * 0.5)) * (0.4 + 1.6 * (V.dim or 0.5))
    local function paint()
      local edges = #G.nodes <= SM.EDGES_MAX
      for _, hb in ipairs(G.hubs) do
        local c = col(hb)
        local hx, hy = HX(hb) - x, HY(hb) - y
        if edges then
          U.set(U.mix(c, U.BG, 0.78))
          for _, n in ipairs(hb.list) do
            local px, py = hx + n.ox * sc, hy + n.oy * sc
            if px >= 0 and px < w and py >= 0 and py < h then gfx.line(px, py, hx, hy, 1) end
          end
        end
        U.set(U.mix(c, U.TEXT, 0.25))
        for _, n in ipairs(hb.list) do
          local px, py = hx + n.ox * sc, hy + n.oy * sc
          local r = n.r * rmax
          if px >= -r and px < w + r and py >= -r and py < h + r then
            if r < 1.5 then gfx.rect(px, py, r < 0.9 and 1 or 2, r < 0.9 and 1 or 2, 1) else gfx.circle(px, py, r, 1, 1) end
          end
        end
      end
    end
    SM.buffered(G, ('g|%d|%d|%d|%d|%.4f|%.1f|%.1f|%.3f|%d|%.4f'):format(x, y, w, h, sc, cx, cy, V.dim or 0.5, G.ver, G.temp > 0.002 and G.temp or 0), x, y, w, h, U, paint)
    -- хабы: кольцо и подпись — живьём поверх буфера; точка под мышью — только в диске своего хаба
    -- подписи без наложений: крупные группы первыми, подпись не влезла рядом с другими — не пишется (видна по наведению)
    G.lab_order = G.lab_order or (function() local t = {}; for i, hb in ipairs(G.hubs) do t[i] = hb end; table.sort(t, function(a, b) return a.n > b.n end); return t end)()
    local placed = {}
    local function free(ax, ay, aw, ah)
      for _, q in ipairs(placed) do if ax < q[1] + q[3] and q[1] < ax + aw and ay < q[2] + q[4] and q[2] < ay + ah then return false end end
      return true
    end
    for _, hb in ipairs(G.lab_order) do
      local nx, ny = HX(hb), HY(hb)
      local r = math.max(4, math.min(14, SM.U * math.sqrt(SM.K0) * sc))
      if nx >= x + r and nx < x + w - r and ny >= y + r and ny < y + h - r then
        U.set(col(hb)); gfx.circle(nx, ny, r, 0, 1); gfx.circle(nx, ny, r - 1, 0, 1)
        local hot = inside and (mx - nx) ^ 2 + (my - ny) ^ 2 <= (r + 3) ^ 2
        local lab = hb.name .. ' ' .. hb.n
        local lx, ly = nx + r + 2, ny - L.rh / 2
        local room = x + w - lx - 2
        local lw = math.min(room, U.measure(lab))
        if room > U.measure('mm') and ly >= y + L.rh and (hot or free(lx, ly, lw, L.rh)) then
          placed[#placed + 1] = { lx, ly, lw, L.rh }
          if hot then U.set(U.PANEL); gfx.rect(lx - 1, ly, lw + 2, L.rh, 1) end
          U.text(lx, ly, fit(lab, room), col(hb))
        end
        if hot then hv = { hub = hb } end
      end
      if inside and not hv and (mx - nx) ^ 2 + (my - ny) ^ 2 <= (hb.R * sc + 4) ^ 2 then
        for _, n in ipairs(hb.list) do
          local px, py = nx + n.ox * sc, ny + n.oy * sc
          local rr = math.max(2, n.r * rmax)
          local d = (mx - px) ^ 2 + (my - py) ^ 2
          if d <= (rr + 3) ^ 2 and (not hd or d < hd) then hv, hd = { node = n, px = px, py = py, r = rr }, d end
        end
      end
    end
    local pn = playing and G.bypath and G.bypath[playing]
    if pn then U.set(U.AMBER); gfx.circle(HX(pn.h) + pn.ox * sc, HY(pn.h) + pn.oy * sc, math.max(2, pn.r * rmax) + 1, 1, 1) end
    if hv and hv.node then U.set(U.TEXT); gfx.circle(hv.px, hv.py, hv.r + 2, 0, 1) end
  end
  if hv and hv.node then
    local lab = hv.node.name
    local tw = U.measure(lab) + 2 * L.pad
    local tx = math.min(x + w - tw - 1, math.max(x + 1, hv.px + 8))
    local ty = math.min(y + h - L.rh - 1, math.max(y + 1, hv.py - L.rh - 4))
    U.set(U.PANEL); gfx.rect(tx, ty, tw, L.rh, 1); U.set(U.AMBER); gfx.rect(tx, ty, tw, L.rh, 0)
    U.text(tx + L.pad, ty, fit(lab, tw), U.TEXT)
  end
  -- 27 окт: ползунки справа сверху — gravity (тяга к центру), dimension (размер; после анализа — покрытие спектра)
  local sw = math.min(L.cw * 10, math.floor(w * 0.25))
  local lw = U.measure('dimension ')
  local right = x + w   -- левый край ползунков: подпись слева до него, не налезает
  if w > lw + sw + 2 * L.pad + U.measure('graph cards nebula random ') + U.measure('300 files') then
    right = x + w - sw - L.pad - lw - L.pad
    for k, sl in ipairs({ { 'gravity', 'grav' }, { 'dimension', 'dim' } }) do
      local sy = y + 2 + (k - 1) * L.rh
      local sx = x + w - sw - L.pad
      local v = V[sl[2]] or 0.5
      local hot = mx >= sx - lw and mx < sx + sw and my >= sy and my < sy + L.rh
      U.set(U.BG); gfx.rect(sx - lw, sy, lw + sw, L.rh, 1)
      U.text(sx - lw, sy, sl[1], hot and U.AMBER or U.GREY)
      U.set(U.DIM); gfx.rect(sx, sy + math.floor(L.rh / 2) - 1, sw, 2, 1)
      U.set(hot and U.AMBER or U.TEXT); gfx.rect(sx, sy + 3, math.max(1, math.floor(sw * v + 0.5)), L.rh - 6, 1)
      if hot then hv = { slider = sl[2], x = sx, w = sw } end
    end
  end
  -- 27 окт: кнопка вида: graph / nebula (два положения) и счёт; текст — до ползунков
  do
    local info = ('%d files, %d groups%s'):format(#G.nodes, #G.hubs, G.szi and ' - sizes...' or '')
    -- 27 окт (2): вид — три вкладки (не кнопка с тремя положениями); random — случайный сэмпл (сектор под мышью / все)
    local bx, by = x + L.pad, y + 2
    local cur = V.style or 'graph'
    local bw = 0
    for _, nm in ipairs({ 'graph', 'cards', 'nebula', 'random' }) do
      local tw = U.measure(nm) + 2 * L.pad
      local on = nm == cur
      local hot = mx >= bx and mx < bx + tw and my >= by and my < by + L.rh
      U.set(hot and U.tint(U.AMBER, 0.3) or (on and U.tint(U.AMBER, 0.15) or U.BG)); gfx.rect(bx, by, tw, L.rh - 1, 1)
      U.set((hot or on) and U.AMBER or U.LINE); gfx.rect(bx, by, tw, L.rh - 1, 0)
      U.text(bx + L.pad, by, nm, (hot or on) and U.AMBER or U.TEXT)
      if hot then hv = nm == 'random' and { random = true } or { style = nm } end
      bx = bx + tw + 2
    end
    bx = bx - bw
    local room = right - (bx + L.pad) - L.pad
    if room > U.measure('mm') then
      U.set(U.BG); gfx.rect(bx + L.pad, y + 2, math.min(room, U.measure(info)), L.rh - 1, 1)
      U.text(bx + L.pad, y + 2, fit(info, room), U.GREY)
    end
  end
  return hv
end

return SM
