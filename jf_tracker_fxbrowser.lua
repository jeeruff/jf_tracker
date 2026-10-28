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
-- 28 окт: исключить из поиска — плагин ('p:' .. label) или папку дерева ('n:' .. k .. '=' .. v: разработчик, категория,
-- тип); исключённое не попадает в результаты набора (/), в своей папке видно (тусклым, с x)
FB.excl = {}
function FB.node_key(nd) return 'n:' .. tostring(nd.k) .. '=' .. tostring(nd.v) end
function FB.excluded(it)
  if FB.excl['p:' .. (it.label or '')] then return true end
  for key in pairs(FB.excl) do
    local k, v = key:match('^n:([^=]+)=(.*)$')
    if k and FB.node_ok_k(it, { k = k, v = v ~= 'nil' and v or nil }) then return true end
  end
  return false
end
-- → 'plugin' / 'folder' / nil, имя
function FB.toggle_excl(it, nd)
  local key, what, nm
  if nd and nd.k ~= 'all' and nd.k ~= 'fav' and nd.k ~= 'rec' then key, what, nm = FB.node_key(nd), 'folder', tostring(nd.v or nd.k)
  elseif it then key, what, nm = 'p:' .. it.label, 'plugin', FB.short and FB.short(it.label) or it.label end
  if not key then return nil end
  FB.excl[key] = (not FB.excl[key]) or nil
  FB.gen = FB.gen + 1
  return what, nm, FB.excl[key] == true
end
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

