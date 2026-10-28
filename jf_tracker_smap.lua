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

-- 27 окт (8): типы файлов карты: сэмплы, MIDI, REX, automation items, шаблоны треков; не-сэмплы — своей группой по типу
SM.TYPES = { 'samples', 'midi', 'rex', 'auto', 'tpl' }
SM.EXT_TYPE = { wav = 'samples', aif = 'samples', aiff = 'samples', flac = 'samples', mp3 = 'samples', ogg = 'samples', m4a = 'samples',
  wv = 'samples', caf = 'samples', opus = 'samples', w64 = 'samples',
  mid = 'midi', midi = 'midi', rx2 = 'rex', rex = 'rex', rcy = 'rex', reaperautoitem = 'auto', rtracktemplate = 'tpl' }
function SM.ext_type(name) local e = name:match('%.([%w]+)$'); return e and SM.EXT_TYPE[e:lower()] end
function SM.cat_of(name, sub)
  local t = SM.ext_type(name)
  if t and t ~= 'samples' then return t end
  return SM.category(name, sub)
end
-- короткое имя по месту: главные слова (без версий, «samples», «pack» …), не длиннее maxch
local NOISE = { samples = true, sample = true, pack = true, library = true, kit = true, wav = true, the = true, vol = true, free = true,
  multiformat = true, kontakt = true, sounds = true, sound = true, collection = true, complete = true, ['and'] = true, of = true, ['for'] = true }
SM.short_memo = setmetatable({}, { __mode = 'k' })
function SM.short(name, maxch)
  -- 27 окт (9): кэш по имени и длине — подписи 150 групп каждый кадр сорили строками
  local m = SM.short_memo[name]
  if not m then m = {}; SM.short_memo[name] = m end
  local r = m[maxch]
  if not r then r = SM.short0(name, maxch); m[maxch] = r end
  return r
