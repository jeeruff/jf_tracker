-- jf_tracker_fxbrowser.lua — браузер эффектов слева от DSP-панели (2 окт).
--
-- Продолжение левой колонки (под матрицей): строка поиска и список
-- установленных FX (EnumInstalledFX, список даёт main). Набор текста — fzf
-- (термы через пробел, буквы по порядку, бонус за начало слова и подряд;
-- 'точно, ^начало, конец$, !исключить). Стрелки / Ctrl+J Ctrl+K — курсор,
-- Enter — добавить FX в конец цепочки трека курсора, мышь: двойной клик —
-- добавить, перетащить на DSP-панель — вставить в место под индикатором.
-- Esc — очистить поиск, второй Esc / Tab — дальше.
--
-- Без reaper.*: тестируется стабами.

-- Папки (3 окт, как нативный браузер): all, fav (избранное REAPER — папка
-- Favorites в reaper-fxfolders.ini — плюс своё, кнопка *), dev / type / cat
-- (разработчик и категория из reaper-fxtags.ini, тип по префиксу VST3: / AU: …)
-- с заголовками групп, rec — недавно добавленные. Данные из ini читает main
-- (FB.set_tags). Набор текста в фокусе — браузер раскрывается всплывашкой.

local TX = dofile((debug.getinfo(1, 'S').source:match('^@(.*/)') or './') .. 'jf_tracker_utf8.lua')   -- 20 окт: набор Юникодом (кириллица)
local FB = {}
FB.list = {}           -- { label=, data= } от main
FB.query = ''
FB.cur = 1
FB.scroll = 0
FB.folder = 'all'
FB.FOLDERS = { 'all', 'fav', 'dev', 'type', 'cat', 'rec' }
FB.tags = { cat = {}, dev = {} }   -- ключ (имя файла, пробелы → _) → категория / разработчик
FB.natfav = {}                     -- ключи избранного REAPER
FB.ownfav = {}                     -- своё избранное: метка → true
FB.recent = {}                     -- метки недавно добавленных, свежие первыми
local cache = { q = nil, list = nil, res = nil, folder = nil, gen = 0 }
FB.gen = 0                         -- меняется при правке избранного / недавних (сброс кэша)

-- ключ эффекта как в reaper-fxtags.ini: имя файла без пути и «<uid», пробелы → _
function FB.fxkey(it)
  if it._key then return it._key end
  local id = tostring(it.data or '')
  local base = id:gsub('<.*$', ''):match('([^/\\]+)$') or id
  if base == '' then base = (it.label or ''):gsub('^%w+i?:%s*', '') end
  it._key = base:gsub(' ', '_')
  return it._key
end
-- тип: префикс метки (VST3 / VST / AU / JS / CLAP / LV2 / DX), иначе other
function FB.kind(it)
  local k = (it.label or ''):match('^(%w+i?):')
  return k and k:upper():gsub('I$', '') or 'other'
end
function FB.dev(it)
  local d = FB.tags.dev[FB.fxkey(it)]
  if d and d ~= '' then return d end
  -- 11 окт: не последняя скобка вообще (группы «2->12ch», «-24 + 24 range», «x86_64»), а последняя,
  -- похожая на имя: каналы, разрядность, legacy id, диапазоны — пропуск; JS без тега — «JS»
  local groups = {}
  for g in (it.label or ''):gmatch('%(([^()]+)%)') do groups[#groups + 1] = g end
  for k = #groups, 1, -1 do
    local g = groups[k]:lower()
    local spec = g:match('^[%-%+%d]') or g:find('%d+ch') or g:find('->', 1, true) or g:find('x86', 1, true) or g:find('x64', 1, true)
      or g:find('arm64', 1, true) or g:find('legacy', 1, true) or g:find('range', 1, true) or g:find('mono', 1, true) or g:find('stereo', 1, true)
      or g:find('demo', 1, true) or g:find('voices', 1, true)
    if not spec then return groups[k] end
  end
  if FB.kind(it) == 'JS' then return 'JS' end
  return '?'
end
function FB.cat(it) return FB.tags.cat[FB.fxkey(it)] or '?' end
function FB.is_fav(it) return FB.natfav[FB.fxkey(it)] or FB.ownfav[it.label] or false end
function FB.set_tags(cat, dev, natfav) FB.tags = { cat = cat or {}, dev = dev or {} }; FB.natfav = natfav or {}; FB.gen = FB.gen + 1 end
function FB.toggle_fav(it)
  if not it then return end
  if FB.ownfav[it.label] then FB.ownfav[it.label] = nil else FB.ownfav[it.label] = true end
  FB.gen = FB.gen + 1
end
function FB.push_recent(it)
  if not it then return end
  for i = #FB.recent, 1, -1 do if FB.recent[i] == it.label then table.remove(FB.recent, i) end end
  table.insert(FB.recent, 1, it.label)
  while #FB.recent > 40 do table.remove(FB.recent) end
  FB.gen = FB.gen + 1
end

local UP, DOWN = 30064, 1685026670

-- короткое имя: «VST3: Pro-Q 3 (FabFilter)» → «Pro-Q 3 (FabFilter)  vst3»
function FB.short(label)
  local kind, rest = label:match('^(%w+i?):%s*(.*)$')
  if kind and rest ~= '' then return rest, kind:lower() end
  return label, ''
end

local function score(hay, term)
  local neg = term:sub(1, 1) == '!'
  if neg then return not hay:find(term:sub(2), 1, true) and 0 or nil end
  if term:sub(1, 1) == "'" then return hay:find(term:sub(2), 1, true) and 50 or nil end
  if term:sub(1, 1) == '^' then return hay:sub(1, #term - 1) == term:sub(2) and 80 or nil end
  if term:sub(-1) == '$' then local t = term:sub(1, -2); return hay:sub(-#t) == t and 60 or nil end
  local p = hay:find(term, 1, true)
  if p then return 100 - math.min(p, 50) + ((p == 1 or hay:sub(p - 1, p - 1):match('[%s%(%-_]')) and 30 or 0) end
  -- подпоследовательность (9 окт: одним шаблоном Lua «a.-b.-c», было —
  -- посимвольно в цикле: 2730 эффектов × буква = 250 мс на нажатие)
  local pat = FB.subpat[term]
  if not pat then
    local parts = {}
    for ch in term:gmatch('.') do parts[#parts + 1] = (ch:gsub('%p', '%%%0')) end
    pat = table.concat(parts, '.-')
    FB.subpat[term] = pat
  end
  local a, b = hay:find(pat)
  if not a then return nil end
  return math.max(1, 30 - (b - a - #term))             -- плотнее — выше
end
FB.subpat = {}
-- нижний регистр имени / метки — один раз на эффект (не на каждый поиск)
local function hay_of(it)
  if not it._hay then
    it._name = FB.short(it.label)
    it._hay = it._name:lower()
    it._lab = it.label:lower()
  end
  return it._hay, it._lab, it._name
end

-- отфильтрованный и отсортированный список (кэш по запросу)
local function group_of(it)
  if FB.folder == 'dev' then return FB.dev(it)
  elseif FB.folder == 'type' then return FB.kind(it)
  elseif FB.folder == 'cat' then return (FB.cat(it):gsub('|.*$', '')) end
  return nil
end
-- строки списка: { it = } и заголовки групп { hdr = } (dev / type / cat)
function FB.results()
  if cache.q == FB.query and cache.list == FB.list and cache.folder == FB.folder and cache.gen == FB.gen then return cache.res end
  local res = {}
  local terms = {}
  for t in FB.query:lower():gmatch('%S+') do terms[#terms + 1] = t end
  local rec_i = {}
  if FB.folder == 'rec' then for i, l in ipairs(FB.recent) do rec_i[l] = i end end
  -- 9 окт: запрос дописан (старый — его начало, та же папка / список) —
  -- искать только среди прошлых результатов
  local src = FB.list
  if cache.res and cache.q and cache.q ~= '' and FB.query:sub(1, #cache.q) == cache.q and not FB.query:find('!', 1, true)
     and cache.list == FB.list and cache.folder == FB.folder and cache.gen == FB.gen then
    src = {}
    for _, r in ipairs(cache.res) do if r.it then src[#src + 1] = r.it end end
  end
  for _, it in ipairs(src) do
    if (FB.folder == 'fav' and not FB.is_fav(it)) or (FB.folder == 'rec' and not rec_i[it.label]) then goto skip end
    do
    local hay, lab, name = hay_of(it)
    local total, ok = 0, true
    for _, t in ipairs(terms) do
      local s = score(hay, t) or score(lab, t)
      if not s then ok = false; break end
      total = total + s
    end
    if ok then res[#res + 1] = { it = it, s = total, name = hay, g = group_of(it), r = rec_i[it.label] } end
    end
    ::skip::
  end
  if FB.folder == 'rec' then table.sort(res, function(a, b) return a.r < b.r end)
  elseif FB.folder == 'dev' or FB.folder == 'type' or FB.folder == 'cat' then
    table.sort(res, function(a, b)
      if a.g ~= b.g then if a.g == '?' then return false elseif b.g == '?' then return true end return a.g:lower() < b.g:lower() end
      if #terms > 0 and a.s ~= b.s then return a.s > b.s end
      return a.name < b.name
    end)
    -- заголовки групп
    local out, last = {}, nil
    for _, r in ipairs(res) do
      if r.g ~= last then out[#out + 1] = { hdr = r.g }; last = r.g end
      out[#out + 1] = r
    end
    res = out
  elseif #terms > 0 then table.sort(res, function(a, b) if a.s ~= b.s then return a.s > b.s end return a.name < b.name end) end
  cache.q, cache.list, cache.res, cache.folder, cache.gen = FB.query, FB.list, res, FB.folder, FB.gen
  return res
end

function FB.selected()
  local r = FB.results()[FB.cur]
  return r and r.it
end
-- курсор не стоит на заголовке группы: шаг d (+1 / −1) до строки эффекта
local function skip_hdr(d)
  local res = FB.results()
  local n = #res
  if n == 0 then FB.cur = 1; return end
  FB.cur = math.max(1, math.min(n, FB.cur))
  local guard = 0
  while res[FB.cur] and res[FB.cur].hdr and guard < n do
    FB.cur = FB.cur + (d or 1)
    if FB.cur > n then FB.cur = n; d = -1 elseif FB.cur < 1 then FB.cur = 1; d = 1 end
    guard = guard + 1
  end
end
FB.skip_hdr = skip_hdr

-- клавиши в фокусе: 'add' — добавить выбранный; 'leave' — фокус дальше
function FB.key(c, mods)
  mods = mods or {}
  local n = #FB.results()
  if c == 27 then
    if FB.query ~= '' then FB.query = ''; FB.cur = 1; FB.scroll = 0; return true end
    return 'leave'
  elseif c == 13 then return 'add'
  elseif c == DOWN or (mods.ctrl and c == 10) then FB.cur = math.min(math.max(1, n), FB.cur + 1); skip_hdr(1)
  elseif c == UP or (mods.ctrl and c == 11) then FB.cur = math.max(1, FB.cur - 1); skip_hdr(-1)
  elseif c == 8 then FB.query = TX.bs(FB.query); FB.cur = 1; FB.scroll = 0; skip_hdr(1)
  elseif TX.char(c) then FB.query = FB.query .. TX.char(c);   -- 20 окт: и кириллица
    FB.cur = 1; FB.scroll = 0; skip_hdr(1)
  else return false end
  return true
end

-- отрисовка в (x, y, w, h); hover = { row = i } | 'search'
function FB.draw(U, L, x, y, w, h, focused, fit)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local hover
  U.set(U.PANEL); gfx.rect(x, y, w, h, 1)
  U.set(U.LINE); gfx.rect(x + w - 1, y, 1, h, 1)
  -- папки (как нативный браузер) и * — избранное для выбранного
  do
    local bx = x + L.pad
    local by = y + 2
    local rows = 1
    for _, fname in ipairs(FB.FOLDERS) do
      local bw = U.measure(fname) + 2 * L.pad
      -- не влезает — на следующую строку (узкая колонка), не обрезать
      if bx + bw > x + w - L.pad - (rows == 1 and (U.measure('*') + 2 * L.pad) or 0) then
        if rows >= 2 then break end
        rows = rows + 1; bx = x + L.pad; by = by + L.rh
      end
      local on = FB.folder == fname
      local hot = mx >= bx and mx < bx + bw and my >= by and my < by + L.rh
      U.set(on and U.tint(U.AMBER, 0.3) or (hot and U.tint(U.TEXT, 0.08) or U.BG)); gfx.rect(bx, by, bw, L.rh - 1, 1)
      U.set(on and U.AMBER or U.LINE); gfx.rect(bx, by, bw, L.rh - 1, 0)
      U.text(bx + L.pad, by, fname, on and U.AMBER or (hot and U.TEXT or U.GREY))
      if hot then hover = { folder = fname } end
      if FB.hint then FB.hint('fxbbtn', bx, by, bw, L.rh, { folder = fname }) end   -- 9 окт: метки f
      bx = bx + bw + 2
    end
    local sel = FB.selected()
    local fav = sel and FB.is_fav(sel)
    local sw = U.measure('*') + 2 * L.pad
    local sx = x + w - L.pad - sw - 1
    local sy0 = y + 2                                   -- * — всегда в первой строке справа
    local hot = mx >= sx and mx < sx + sw and my >= sy0 and my < sy0 + L.rh
    U.set(fav and U.tint(U.AMBER, 0.35) or (hot and U.tint(U.TEXT, 0.08) or U.BG)); gfx.rect(sx, sy0, sw, L.rh - 1, 1)
    U.set(fav and U.AMBER or U.LINE); gfx.rect(sx, sy0, sw, L.rh - 1, 0)
    U.text(sx + L.pad, sy0, '*', fav and U.AMBER or (hot and U.TEXT or U.GREY))
    if hot then hover = { star = true } end
    if FB.hint then FB.hint('fxbbtn', sx, sy0, sw, L.rh, { star = true }) end
    y, h = y + rows * L.rh + 2, h - rows * L.rh - 2
  end
  -- строка поиска
  local res = FB.results()
  local sy = y + 3
  U.set(U.BG); gfx.rect(x + L.pad, sy, w - 2 * L.pad - 1, L.rh, 1)
  U.set(focused and U.AMBER or U.LINE); gfx.rect(x + L.pad, sy, w - 2 * L.pad - 1, L.rh, 0)
  local q = FB.query ~= '' and FB.query or (focused and '' or 'fx: type to find')
  local cnt = ('%d'):format(#res)
  local cw = U.measure(cnt) + L.pad
  U.text(x + 2 * L.pad, sy + 1, fit((FB.query ~= '' and '/' or '') .. q .. (focused and '_' or ''), w - 4 * L.pad - cw), FB.query ~= '' and U.TEXT or U.GREY)
  U.text(x + w - L.pad - cw, sy + 1, cnt, U.GREY)
  if mx >= x and mx < x + w and my >= sy and my < sy + L.rh then hover = 'search' end
  if FB.hint then FB.hint('fxbbtn', x + L.pad, sy, w - 2 * L.pad, L.rh, { search = true }) end
  -- список
  local top = sy + L.rh + 3
  local nvis = math.max(1, math.floor((y + h - top - 2) / L.rh))
  if FB.cur > #res then FB.cur = math.max(1, #res) end
  if FB.cur - 1 < FB.scroll then FB.scroll = FB.cur - 1 end
  if FB.cur - 1 >= FB.scroll + nvis then FB.scroll = FB.cur - nvis end
  for i = 1, nvis do
    local idx = FB.scroll + i
    local r = res[idx]
    if not r then break end
    local ry = top + (i - 1) * L.rh
    if r.hdr then
      -- заголовок группы (разработчик / тип / категория)
      U.text(x + L.pad, ry + 1, fit(r.hdr, w - 2 * L.pad), U.AMBER)
      U.set(U.LINE); gfx.rect(x + L.pad + math.min(w - 3 * L.pad, U.measure(r.hdr) + L.pad), ry + math.floor(L.rh / 2), math.max(0, w - 3 * L.pad - U.measure(r.hdr) - L.pad), 1, 1)
      goto next_row
    end
    do
    local sel = idx == FB.cur
    local curc = sel and U.list_cursor(x + 1, ry, w - 3, L.rh, focused)   -- 10 окт: курсор как в lib
    local name, kind = FB.short(r.it.label)
    if FB.is_fav(r.it) then name = '* ' .. name end          -- избранное видно в любой папке
    local kw = kind ~= '' and (U.measure(kind) + L.pad) or 0
    U.text(x + L.pad, ry + 1, fit(name, w - 2 * L.pad - kw), (sel and focused) and curc or U.TEXT)
    if kw > 0 and w > kw * 3 then U.text(x + w - L.pad - kw + L.pad, ry + 1, kind, (sel and focused) and U.GREY or U.DIM) end
    if mx >= x and mx < x + w - 1 and my >= ry and my < ry + L.rh then hover = { row = idx } end
    if FB.hint then FB.hint('fxbrow', x + 1, ry, w - 3, L.rh, idx) end
    end
    ::next_row::
  end
  if U.vbar then U.vbar('fxb', x, top, w, nvis * L.rh, FB.scroll, nvis, #res) end   -- 15 окт: длинному списку — полоса всегда
  return hover
end

return FB