-- 21 окт: две колонки, как в REAPER: слева дерево (All / Favorites / Recently used / Instruments, типы, категории,
-- разработчики) с числом эффектов, справа список узла. Узел — FB.node = { k = all|fav|rec|inst|type|cat|dev, v = }.
-- Клавиши: j k — строка, h l — колонка (FB.col 1 дерево / 2 список), Enter — узел / добавить, / — поиск, gt gT — модули
FB.node = { k = 'all' }
FB.col = 2
FB.tree_cur, FB.tree_scroll = 1, 0
FB.tree_on = false           -- ставит draw: колонка дерева видна (широко)
FB.typing = false            -- поиск только после /
local TYPE_ORDER = { 'VST', 'VSTi', 'VST3', 'VST3i', 'AU', 'AUi', 'LV2', 'LV2i', 'CLAP', 'CLAPi', 'JS', 'DX', 'DXi' }
local function raw_kind(it) return (it.label or ''):match('^(%w+):') or 'other' end
local tree_c = {}
function FB.tree()
  if tree_c.list == FB.list and tree_c.gen == FB.gen then return tree_c.rows end
  local nt, nc, nd, nfav, ninst = {}, {}, {}, 0, 0
  for _, it in ipairs(FB.list) do
    local k = raw_kind(it)
    nt[k] = (nt[k] or 0) + 1
    if k:match('i$') then ninst = ninst + 1 end
    if FB.is_fav(it) then nfav = nfav + 1 end
    for c in (FB.cat(it) .. '|'):gmatch('([^|]*)|') do if c ~= '' and c ~= '?' then nc[c] = (nc[c] or 0) + 1 end end
    local d = FB.dev(it); if d ~= '?' then nd[d] = (nd[d] or 0) + 1 end
  end
  local rows = {}
  local function add(label, node, n, depth) rows[#rows + 1] = { label = label, node = node, n = n, depth = depth or 1 } end
  local function hdr(label) rows[#rows + 1] = { label = label, hdr = true } end
  add('all plugins', { k = 'all' }, #FB.list, 0)
  add('favorites', { k = 'fav' }, nfav, 0)
  add('recently used', { k = 'rec' }, #FB.recent, 0)
  add('instruments', { k = 'inst' }, ninst, 0)
  hdr('types')
  local seen = {}
  for _, k in ipairs(TYPE_ORDER) do if nt[k] then add(k, { k = 'type', v = k }, nt[k]); seen[k] = true end end
  for k, n in pairs(nt) do if not seen[k] then add(k, { k = 'type', v = k }, n) end end
  local function sorted(t) local o = {}; for k in pairs(t) do o[#o + 1] = k end; table.sort(o, function(a, b) return a:lower() < b:lower() end); return o end
  local cs = sorted(nc)
  if #cs > 0 then hdr('categories'); for _, c in ipairs(cs) do add(c, { k = 'cat', v = c }, nc[c]) end end
  local ds = sorted(nd)
  if #ds > 0 then hdr('developers'); for _, d in ipairs(ds) do add(d, { k = 'dev', v = d }, nd[d]) end end
  tree_c.list, tree_c.gen, tree_c.rows = FB.list, FB.gen, rows
  return rows
end
local function node_ok(it, nd, rec_i)
  local k = nd.k
  if k == 'all' then return true
  elseif k == 'fav' then return FB.is_fav(it)
  elseif k == 'rec' then return rec_i[it.label] ~= nil
  elseif k == 'inst' then return raw_kind(it):match('i$') ~= nil
  elseif k == 'type' then return raw_kind(it) == nd.v
  elseif k == 'cat' then return ('|' .. FB.cat(it) .. '|'):find('|' .. nd.v .. '|', 1, true) ~= nil
  elseif k == 'dev' then return FB.dev(it) == nd.v end
  return true
end
function FB.node_ok_k(it, nd) return node_ok(it, nd, {}) end
FB.node_ok = node_ok

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
  local fkey = FB.tree_on and ('node:' .. FB.node.k .. ':' .. tostring(FB.node.v)) or FB.folder
  if cache.q == FB.query and cache.list == FB.list and cache.folder == fkey and cache.gen == FB.gen then return cache.res end
  local tree = FB.tree_on
  local folder = tree and (FB.node.k == 'rec' and 'rec' or 'tree') or FB.folder
  local res = {}
  local terms = {}
  for t in FB.query:lower():gmatch('%S+') do terms[#terms + 1] = t end
  local rec_i = {}
  if folder == 'rec' then for i, l in ipairs(FB.recent) do rec_i[l] = i end end
  -- 9 окт: запрос дописан (старый — его начало, та же папка / список) —
  -- искать только среди прошлых результатов
  local src = FB.list
  if cache.res and cache.q and cache.q ~= '' and FB.query:sub(1, #cache.q) == cache.q and not FB.query:find('!', 1, true)
     and cache.list == FB.list and cache.folder == fkey and cache.gen == FB.gen then
    src = {}
    for _, r in ipairs(cache.res) do if r.it then src[#src + 1] = r.it end end
  end
  for _, it in ipairs(src) do
    if tree then if not node_ok(it, FB.node, rec_i) then goto skip end
    elseif (folder == 'fav' and not FB.is_fav(it)) or (folder == 'rec' and not rec_i[it.label]) then goto skip end
    if #terms > 0 and next(FB.excl) and FB.excluded(it) then goto skip end   -- 28 окт: исключённое — не в поиске
    do
    local hay, lab, name = hay_of(it)
    local total, ok = 0, true
    for _, t in ipairs(terms) do
      local s = score(hay, t) or score(lab, t)
      if not s then ok = false; break end
      total = total + s
    end
    if ok then res[#res + 1] = { it = it, s = total, name = hay, g = (not tree) and group_of(it) or nil, r = rec_i[it.label] } end
    end
    ::skip::
  end
  if folder == 'rec' then table.sort(res, function(a, b) return a.r < b.r end)
  elseif tree then table.sort(res, function(a, b) if #terms > 0 and a.s ~= b.s then return a.s > b.s end return a.name < b.name end)
  elseif folder == 'dev' or folder == 'type' or folder == 'cat' then
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
  cache.q, cache.list, cache.res, cache.folder, cache.gen = FB.query, FB.list, res, fkey, FB.gen
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
  -- 21 окт: без / — навигация (буквы не в поиск): j k h l, G, Enter, * избранное, g t / g T — модули ('gt' / 'gT')
  if not FB.typing then
    local ch = c > 0 and c < 256 and string.char(c) or ''
    if FB.gpend then FB.gpend = nil; if ch == 't' then return 'gt' elseif ch == 'T' then return 'gT' elseif ch == 'g' then if FB.col == 1 and FB.tree_on then FB.tree_cur = 1 else FB.cur = 1; skip_hdr(1) end; return true end end
    if ch == '/' then FB.typing = true; return true end
    if ch == 'g' then FB.gpend = true; return true end
    local tree = FB.tree_on and FB.col == 1
    local rows = tree and FB.tree() or nil
    local function tstep(d)
      local i = FB.tree_cur
      repeat i = i + d until not rows[i] or not rows[i].hdr
      if rows[i] then FB.tree_cur = i end
    end
    if ch == 'j' or c == DOWN then if tree then tstep(1) else FB.cur = math.min(math.max(1, n), FB.cur + 1); skip_hdr(1) end; return true end
    if ch == 'k' or c == UP then if tree then tstep(-1) else FB.cur = math.max(1, FB.cur - 1); skip_hdr(-1) end; return true end
    if ch == 'G' then if tree then FB.tree_cur = #rows else FB.cur = math.max(1, n); skip_hdr(-1) end; return true end
    if (ch == 'h' or c == 1818584692) and FB.tree_on then FB.col = 1; return true end
    if (ch == 'l' or c == 1919379572) and FB.tree_on then FB.col = 2; return true end
    if ch == '*' then FB.toggle_fav(FB.selected()); return true end
    if ch == 'x' then   -- 28 окт: исключить из поиска (в дереве — папку, в списке — плагин); ещё раз — вернуть
      local nd = tree and rows[FB.tree_cur] and rows[FB.tree_cur].node or nil
      local what, nm, on = FB.toggle_excl(not tree and FB.selected() or nil, nd)
      FB.last_excl = what and (('%s %s %s search (x again - back)'):format(what, nm, on and 'excluded from' or 'back in')) or 'x: pick a plugin or a folder (developer, category, type)'
      return 'excl'
    end
    -- 22 окт: a — к треку курсора, A (Shift = выбранные) — к выбранным трекам, n — на новый трек
    if ch == 'a' then return 'add' elseif ch == 'A' then return 'addsel' elseif ch == 'n' then return 'addnew' end
    if c == 13 then
      if tree then local r = rows[FB.tree_cur]; if r and r.node then FB.node = r.node; FB.cur = 1; FB.scroll = 0; FB.col = 2; skip_hdr(1) end; return true end
      return 'add'
    end
    if c == 27 then if FB.query ~= '' then FB.query = ''; FB.cur = 1; FB.scroll = 0; return true end; return 'leave' end
    return false
  end
  if c == 13 then FB.typing = false; return 'add' end   -- поиск: Enter — добавить найденное (и из набора)
  if c == 27 then FB.typing = false end
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
  -- 21 окт: широко — дерево слева (как в REAPER), список справа; узко — прежние кнопки папок
  local was = FB.tree_on
  FB.tree_on = w >= L.cw * 34
  if FB.tree_on ~= was then FB.cur = 1; FB.scroll = 0 end
  FB.tree_x1 = nil
  if FB.tree_on then
    local tw = math.max(L.cw * 14, math.min(L.cw * 24, math.floor(w * 0.4)))
    local rows = FB.tree()
    local top = y + 3
    local nvis = math.max(1, math.floor((h - 6) / L.rh))
    FB.tree_cur = math.max(1, math.min(#rows, FB.tree_cur))
    if FB.tree_seen ~= FB.tree_cur then   -- 21 окт: за курсором — только когда он сдвинулся (колесо листает свободно)
      FB.tree_seen = FB.tree_cur
      if FB.tree_cur - 1 < FB.tree_scroll then FB.tree_scroll = FB.tree_cur - 1 end
      if FB.tree_cur - 1 >= FB.tree_scroll + nvis then FB.tree_scroll = FB.tree_cur - nvis end
    end
    FB.tree_scroll = math.max(0, math.min(FB.tree_scroll, math.max(0, #rows - nvis)))
    for i = 1, nvis do
      local idx = FB.tree_scroll + i
      local r = rows[idx]
      if not r then break end
      local ry = top + (i - 1) * L.rh
      if r.hdr then U.text(x + L.pad, ry + 1, fit(r.label, tw - 2 * L.pad), U.AMBER)
      else
        local on = FB.node.k == r.node.k and FB.node.v == r.node.v
        local sel = focused and FB.col == 1 and idx == FB.tree_cur
        if sel then U.list_cursor(x + 1, ry, tw - 3, L.rh, true) elseif on then U.set(U.tint(U.CYAN, 0.18)); gfx.rect(x + 1, ry, tw - 3, L.rh, 1) end
        local cnt = tostring(r.n or 0)
        local ix = x + L.pad + (r.depth or 1) * L.cw
        local ex = r.node and FB.excl[FB.node_key(r.node)]
        U.text(ix, ry + 1, fit((ex and 'x ' or '') .. r.label, x + tw - 2 * L.pad - U.measure(cnt) - ix), ex and U.DIM or (on and U.CYAN or U.TEXT))
        U.text(x + tw - L.pad - U.measure(cnt), ry + 1, cnt, U.DIM)
        if mx >= x and mx < x + tw and my >= ry and my < ry + L.rh then hover = { tree = idx } end
        if FB.hint then FB.hint('fxbtree', x + 1, ry, tw - 3, L.rh, idx) end
      end
    end
    if U.vbar then U.vbar('fxbtree', x, top, tw, nvis * L.rh, FB.tree_scroll, nvis, #rows) end
    U.set(U.LINE); gfx.rect(x + tw, y, 1, h, 1)
    FB.tree_x1 = x + tw   -- 21 окт: колесо левее — дерево
    x, w = x + tw + 1, w - tw - 1
  end
  -- папки (как нативный браузер) и * — избранное для выбранного
  if not FB.tree_on then
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
  local q = FB.query ~= '' and FB.query or ((focused and FB.typing) and '' or (focused and '/ - find, j k h l, Enter - add' or 'fx: / to find'))
  local cnt = ('%d'):format(#res)
  local cw = U.measure(cnt) + L.pad
  U.text(x + 2 * L.pad, sy + 1, fit(((FB.query ~= '' or FB.typing) and '/' or '') .. q .. ((focused and FB.typing) and '_' or ''), w - 4 * L.pad - cw), FB.query ~= '' and U.TEXT or U.GREY)
  U.text(x + w - L.pad - cw, sy + 1, cnt, U.GREY)
  if mx >= x and mx < x + w and my >= sy and my < sy + L.rh then hover = 'search' end
  if FB.hint then FB.hint('fxbbtn', x + L.pad, sy, w - 2 * L.pad, L.rh, { search = true }) end
  -- список
  local top = sy + L.rh + 3
  local nvis = math.max(1, math.floor((y + h - top - 2) / L.rh))
  if FB.cur > #res then FB.cur = math.max(1, #res) end
  if FB.cur_seen ~= FB.cur then   -- 21 окт: за курсором — только когда он сдвинулся
    FB.cur_seen = FB.cur
    if FB.cur - 1 < FB.scroll then FB.scroll = FB.cur - 1 end
    if FB.cur - 1 >= FB.scroll + nvis then FB.scroll = FB.cur - nvis end
  end
  FB.scroll = math.max(0, math.min(FB.scroll, math.max(0, #res - nvis)))
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
    local curc = sel and U.list_cursor(x + 1, ry, w - 3, L.rh, focused and (FB.col == 2 or not FB.tree_on))   -- 10 окт: курсор как в lib
    local name, kind = FB.short(r.it.label)
    if FB.is_fav(r.it) then name = '* ' .. name end          -- избранное видно в любой папке
    local exl = FB.excl['p:' .. r.it.label]
    if exl then name = 'x ' .. name end                       -- 28 окт: исключён из поиска
    local kw = kind ~= '' and (U.measure(kind) + L.pad) or 0
    U.text(x + L.pad, ry + 1, fit(name, w - 2 * L.pad - kw), (sel and focused) and curc or (exl and U.DIM or U.TEXT))
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