end
function SM.short0(name, maxch)
  local base = (name:gsub('^[/!_%s]+', ''))
  if #base <= maxch then return base end
  local out = ''
  for w in base:gmatch('[^%s%-_%.%(%)%[%]&,|]+') do
    if not NOISE[w:lower()] and not w:match('^%d+$') and not w:match('^v%d') then
      local nxt = out == '' and w or (out .. ' ' .. w)
      if #nxt > maxch then break end
      out = nxt
    end
  end
  if out == '' then out = base:sub(1, math.max(1, maxch)) end
  return out
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
  if G.rd then return SM.read_tick(G, budget * 3) end
  local t0 = now()
  local st = G.stack
  while #st > 0 do
    local top = table.remove(st)
    local path, sub = top[1], top[2]
    G.ndirs = G.ndirs + 1
    for _, e in ipairs(G.list_dir(path, true)) do
      local p = (path == '/' and '' or path) .. '/' .. e.name
      if e.dir then st[#st + 1] = { p, sub or e.name }
      elseif #G.nodes < SM.LIMIT then G.nodes[#G.nodes + 1] = { path = p, name = e.name, cat = SM.cat_of(e.name, sub), dir = path, sub = sub } end
    end
    if now() - t0 > budget then return false end
  end
  G.building, G.stack, G.list_dir = false, nil, nil
  SM.finish(G)
  return true
end
-- 27 окт (2): индекс на диске — один раз просканировали, дальше карта сразу из него; фоновая проверка ищет изменения.
-- Формат: строка «D\t<папка>\t<sub>», за ней «<имя файла>» по строке
function SM.save_cache(G, file)
  local f = io.open(file .. '.tmp', 'w')
  if not f then return false end
  f:write('JFMAP1\t', G.root, '\n')
  local last
  for _, n in ipairs(G.raw or G.nodes) do
    if n.dir ~= last then f:write('D\t', n.dir or '', '\t', n.sub or '', '\n'); last = n.dir end
    f:write(n.name, '\n')
  end
  f:close()
  os.remove(file); os.rename(file .. '.tmp', file)
  return true
end
function SM.load_cache(root, file)
  local f = io.open(file, 'r')
  if not f then return nil end
  local head = f:read('*l') or ''
  if head ~= 'JFMAP1\t' .. root then f:close(); return nil end
  -- 27 окт (9): чтение по кадрам (SM.scan) — 190 тыс. строк разом замораживали окно на 4 с
  return { root = root, nodes = {}, hubs = {}, t = 0, temp = 0.12, ver = 0, cached = true, building = true, rd = f, ndirs = 0 }
end
function SM.read_tick(G, budget)
  local t0 = now()
  local f, k = G.rd, 0
  while true do
    local line = f:read('*l')
    if not line then f:close(); G.rd = nil; G.building = false; SM.finish(G); return true end
    if line:sub(1, 2) == 'D\t' then
      local d, sb = line:match('^D\t([^\t]*)\t(.*)$')
      G.rdir = d; G.rsub = (sb ~= '' and sb) or nil; G.ndirs = G.ndirs + 1
    elseif G.rdir and #G.nodes < SM.LIMIT then
      local dir = G.rdir
      G.nodes[#G.nodes + 1] = { path = (dir == '/' and '' or dir) .. '/' .. line, name = line, cat = SM.cat_of(line, G.rsub), dir = dir, sub = G.rsub }
    end
    k = k + 1
    if k % 256 == 0 and now() - t0 > budget then return false end
  end
end
-- 27 окт (9): ЭТАП 2 — грубый анализ звука (пики REAPER + спектральный слой 's', без внешних программ):
-- l — громкость (средний пик 0..1), b — яркость (средняя частота спектра в лог-шкале 50 Гц..16 кГц, 0..1).
-- SM.AN[path] = { l, b } — общий для всех папок, на диске Data/jf_tracker_mapan.txt; считаются файлы, которые
-- слушали, и группа под мышью (не все 190 тыс. — пики строятся файлами на диск)
SM.AN, SM.an_dirty = {}, false
function SM.an_from_peaks(pk)
  if not (pk and pk.n and pk.n > 0) then return nil end
  local sl, sb, nb = 0, 0, 0
  for i = 1, pk.n do
    local a = math.max(math.abs(pk.max[i] or 0), math.abs(pk.min[i] or 0))
    sl = sl + a
    local sv = pk.spec and pk.spec[i]
    if sv and sv > 0 and a > 0.01 then
      local f = math.floor(sv) % 32768
      if f > 20 then sb = sb + math.max(0, math.min(1, math.log(f / 50, 2) / math.log(16000 / 50, 2))); nb = nb + 1 end
    end
  end
  return { l = math.min(1, sl / pk.n * 1.6), b = nb > 0 and sb / nb or 0.5 }
end
function SM.an_load(file)
  local f = io.open(file, 'r'); if not f then return end
  for line in f:lines() do
    local pth, l, b, d = line:match('^(.-)\t([%d%.]+)\t([%d%.]+)\t?([%d%.]*)$')
    if pth then SM.AN[pth] = { l = tonumber(l), b = tonumber(b), d = tonumber(d) }; SM.an_n = (SM.an_n or 0) + 1 end
  end
  f:close()
end
function SM.an_save(file)
  if not SM.an_dirty then return end
  local f = io.open(file .. '.tmp', 'w'); if not f then return end
  for pth, a in pairs(SM.AN) do f:write(pth, '\t', ('%.3f'):format(a.l), '\t', ('%.3f'):format(a.b), '\t', a.d and ('%.3f'):format(a.d) or '', '\n') end
  f:close(); os.remove(file); os.rename(file .. '.tmp', file)
  SM.an_dirty = false
end
-- группа: после анализа — спираль по яркости (тёмные к центру, яркие наружу): похожие звуки рядом
function SM.an_resort(G, hb)
  local function key(n) local a = SM.AN[n.path]; return a and a.b or 2 end
  table.sort(hb.list, function(p, q) return key(p) < key(q) end)
  hb.chl = nil   -- 27 окт (10): яркость поменялась — фигура Хладни заново (третья мода)
  for k, n in ipairs(hb.list) do n.k = k; local a, rr = k * 2.39996, SM.U * math.sqrt(k + SM.K0); n.ox, n.oy = rr * math.cos(a), rr * math.sin(a) end
  G.ver = G.ver + 1
end
-- 27 окт (9): лёгкая проверка изменений — обход дерева без узлов (только число и сумма путей): полный пересбор
-- 190 тыс. файлов каждый запуск сорил сотнями КБ за кадр и давал пики (17 fps). → true, когда готово (G.sig_n, G.sig_h)
function SM.sig_build(root, list_dir)
  return { stack = { root }, list_dir = list_dir, n = 0, h = 0, building = true }
end
function SM.sig_scan(S, budget)
  if not S.building then return true end
  local t0 = now()
  local st = S.stack
  while #st > 0 do
    local path = table.remove(st)
    for _, e in ipairs(S.list_dir(path, true)) do
      local p = (path == '/' and '' or path) .. '/' .. e.name
      if e.dir then st[#st + 1] = p
      else S.n = S.n + 1; S.h = (S.h + #p * 31 + p:byte(-1)) % 2147483647 end
    end
    if now() - t0 > budget then return false end
  end
  S.building = false
  return true
end
function SM.sig_of(G)
  local h = 0
  local L0 = G.raw or G.nodes
  for _, n in ipairs(L0) do h = (h + #n.path * 31 + n.path:byte(-1)) % 2147483647 end
  return #L0, h
end
-- одинаковы ли два набора файлов (проверка изменений): число и сумма путей
function SM.same_files(a, b)
  if #a.nodes ~= #b.nodes then return false end
  local sa, sb = 0, 0
  for _, n in ipairs(a.nodes) do sa = (sa + #n.path * 31 + n.path:byte(-1)) % 2147483647 end
  for _, n in ipairs(b.nodes) do sb = (sb + #n.path * 31 + n.path:byte(-1)) % 2147483647 end
  return sa == sb
end
-- 27 окт: граф из готового списка (db / proj / pm): files { path, name, sub } — sub — запасная группа
function SM.from_files(key, files)
  local G = { root = key, nodes = {}, hubs = {}, t = 0, temp = 0.12, ver = 0 }
  for _, f in ipairs(files) do
    if #G.nodes >= SM.LIMIT then break end
    G.nodes[#G.nodes + 1] = { path = f.path, name = f.name, cat = SM.cat_of(f.name, f.sub), src = true }
  end
  return SM.finish(G)
end
-- место файла в хабе: k-й по спирали Фибоначчи (диск без наложений, плотность ровная)
local function place(n, k)
  local a, rr = k * 2.39996, SM.U * math.sqrt(k + SM.K0)
  n.ox, n.oy = rr * math.cos(a), rr * math.sin(a)
end
-- 28 окт: фильтры карты (список слева снизу): по имени — всегда, по звуку — для проанализированных (этап 2)
SM.FILTERS = {
  { key = 'quiet', label = 'no quiet', test = function(n, a) return a and a.l < 0.08 end },
  { key = 'long', label = 'no long > 10s', test = function(n, a) return a and a.d and a.d > 10 end },
  { key = 'short', label = 'no short < 0.2s', test = function(n, a) return a and a.d and a.d < 0.2 end },
  { key = 'backup', label = 'no backup', test = function(n) local l = n.name:lower(); return l:find('backup', 1, true) or l:find('autosave', 1, true) end },
  { key = 'ir', label = 'no IR', test = function(n) local l = (n.path or n.name):lower(); return l:find('impulse', 1, true) or l:find('/irs?/') or l:find('%f[%a]ir%f[%A]') or l:find('cab', 1, true) end },
  { key = 'loops', label = 'no loops', test = function(n) return n.cat == 'loop' end },
}
SM.FON = {}
function SM.filtered_out(n)
  -- 28 окт: выбранные типы файлов (samples midi rex …) — фильтр списка; файлы из db / proj — без типа, не режутся
  if SM.TYPEON and not n.src then local t = SM.ext_type(n.name or ''); if t and not SM.TYPEON[t] then return true end end
  local a = SM.AN and SM.AN[n.path]
  for _, f in ipairs(SM.FILTERS) do if SM.FON[f.key] and f.test(n, a) then return true end end
  return false
end
function SM.finish(G)
  -- 28 окт: G.raw — весь список (индекс, проверка изменений), G.nodes — после фильтров
  G.raw = G.raw or G.nodes
  if next(SM.FON) or SM.TYPEON then
    local keep = {}
    for _, n in ipairs(G.raw) do if not SM.filtered_out(n) then keep[#keep + 1] = n end end
    G.nodes = keep
  else G.nodes = G.raw end
  G.hubs = {}
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
  for _ = 1, 150 do if not SM.step(G) then break end end   -- 27 окт (9): было 800 (151 группа — 9 млн пар, ~1 с замирания); дальше — по кадрам
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
  -- 27 окт (8): карточка не меньше cardz × 10 знаков (+ / - / колесо — размер), лишние ряды — прокруткой (Shift+колесо, j k)
  local top = y + L.rh + 4
  local minw = L.cw * 10 * (SM.cardz or 1.5)
  local cols = math.max(1, math.min(nh, math.floor(w / minw)))
  local rows = math.max(1, math.ceil(nh / cols))
  local cw = w / cols
  local ch = math.max(L.rh * 4, cw * 0.75)
  local maxs = math.max(0, rows * ch - (y + h - top))
  SM.cards_scroll = math.max(0, math.min(maxs, SM.cards_scroll or 0))
  return cols, rows, top - SM.cards_scroll, cw, ch, top
end
-- 27 окт (10): ФИГУРА ХЛАДНИ квадратной пластины: f(x,y) = Σ a_i · (cos(n_i πx) cos(m_i πy) − cos(m_i πx) cos(n_i πy)),
-- x, y ∈ [-1, 1]; узловые линии f = 0 — там песок (точки). 2-3 моды: (n1, m1) — от имени, (n2, m2) — от числа файлов
-- и разброса размеров, третья — от яркости (если группа проанализирована). Точки линии — пересечения знака на сетке 96×96
function SM.chladni_modes(hb)
  local sh = SM.card_shape(hb)
  local hsh = sh.hsh
  local n1 = 1 + hsh % 5; local m1 = n1 + 1 + (hsh // 5) % 3
  local n2 = 1 + math.floor(math.log(1 + hb.n) / math.log(3)) % 6; local m2 = n2 + 2
  local modes = { { n1, m1, 1 }, { n2, m2, 0.3 + sh.depth * 1.5 } }
  local sb, nb = 0, 0
  for i = 1, math.min(#hb.list, 200) do local a = SM.AN[hb.list[i].path]; if a then sb = sb + a.b; nb = nb + 1 end end
  if nb > 0 then local n3 = 2 + math.floor(sb / nb * 6); modes[3] = { n3, n3 + 3, 0.5 } end
  return modes
end
function SM.chladni(hb)
  local modes = SM.chladni_modes(hb)
  local N = 96
  local pi = math.pi
  local function f(x, y)
    local v = 0
    for _, m in ipairs(modes) do
      v = v + m[3] * (math.cos(m[1] * pi * x) * math.cos(m[2] * pi * y) - math.cos(m[2] * pi * x) * math.cos(m[1] * pi * y))
    end
    return v
  end
  local row, prev = {}, nil
  local pts = {}
  for j = 0, N do
    local y = -1 + 2 * j / N
    row = {}
    for i = 0, N do
      local x = -1 + 2 * i / N
      local v = f(x, y)
      row[i] = v
      if (i > 0 and (row[i - 1] < 0) ~= (v < 0)) or (prev and (prev[i] < 0) ~= (v < 0)) then pts[#pts + 1] = { x, y } end
    end
    prev = row
  end
  -- порядок обхода — вперемешку (детерминированно), чтобы малая группа покрывала всю фигуру, а не угол
  local step = 7919 % math.max(1, #pts)
  if step == 0 then step = 1 end
  local out, used, j = {}, {}, 1
  for _ = 1, #pts do
    while used[j] do j = j % #pts + 1 end
    used[j] = true; out[#out + 1] = pts[j]
    j = (j + step - 1) % #pts + 1
  end
  hb.chl = out
  return out
end
function SM.card_shape(hb)
  if hb.shape then return hb.shape end
  local hsh = 0
  for i = 1, #hb.name do hsh = (hsh * 31 + hb.name:byte(i)) % 1000003 end
  local mn, mxs, subs = math.huge, 0, {}
  for _, n in ipairs(hb.list) do
    local sz = n.size or 0
    mn, mxs = math.min(mn, sz), math.max(mxs, sz)
    if n.sub then subs[n.sub] = true end
  end
  local ns = 0; for _ in pairs(subs) do ns = ns + 1 end
  local var = (mxs > 0 and mn < math.huge) and math.min(1, math.log(1 + mxs / math.max(1, mn)) / 6) or 0.3
  local el = math.min(0.45, math.log(1 + hb.n) / 25)
  local rot = (ns * 0.7 + (hsh % 7) * 0.45)
  hb.shape = { hsh = hsh, lobes = 2 + hsh % 5, depth = 0.08 + 0.32 * var, phase = (hsh % 628) / 100,
               ax = 1 + el, ay = 1 - el * 0.8, c = math.cos(rot), s = math.sin(rot) }
  return hb.shape
end
function SM.draw_cards(U, L, G, x, y, w, h, V, playing, fit, col, mx, my, inside)
  local cols, rows, top, cw, ch, top0 = SM.neb_layout(G, x, y, w, h, L)
  -- 28 окт: карты ровно квадратные (сторона — меньшая из ширины / высоты ячейки), ряд — по центру
  do local sq = math.floor(math.min(cw, ch)); x = x + math.floor((cw - sq) * cols / 2); cw, ch = sq, sq end
  local hv, hd
  local rmax = math.max(2, math.min(7, math.min(cw, ch) * 0.03)) * (0.4 + 1.6 * (V.dim or 0.5))
  local spread = 0.95 - 0.45 * (V.grav or 0.5)
  local function pos(n)
    local hb = n.h
    local i = hb.cell - 1
    local qx0, qy0 = x + (i % cols) * cw, top + math.floor(i / cols) * ch
    -- 27 окт (10): фигура Хладни — точки на узловых линиях пластины (SM.chladni), моды — из содержимого группы
    local pts = hb.chl or SM.chladni(hb)
    local np = #pts
    local qx, qy
    if np > 0 then
      local j = (hb.n <= np) and (math.floor((n.k - 1) * np / hb.n) + 1) or ((n.k - 1) % np + 1)
      local pt = pts[j]
      qx, qy = pt[1] * spread, pt[2] * spread   -- больше файлов, чем точек линии, — на тех же точках (линии остаются линиями)
    else
      local rr, a = math.sqrt((n.k - 0.5) / hb.n) * spread, n.k * 2.39996
      qx, qy = rr * math.cos(a), rr * math.sin(a)
    end
    local m = math.max(5, math.floor(math.min(cw - 8, ch - 6) * 0.08)) + 6
    return qx0 + cw / 2 + qx * (cw / 2 - 4 - m), qy0 + ch / 2 + qy * (ch / 2 - 3 - m - L.rh)
  end
  -- точки — в буфер, пока вид тот же
  -- 27 окт (10): игральная карта: светлая карта со скруглёнными углами, рубашка — рамка с фигурой Хладни внутри
  local function card(ox, oy, hb)
    local i = hb.cell - 1
    local qx0, qy0 = x + (i % cols) * cw - ox, top + math.floor(i / cols) * ch - oy
    local c = col(hb)
    local bx0, by0, bw, bh = math.floor(qx0 + 4), math.floor(qy0 + 3), math.floor(cw - 8), math.floor(ch - 6)
    local face = U.mix(U.PANEL, U.TEXT, 0.06)
    U.set(face); gfx.rect(bx0, by0, bw, bh, 1)   -- 28 окт: прямые углы (без скруглений — проще и быстрее)
    U.set(U.mix(c, U.BG, 0.3)); gfx.rect(bx0, by0, bw, bh, 0)
    -- рамка рубашки (двойная тонкая), внутри — фигура
    local m = math.max(5, math.floor(math.min(bw, bh) * 0.08))
    U.set(U.mix(c, face, 0.45)); gfx.rect(bx0 + m, by0 + m + L.rh, bw - 2 * m, bh - 2 * m - 2 * L.rh, 0)
    U.set(U.mix(c, face, 0.7)); gfx.rect(bx0 + m + 2, by0 + m + L.rh + 2, bw - 2 * m - 4, bh - 2 * m - 2 * L.rh - 4, 0)
  end
  local function dots(ox, oy)
    for _, hb in ipairs(G.hubs) do card(ox, oy, hb) end
    for _, hb in ipairs(G.hubs) do
      local c = col(hb)
      U.set(U.mix(c, U.TEXT, 0.15), 0.85)
      -- 27 окт (10): точки не толще шага сетки фигуры — иначе узловые линии сливаются в сплошной прямоугольник
      local rcap = math.max(1, cw / 220)
      for _, n in ipairs(hb.list) do
        local px, py = pos(n)
        local r = math.min(n.r * rmax, rcap)
        if r < 1.5 then gfx.rect(px - ox, py - oy, 2, 2, 1) else gfx.circle(px - ox, py - oy, r, 1, 1) end
      end
    end
    gfx.a = 1
  end
  SM.buffered(G, ('cards|%d|%d|%d|%d|%.3f|%.3f|%d|%.1f|%.2f'):format(x, y, w, h, V.dim or 0.5, V.grav or 0.5, G.ver, cw, SM.cards_scroll or 0), x, y, w, h, U, function() dots(x, y) end)
  for _, hb in ipairs(G.hubs) do
    local i = hb.cell - 1
    local qx0, qy0 = x + (i % cols) * cw, top + math.floor(i / cols) * ch
    if qy0 + ch < top0 or qy0 + ch > y + h + 2 then goto next_card end   -- 27 окт: только целые карточки (подпись нижней лезла на плеер)
    local c = col(hb)
    -- 27 окт (10): индексы игральной карты — имя группы слева сверху, число файлов справа снизу (цвет группы)
    local bx0, by0, bx1, by1 = math.floor(qx0 + 4), math.floor(qy0 + 3), math.floor(qx0 + cw - 4), math.floor(qy0 + ch - 3)
    local room = bx1 - bx0 - 8
    U.text(bx0 + 4, by0 + 2, fit(SM.short(hb.name, math.max(3, math.floor(room / math.max(1, U.measure('M'))))):upper(), room), c)
    local cnt = tostring(hb.n)
    U.text(bx1 - 4 - U.measure(cnt), by1 - L.rh - 1, cnt, U.mix(c, U.BG, 0.2))
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
    ::next_card::
  end
  local pn = playing and G.bypath and G.bypath[playing]
  if pn then local px, py = pos(pn); if py >= top0 and py < y + h then U.set(U.AMBER); gfx.circle(px, py, math.max(2, pn.r * rmax) + 1, 1, 1) end end
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
  for _, hb in ipairs(G.hubs) do for j, st in ipairs(hb.stars) do st.n = hb.list[j]; if st.n then st.n.star = st end end end
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
  -- 28 окт: справа сверху — вся галактика мелко, сектор этой системы подсвечен; щелчок — назад
  if G.gal then
    local mw = math.min(math.floor(w * 0.22), L.cw * 24)
    local mh = math.floor(mw * 0.8)
    local mx0, my0 = x + w - mw - 6, top + 2
    U.set(U.BG); gfx.rect(mx0, my0, mw, mh, 1)
    U.set(U.LINE); gfx.rect(mx0, my0, mw, mh, 0)
    local function MX(v) return mx0 + (v + 1.05) / 2.1 * mw end
    local function MY(v) return my0 + (v + 0.85) / 1.7 * mh end
    for _, h2 in ipairs(G.hubs) do
      local rc = h2.rect
      if rc then
        local on = h2 == hb
        U.set(on and U.AMBER or U.mix(col(h2), U.BG, 0.55))
        gfx.rect(math.floor(MX(rc[1])), math.floor(MY(rc[2])), math.max(1, math.floor(MX(rc[3]) - MX(rc[1]))), math.max(1, math.floor(MY(rc[4]) - MY(rc[2]))), on and 1 or 0)
      end
    end
    if inside and mx >= mx0 and mx < mx0 + mw and my >= my0 and my < my0 + mh then hv = { back = true } end
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
  SM.hist_path(U, G, V, function(nd) if nd.h == hb then return pos(nd) end end, col)
  for _, e in ipairs(V.hist or {}) do
    local nd = G.bypath and G.bypath[e.path]
    local age = nd and nd.h == hb and SM.fresh(V, nd)
    if age and V.hist_by[e.path] == e then local px, py = pos(nd); U.set(SM.fresh_col(U, c, age)); gfx.circle(px, py, age == 0 and 4 or 3, 1, 1) end
  end
  if hv and hv.node then U.set(U.TEXT); gfx.circle(hv.px, hv.py, 5, 0, 1) end
  return hv
end
-- 27 окт (5): свежесть прослушивания: 0 — только что (ярко), 1..10 — сразу тёмная, 11..20 — светлеет к обычной
SM.DARK, SM.RECOVER = 10, 10
function SM.fresh(V, n)
  if not (V.hist and n) then return nil end
  local e = V.hist_by and V.hist_by[n.path]
  if not e then return nil end
  local age = (V.step or 0) - e.step
  if age > SM.DARK + SM.RECOVER then return nil end
  return age
end
-- линия по последним прослушанным (до DARK + RECOVER шагов): xy(nd) → экранные x, y или nil (точки не видно)
function SM.hist_path(U, G, V, xy, col)
  local hist = V.hist or {}
  local win = SM.DARK + SM.RECOVER
  local px, py
  for i, e in ipairs(hist) do
    local age = (V.step or 0) - e.step
    if age > win then break end
    local nd = G.bypath and G.bypath[e.path]
    local x, y
    if nd then x, y = xy(nd) end
    if x and px then
      local t = math.min(1, age / math.max(1, win))
      U.set(i == 2 and U.AMBER or U.mix(U.AMBER, U.BG, 0.35 + 0.55 * t))
      gfx.line(px, py, x, y, 1)
      if i == 2 then gfx.line(px + 1, py, x + 1, y, 1) end
    end
    if x then px, py = x, y end
  end
end
-- цвет точки по свежести: c — обычный цвет группы
function SM.fresh_col(U, c, age)
  if age == 0 then return U.AMBER end
  -- 28 окт: хвост — свежие светлые, давние гаснут к обычному цвету (было: сразу тёмные, потом светлели)
  local t = math.min(1, age / math.max(1, SM.DARK + SM.RECOVER))
  return U.mix(U.mix(c, U.TEXT, 0.6), c, t)
end
-- панель истории справа: проигранные файлы, новое сверху, цвет — свежесть; → hover { hist = i }
function SM.hist_panel(U, L, V, x, y, w, h, fit, mx, my, inside)
  U.set(U.PANEL); gfx.rect(x, y, w, h, 1)
  U.set(U.mix(U.LINE, U.TEXT, 0.35)); gfx.rect(x, y, 1, h, 1)
  U.text(x + L.pad, y + 1, fit('history', w - 2 * L.pad), V.zone == 'hist' and U.AMBER or U.GREY)
  local hv
  do   -- 27 окт (8): print — впечатать проигранное в трекер
    local bw = U.measure('print') + 2 * L.pad
    local bx = x + w - bw - 2
    if bx > x + U.measure('history ') and #(V.hist or {}) > 0 then
      local hot = inside and mx >= bx and mx < bx + bw and my >= y + 1 and my < y + 1 + L.rh
      U.set(hot and U.tint(U.AMBER, 0.3) or U.BG); gfx.rect(bx, y + 1, bw, L.rh - 1, 1)
      U.set(hot and U.AMBER or U.LINE); gfx.rect(bx, y + 1, bw, L.rh - 1, 0)
      U.text(bx + L.pad, y + 1, 'print', hot and U.AMBER or U.TEXT)
      if hot then hv = { hprint = true } end
    end
  end
  local n = math.floor((h - L.rh - 2) / L.rh)
  for i = 1, math.min(n, #(V.hist or {})) do
    local e = V.hist[i]
    local ry = y + L.rh + 2 + (i - 1) * L.rh
    local age = (V.step or 0) - e.step
    local hot = inside and mx >= x and mx < x + w and my >= ry and my < ry + L.rh
    if hot then U.set(U.tint(U.AMBER, 0.2)); gfx.rect(x + 1, ry, w - 1, L.rh, 1); hv = { hist = i }
    elseif V.zone == 'hist' and V.hcur == i then U.set(U.tint(U.AMBER, 0.3)); gfx.rect(x + 1, ry, w - 1, L.rh, 1) end
    local c = age == 0 and U.AMBER or (age <= SM.DARK and U.mix(U.TEXT, U.BG, 0.55) or U.GREY)
    U.text(x + L.pad, ry, fit((e.name:gsub('%.[%w]+$', '')), w - 2 * L.pad), hot and U.TEXT or c)
  end
  if not V.hist or #V.hist == 0 then U.text(x + L.pad, y + L.rh + 2, fit('played files land here', w - 2 * L.pad), U.DIM) end
  return hv
end
function SM.draw_nebula(U, L, G, x, y, w, h, V, playing, fit, col, mx, my, inside)
  -- 27 окт (7): панель history / marked — у браузера справа от карты во всех видах (B.map_side)
  return SM.draw_nebula2(U, L, G, x, y, w, h, V, playing, fit, col, mx, my, inside)
end
function SM.draw_nebula2(U, L, G, x, y, w, h, V, playing, fit, col, mx, my, inside)
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
        local lab = ('%s %d'):format(SM.short(hb.name, math.max(3, math.floor((cx1 - cx0 - 6) / math.max(1, U.measure('M'))) - 5)):upper(), hb.n)
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
  -- 27 окт (6): путь прослушанного — линия от точки к точке (новый отрезок ярче, старые бледнеют)
  SM.hist_path(U, G, V, function(nd) if nd.star then return X(nd.star.x), Y(nd.star.y) end end, col)
  -- 27 окт (5): прослушанные — по свежести (только что — ярко, потом тёмные 10 шагов, потом светлеют); поверх буфера
  for _, e in ipairs(V.hist or {}) do
    local nd = G.bypath and G.bypath[e.path]
    local age = SM.fresh(V, nd)
    if age and nd.star and V.hist_by[e.path] == e then
      U.set(SM.fresh_col(U, col(nd.h), age)); gfx.circle(X(nd.star.x), Y(nd.star.y), age == 0 and 3.5 or 2, 1, 1)
    end
  end
  if hv and hv.node then U.set(U.TEXT); gfx.circle(hv.px, hv.py, 4, 0, 1) end
  return hv
end


-- ── 27 окт (10): вид TREE — дерево папок: ствол слева, ветви — папки (глубже 5 — в предка), листья-точки — файлы
-- на веточке своей папки; классы (db / proj / pm без папок) — ветви по группе
SM.TREE_DEPTH = 5
function SM.tree_build(G)
  if G.tree then return G.tree end
  local root
  for _, n in ipairs(G.nodes) do
    local d = n.dir or ''
    if not root or #d < #root then root = d end
  end
  root = root or ''
  local T = { name = '/', kids = {}, files = {}, n = 0, depth = 0 }
  local by = { [''] = T }
  local function node(rel)
    if by[rel] then return by[rel] end
    local parent, nm = rel:match('^(.*)/([^/]+)$')
    if not parent then parent, nm = '', rel end
    local pn = node(parent)
    local t = { name = nm, kids = {}, files = {}, n = 0, depth = pn.depth + 1, parent = pn }
    pn.kids[#pn.kids + 1] = t
    by[rel] = t
    return t
  end
  for _, n in ipairs(G.nodes) do
    local rel
    if n.dir then
      rel = (n.dir:sub(1, #root) == root) and n.dir:sub(#root + 2) or n.dir
      local parts, k = {}, 0
      for p in rel:gmatch('[^/]+') do k = k + 1; if k <= SM.TREE_DEPTH then parts[#parts + 1] = p end end
      rel = table.concat(parts, '/')
    else rel = (n.cat or 'other'):gsub('^/', '') end
    local t = node(rel)
    t.files[#t.files + 1] = n
    n.tnode, n.ti = t, #t.files   -- 27 окт: для сыгранных — без обхода всех файлов
  end
  local function weigh(t) local w = #t.files; for _, c in ipairs(t.kids) do w = w + weigh(c) end; t.n = w; table.sort(t.kids, function(a, b) return a.n > b.n end); return w end
  weigh(T)
  G.tree = T
  return T
end
function SM.draw_tree(U, L, G, x, y, w, h, V, playing, fit, col, mx, my, inside)
  local T = SM.tree_build(G)
  local top = y + L.rh + 4
  local zoom = V.zoom or 1
  local H = (y + h - top - 4) * zoom
  if not T.maxd then local m = 0; local function md(t) if t.depth > m then m = t.depth end; for _, c in ipairs(t.kids) do md(c) end end; md(T); T.maxd = m end
  local dx = math.max(L.cw * 6, (w - L.cw * 18) / math.max(1, T.maxd + 1)) * math.min(2, zoom)
  local ox, oy = x + L.pad + (V.px or 0), top + (V.py or 0)
  -- 27 окт: раскладка — только когда меняется вид (было каждый кадр: 6700 папок + 188 тыс. файлов = 38 мс)
  local lkey = ('%d|%d|%d|%d|%.3f|%.1f|%.1f'):format(x, y, w, h, zoom, V.px or 0, V.py or 0)
  local lay = T.lay
  if T.lkey ~= lkey then
    lay = {}
    local function place(t, y0, y1)
      t.ty0, t.ty1 = y0, y1
      t.tx, t.ty = ox + t.depth * dx, (y0 + y1) / 2
      lay[#lay + 1] = t
      local acc = y0 + (y1 - y0) * #t.files / math.max(1, t.n)   -- свои листья — сверху полосы
      for _, c in ipairs(t.kids) do
        local hh = (y1 - y0) * c.n / math.max(1, t.n)
        place(c, acc, acc + hh); acc = acc + hh
      end
    end
    place(T, oy, oy + H)
    -- подписи: только ветви с полосой хотя бы в строку, крупные первыми
    local order = {}
    for _, t in ipairs(lay) do if t.depth > 0 and t.ty1 - t.ty0 >= L.rh * 0.8 and t.ty >= top + L.rh and t.ty < y + h then order[#order + 1] = t end end
    table.sort(order, function(a, b) return a.n > b.n end)
    T.lay, T.lkey, T.order = lay, lkey, order
  end
  local function hubcol(t) local n = t.files[1]; if not n then for _, c in ipairs(t.kids) do if c.files[1] then n = c.files[1]; break end end end; return n and col(n.h) or U.GREY end
  -- листья: веточка вправо от узла, точки на ней (не длиннее 0.8 шага; больше — рядами в своей полосе)
  local function leafpos(t, i)
    local cnt = #t.files
    local per = math.max(1, math.floor(dx * 0.8 / 4))
    local row, k = (i - 1) // per, (i - 1) % per
    local rows = math.max(1, math.ceil(cnt / per))
    local band = (#t.kids == 0) and 1 or (#t.files / math.max(1, t.n))
    return t.tx + 6 + k * 4, t.ty0 + (t.ty1 - t.ty0) * band * ((row + 0.5) / rows)
  end
  local function paint()
    for _, t in ipairs(lay) do
      if t.ty1 >= top and t.ty0 <= y + h then
        local c = hubcol(t)
        if t.parent then   -- ветвь уголком: от родителя вправо, вниз / вверх, к узлу
          local px, py = t.parent.tx, t.parent.ty
          local mxx = px + dx * 0.5
          U.set(U.mix(c, U.BG, 0.45))
          gfx.line(px - x, py - y, mxx - x, py - y, 1); gfx.line(mxx - x, py - y, mxx - x, t.ty - y, 1); gfx.line(mxx - x, t.ty - y, t.tx - x, t.ty - y, 1)
        end
        if #t.files > 0 and t.ty1 - t.ty0 >= 1 then
          U.set(U.mix(c, U.TEXT, 0.2))
          for i = 1, #t.files do
            local lx, ly = leafpos(t, i)
            if ly >= top and ly < y + h then gfx.rect(lx - x, ly - y, 2, 2, 1) end
          end
        end
      end
    end
  end
  SM.buffered(G, ('tree|%d|%d|%d|%d|%.3f|%.1f|%.1f|%d'):format(x, y, w, h, zoom, V.px or 0, V.py or 0, G.ver), x, y, w, h, U, paint)
  local hv, hd
  local placed = {}
  for _, t in ipairs(T.order) do
    do
      local lab = SM.short(t.name, math.max(3, math.floor(dx / math.max(1, L.cw)) - 1)) .. ((t.ty1 - t.ty0 > 2 * L.rh) and (' ' .. t.n) or '')
      local lw = U.measure(lab)
      local lx, ly = t.tx - lw - 2, t.ty - L.rh
      local free = t.ty1 - t.ty0 >= L.rh * 0.8 and lx > x
      if free then for _, q in ipairs(placed) do if lx < q[1] + q[3] and q[1] < lx + lw and ly < q[2] + L.rh and q[2] < ly + L.rh then free = false; break end end end
      if free then
        placed[#placed + 1] = { lx, ly, lw }
        U.set(hubcol(t)); gfx.rect(lx - 1, ly, lw + 2, L.rh, 1); U.text(lx, ly, lab, U.BG)   -- инверсно, как у групп
      end
    end
  end
  -- наведение: ветвь под мышью — двоичный поиск нет смысла, но только листья ветвей, чья полоса под мышью
  if inside then
    for _, t in ipairs(lay) do
      if my >= t.ty0 and my < t.ty1 and mx >= t.tx and mx < t.tx + dx and #t.files > 0 then
        for i = 1, #t.files do
          local lx, ly = leafpos(t, i)
          local d = (mx - lx) ^ 2 + (my - ly) ^ 2
          if d < 30 and (not hd or d < hd) then hv, hd = { node = t.files[i], px = lx, py = ly, r = 2 }, d end
        end
      end
    end
  end
  -- сыгранные — по свежести, как в других видах (только файлы истории)
  local pos = {}
  for _, e in ipairs(V.hist or {}) do
    local n = G.bypath and G.bypath[e.path]
    if n and n.tnode then local lx, ly = leafpos(n.tnode, n.ti); pos[n] = { lx, ly } end
  end
  SM.hist_path(U, G, V, function(nd) local p0 = pos[nd]; if p0 then return p0[1], p0[2] end end, col)
  for n, p0 in pairs(pos) do local age = SM.fresh(V, n); if age then U.set(SM.fresh_col(U, col(n.h), age)); gfx.circle(p0[1], p0[2], age == 0 and 3 or 2, 1, 1) end end
  if hv and hv.node then U.set(U.TEXT); gfx.circle(hv.px, hv.py, 4, 0, 1) end
  return hv
end


-- ── 27 окт (10): вид SAND — каждый файл песчинка: ниже частота — крупнее и темнее, короче — мельче и ярче
-- (этап 2: SM.AN b — яркость, d — длина; не проанализирован — средняя тусклая). Кучки — места групп из раскладки
-- графа, радиус по логарифму числа файлов (папка киков не размером с солнце), песчинки — спиралью по яркости
function SM.sand_grain(n)
  local a = SM.AN[n.path]
  if not a then return 1.2, nil, 0.75 end
  local low = 1 - (a.b or 0.5)                                   -- 1 — низ, 0 — верх
  local short = a.d and math.max(0, math.min(1, 1 - math.log(1 + a.d) / math.log(1 + 8))) or 0.5   -- 1 — короткий
  local size = 0.8 + 3.2 * low * (1 - 0.6 * short)                -- низкие крупнее, короткие мельче
  local dark = 0.15 + 0.55 * low - 0.35 * short                   -- низкие темнее, короткие ярче
  return size, a, math.max(0, math.min(0.85, dark))
end
function SM.draw_sand(U, L, G, x, y, w, h, V, playing, fit, col, mx, my, inside)
  local top = y + L.rh + 4
  local hs = G.hubs
  local x0, x1, y0, y1 = math.huge, -math.huge, math.huge, -math.huge
  for _, hb in ipairs(hs) do x0, x1, y0, y1 = math.min(x0, hb.x), math.max(x1, hb.x), math.min(y0, hb.y), math.max(y1, hb.y) end
  local ox, oy = (x0 + x1) / 2, (y0 + y1) / 2
  local sc = math.min(0.42 * w / math.max(0.05, (x1 - x0) / 2), 0.42 * (y + h - top) / math.max(0.05, (y1 - y0) / 2)) * (V.zoom or 1)
  local cx, cy = x + w / 2 + (V.px or 0), top + (y + h - top) / 2 + (V.py or 0)
  local base = math.max(6, math.min(w, h) * 0.018) * (V.zoom or 1)
  local function R(hb) return base * (1 + math.log(hb.n, 10)) end   -- 1 файл — base, 10 — 2·base, 10 000 — 5·base
  local function HX(hb) return cx + (hb.x - ox) * sc end
  local function HY(hb) return cy + (hb.y - oy) * sc end
  local function gpos(hb, n)
    local k = n.k
    local rr = math.sqrt((k - 0.5) / hb.n) * R(hb)
    local a = k * 2.39996
    return HX(hb) + rr * math.cos(a), HY(hb) + rr * math.sin(a)
  end
  local function paint()
    for _, hb in ipairs(hs) do
      local c = col(hb)
      for _, n in ipairs(hb.list) do
        local px, py = gpos(hb, n)
        if px >= x and px < x + w and py >= top and py < y + h then
          local sz, _, dark = SM.sand_grain(n)
          U.set(U.mix(U.mix(c, U.TEXT, 0.3), U.BG, dark))
          if sz < 1.5 then gfx.rect(px - x, py - y, 1, 1, 1) else gfx.circle(px - x, py - y, sz * 0.5, 1, 1) end
        end
      end
    end
  end
  -- 28 окт: перерисовка буфера — по смене вида и раз в 2 с при новых анализах (было: каждый кадр, пока шёл анализ — 20 тыс. песчинок)
  local now0 = reaper and reaper.time_precise and reaper.time_precise() or os.clock()   -- R здесь — радиус кучки
  if (SM.an_n or 0) ~= (G.sand_an or 0) and now0 - (G.sand_t or 0) > 2 then G.sand_an, G.sand_t = SM.an_n or 0, now0 end
  SM.buffered(G, ('sand|%d|%d|%d|%d|%.4f|%.1f|%.1f|%d|%d'):format(x, y, w, h, sc, cx, cy, G.ver, G.sand_an or 0), x, y, w, h, U, paint)
  -- подписи кучек (крупные первыми, без наложений), наведение — ближайшая песчинка в кучке под мышью
  local hv, hd
  local placed = {}
  G.lab_order = G.lab_order or (function() local t = {}; for i, hb in ipairs(hs) do t[i] = hb end; table.sort(t, function(a, b) return a.n > b.n end); return t end)()
  for _, hb in ipairs(G.lab_order) do
    local nx, ny, r = HX(hb), HY(hb), R(hb)
    if r > 10 and nx >= x and nx < x + w and ny - r - L.rh >= top and ny < y + h then
      local lab = SM.short(hb.name, math.max(3, math.floor(r * 2 / math.max(1, L.cw)))) .. ' ' .. hb.n
      local lw = U.measure(lab)
      local lx, ly = nx - lw / 2, ny - r - L.rh - 1
      local free = true
      for _, q in ipairs(placed) do if lx < q[1] + q[3] and q[1] < lx + lw and ly < q[2] + L.rh and q[2] < ly + L.rh then free = false; break end end
      if free then placed[#placed + 1] = { lx, ly, lw }; U.set(col(hb)); gfx.rect(lx - 1, ly, lw + 2, L.rh, 1); U.text(lx, ly, lab, U.BG) end
    end
    if inside and not hv and (mx - nx) ^ 2 + (my - ny) ^ 2 <= (r + 4) ^ 2 then
      for _, n in ipairs(hb.list) do
        local px, py = gpos(hb, n)
        local d = (mx - px) ^ 2 + (my - py) ^ 2
        if d < 25 and (not hd or d < hd) then hv, hd = { node = n, px = px, py = py, r = 2 }, d end
      end
      if not hv then hv = { hub = hb } end
    end
  end
  SM.hist_path(U, G, V, function(nd) return gpos(nd.h, nd) end, col)
  for _, e in ipairs(V.hist or {}) do
    local nd = G.bypath and G.bypath[e.path]
    local age = SM.fresh(V, nd)
    if age and V.hist_by[e.path] == e then local px, py = gpos(nd.h, nd); U.set(SM.fresh_col(U, col(nd.h), age)); gfx.circle(px, py, age == 0 and 3 or 2, 1, 1) end
  end
  if hv and hv.node then
    U.set(U.TEXT); gfx.circle(hv.px, hv.py, 4, 0, 1)
    local a = SM.AN[hv.node.path]
    if a then hv.info = ('loud %.0f%%  bright %.0f%%%s'):format(a.l * 100, a.b * 100, a.d and ('  %.2fs'):format(a.d) or '') end
  end
  return hv
end

-- точки в свой буфер: перерисовка, только когда меняется ключ вида; иначе — копия буфера
function SM.buffered(G, key, x, y, w, h, U, paint)
  w, h = math.max(1, math.floor(w)), math.max(1, math.floor(h))
  if G.bkey ~= key or SM.bowner ~= G then SM.repaints = (SM.repaints or 0) + 1; SM.last_bkey = key
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
-- 28 окт: высота полосы опций — строки фильтров (перенос по ширине) + типы + ползунки
function SM.opts_h(U, L, w)
  local rows, fx = 1, 0
  for _, f in ipairs(SM.FILTERS) do
    local tw = U.measure(f.label) + 2 * L.pad + 2
    if fx + tw > w - 2 * L.pad and fx > 0 then rows, fx = rows + 1, 0 end
    fx = fx + tw
  end
  return (rows + 2) * L.rh + 3
end
function SM.draw(U, L, G, x, y, w, h, V, playing, fit)
  V.hist_by = {}
  for _, e in ipairs(V.hist or {}) do if not V.hist_by[e.path] then V.hist_by[e.path] = e end end
  -- 28 окт: обход / чтение индекса — фоном в тике main (SM.bg = true), не в отрисовке: кадр карты рисуется реже (кэш)
  if G.building and not SM.bg then SM.scan(G, SM.SCAN_S) end
  if not G.building and not SM.bg then SM.size_tick(G, SM.SCAN_S) end
  G.grav = V.grav
  -- 28 окт: опции карты — своя полоса сверху модуля (не поверх вида): фильтры, типы, gravity / dimension
  local oy0, oh = y, SM.opts_h(U, L, w)
  if h > oh + 6 * L.rh then y, h = y + oh, h - oh else oh = 0 end
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
  elseif V.style == 'sand' then
    hv = SM.draw_sand(U, L, G, x, y, w, h, V, playing, fit, col, mx, my, inside)
  elseif V.style == 'tree' and SM.TREE_ON then   -- 27 окт: скрыт; SM.TREE_ON = true — вернуть
    hv = SM.draw_tree(U, L, G, x, y, w, h, V, playing, fit, col, mx, my, inside)
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
        -- 27 окт (8): точки гуще 3 px — группа одним залитым диском (узоры муара не мешают читать)
        if SM.U * sc < 3 then
          U.set(U.mix(c, U.BG, 0.35)); gfx.circle(hx, hy, math.max(1.5, hb.R * sc), 1, 1)
          goto next_hub
        end
        U.set(U.mix(c, U.TEXT, 0.25))
        for _, n in ipairs(hb.list) do
          local px, py = hx + n.ox * sc, hy + n.oy * sc
          local an = SM.AN[n.path]
          -- этап 2: проанализирован — размер по громкости, dimension раздувает яркие (покрытие спектра)
          local r = an and (0.3 + 0.7 * an.l) * (1 + (V.dim or 0.5) * 1.5 * an.b) * rmax * 0.7 or n.r * rmax
          if px >= -r and px < w + r and py >= -r and py < h + r then
            if r < 1.5 then gfx.rect(px, py, r < 0.9 and 1 or 2, r < 0.9 and 1 or 2, 1) else gfx.circle(px, py, r, 1, 1) end
          end
        end
        ::next_hub::
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
        -- 27 окт (8): подпись по масштабу: диск мелкий — без подписи, дальше — короче (главные слова), ближе — полностью
        local rpx = hb.R * sc
        local maxch = math.floor(math.max(0, math.min(60, rpx * 2.2 / math.max(1, L.cw))))
        local lab = (hot or maxch >= 4) and (SM.short(hb.name, hot and 60 or maxch) .. ((hot or rpx > 40) and (' ' .. hb.n) or '')) or nil
        local lx, ly = nx + r + 2, ny - L.rh / 2
        local room = x + w - lx - 2
        local lw = lab and math.min(room, U.measure(lab)) or 0
        if lab and room > U.measure('mm') and ly >= y + L.rh and (hot or free(lx, ly, lw, L.rh)) then
          placed[#placed + 1] = { lx, ly, lw, L.rh }
          U.set(col(hb)); gfx.rect(lx - 1, ly, lw + 2, L.rh, 1)   -- 27 окт (8): инверсно — цвет группы подложкой, буквы фоном
          U.text(lx, ly, fit(lab, room), U.BG)
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
  -- 28 окт: полоса опций сверху (oy0 .. oy0 + oh): строки фильтров, строка типов, ползунки в одну строку
  if oh > 0 then
    U.set(U.PANEL); gfx.rect(x, oy0, w, oh, 1)
    U.set(U.LINE); gfx.rect(x, oy0 + oh - 1, w, 1, 1)
    local function btn(bx, by, lab, on, key, val)
      local tw = U.measure(lab) + 2 * L.pad
      local hot = mx >= bx and mx < bx + tw and my >= by and my < by + L.rh
      U.set(hot and U.tint(U.AMBER, 0.3) or (on and U.tint(U.AMBER, 0.15) or U.PANEL)); gfx.rect(bx, by, tw, L.rh - 1, 1)
      U.set(on and U.AMBER or U.LINE); gfx.rect(bx, by, tw, L.rh - 1, 0)
      U.text(bx + L.pad, by, lab, on and U.AMBER or (hot and U.TEXT or U.GREY))
      if hot then hv = { [key] = val } end
      return tw
    end
    local fy, fx = oy0 + 1, x + L.pad
    for _, f in ipairs(SM.FILTERS) do
      local tw = U.measure(f.label) + 2 * L.pad
      if fx + tw > x + w - L.pad and fx > x + L.pad then fy, fx = fy + L.rh, x + L.pad end
      fx = fx + btn(fx, fy, f.label, SM.FON[f.key], 'mfilter', f.key) + 2
    end
    fy, fx = fy + L.rh, x + L.pad
    for _, t in ipairs(SM.TYPES) do fx = fx + btn(fx, fy, t, V.types and V.types[t], 'mtype', t) + 2 end
    fy = fy + L.rh
    local sw = math.max(L.cw * 4, math.min(L.cw * 10, math.floor((w - 2 * L.pad) / 2) - U.measure('dimension ') - L.pad))
    local sx0 = x + L.pad
    for _, sl in ipairs({ { 'gravity', 'grav' }, { 'dimension', 'dim' } }) do
      local lw = U.measure(sl[1] .. ' ')
      local sx = sx0 + lw
      local v = V[sl[2]] or 0.5
      local hot = mx >= sx0 and mx < sx + sw and my >= fy and my < fy + L.rh
      U.text(sx0, fy, sl[1], hot and U.AMBER or U.GREY)
      U.set(U.DIM); gfx.rect(sx, fy + math.floor(L.rh / 2) - 1, sw, 2, 1)
      U.set(hot and U.AMBER or U.TEXT); gfx.rect(sx, fy + 3, math.max(1, math.floor(sw * v + 0.5)), L.rh - 6, 1)
      if hot then hv = { slider = sl[2], x = sx, w = sw } end
      sx0 = sx + sw + 2 * L.pad
    end
  end
  -- 27 окт: кнопка вида: graph / nebula (два положения) и счёт; текст — до ползунков
  do
    local info = ('%d files, %d groups%s%s'):format(#G.nodes, #G.hubs, G.szi and ' - sizes...' or '', (SM.an_n or 0) > 0 and ('  ~%d heard' ):format(SM.an_n) or '')
    -- 27 окт (2): вид — три вкладки (не кнопка с тремя положениями); random — случайный сэмпл (сектор под мышью / все)
    local bx, by = x + L.pad, y + 2
    local cur = V.style or 'graph'
    local bw = 0
    for _, nm in ipairs({ 'graph', 'cards', 'nebula', 'sand', 'ξ' }) do   -- 27 окт: tree скрыт (пользователь: «жесть»), код SM.draw_tree остаётся   -- ξ — случайная величина: случайный сэмпл
      local tw = U.measure(nm) + 2 * L.pad
      local on = nm == cur
      local hot = mx >= bx and mx < bx + tw and my >= by and my < by + L.rh
      U.set(hot and U.tint(U.AMBER, 0.3) or (on and U.tint(U.AMBER, 0.15) or U.BG)); gfx.rect(bx, by, tw, L.rh - 1, 1)
      U.set((hot or on) and U.AMBER or U.LINE); gfx.rect(bx, by, tw, L.rh - 1, 0)
      U.text(bx + L.pad, by, nm, (hot or on) and U.AMBER or U.TEXT)
      if hot then hv = nm == 'ξ' and { random = true } or { style = nm } end
      bx = bx + tw + 2
    end
    bx = bx - bw
    local room = (x + w) - (bx + L.pad) - L.pad
    if room > U.measure('mm') then
      U.set(U.BG); gfx.rect(bx + L.pad, y + 2, math.min(room, U.measure(info)), L.rh - 1, 1)
      U.text(bx + L.pad, y + 2, fit(info, room), U.GREY)
    end
  end
  return hv
end

return SM
