-- jf_tracker_doc.lua — справка F1 прямо в трекере (6 окт).
--
-- Текст — из jf_tracker_help.html (один источник: html остаётся для
-- браузера, это окно — его зеркало в стиле трекера). Разделы по <h2>:
-- слева список разделов, справа текст раздела с переносом по ширине;
-- клавиши (<kbd>) — янтарём, заголовки блоков (<b>, <h3>) — циан. Первым —
-- раздел «find»: всё в трекере ищется через /.
-- Клавиши: j k — прокрутка, J K / [ ] — раздел, / — поиск по всей справке
-- (n N — следующее / предыдущее попадание), Esc / F1 — закрыть.
-- Без reaper / gfx в разборе: tests/test_doc.lua.

local DOC = { sec = 1, scroll = 0, query = nil, typing = false, hits = {}, hit = 0 }
local U, ctx

DOC.FIND = {
  'Everything in jf_tracker can be found by typing - the slash / is the door:',
  '',
  '[/] in the tracker - commands and actions at the cursor (fuzzy: type a few letters, Enter runs)',
  '[:] the command line - :pt, :big, :arp up 2, :swing 33, :pm big ...; Tab completes',
  '[Ctrl+/] find an effect and add it to the track',
  '[Option+/] find inside the DSP chain of the track',
  '[Cmd+/] find a file (samples, projects)',
  '[?] any REAPER action in the tracker style, the recent ones on top',
  '[\\] the main menu of everything; [\\\\] the menu of what is under the cursor (= right click)',
  '[f] two-letter labels on everything on screen - type the label and you are there',
  '[/] here, in this help - search the whole help; [n] [N] next / previous hit',
  '',
  'The help button of the main module shows the keys of the focused module, live: every key you press lights up its line.',
  '[Shift+F1] - the tutorial: first steps, one at a time.',
}

local ENT = { amp = '&', lt = '<', gt = '>', quot = '"', nbsp = ' ', middot = '·', mdash = '—', ndash = '–', rarr = '→', larr = '←', hellip = '…', times = '×' }
local function unent(s)
  s = s:gsub('&#(%d+);', function(n) return utf8.char(tonumber(n)) end)
  s = s:gsub('&#x(%x+);', function(n) return utf8.char(tonumber(n, 16)) end)
  return (s:gsub('&(%a+);', function(e) return ENT[e] or ('&' .. e .. ';') end))
end

-- html → { { id, title, lines = { строки с метками [клавиш] и {заголовков} } } }
function DOC.parse(html)
  local body = html:match('<body.->(.*)</body>') or html
  body = body:gsub('<style.-</style>', ''):gsub('<script.-</script>', ''):gsub('<svg.-</svg>', ''):gsub('<!%-%-.-%-%->', '')
  body = body:gsub('<figure.-</figure>', ''):gsub('<img[^>]*>', '')
  local secs = {}
  local cur = { id = 'intro', title = 'jf_tracker', raw = {} }
  local pos = 1
  while true do
    local a, b, id, title = body:find('<h2[^>]-id="([^"]*)"[^>]*>(.-)</h2>', pos)
    local chunk = body:sub(pos, a and (a - 1) or #body)
    cur.raw[#cur.raw + 1] = chunk
    if #table.concat(cur.raw):gsub('%s', '') > 0 or cur.id ~= 'intro' then secs[#secs + 1] = cur end
    if not a then break end
    cur = { id = id, title = unent(title:gsub('<[^>]+>', '')), raw = {} }
    pos = b + 1
  end
  for _, s in ipairs(secs) do
    local t = table.concat(s.raw)
    t = t:gsub('\r', ''):gsub('\n', ' ')
    -- метки раскраски — управляющие символы (в тексте клавиши [ ] { } сами
    -- бывают): \1клавиша\2 — янтарь, \3заголовок\4 — циан
    t = t:gsub('<kbd>(.-)</kbd>', function(k) return '\1' .. k:gsub('<[^>]+>', '') .. '\2' end)
    t = t:gsub('<h3[^>]*>(.-)</h3>', function(h) return '\n\3' .. h:gsub('<[^>]+>', '') .. '\4\n' end)
    t = t:gsub('<b>(.-)</b>', function(h) return '\3' .. h:gsub('<[^>]+>', '') .. '\4' end)   -- в строке (в списках — рядом с ·)
    t = t:gsub('<h1[^>]*>(.-)</h1>', function(h) return '\3' .. h:gsub('<[^>]+>', '') .. '\4\n' end)
    t = t:gsub('<br%s*/?>', '\n'):gsub('</p>', '\n\n'):gsub('<p[^>]*>', '')
    t = t:gsub('<li[^>]*>', '\n· '):gsub('</li>', ''):gsub('</?[uo]l[^>]*>', '\n')
    t = t:gsub('<tr[^>]*>', '\n'):gsub('</td>%s*<td[^>]*>', '  —  '):gsub('</?t[dhr][^>]*>', ''):gsub('</?table[^>]*>', '\n')
    t = t:gsub('</div>', '\n'):gsub('<div[^>]*>', '\n')
    t = t:gsub('<[^>]+>', '')
    t = unent(t)
    local lines, blank = {}, true
    for raw in (t .. '\n'):gmatch('([^\n]*)\n') do
      local ln = raw:gsub('%s+', ' '):gsub('^ ', ''):gsub(' $', '')   -- не присваивать переменной цикла (Lua 5.5)
      if ln == '' then
        if not blank then lines[#lines + 1] = ''; blank = true end
      else lines[#lines + 1] = ln; blank = false end
    end
    while lines[#lines] == '' do lines[#lines] = nil end
    s.lines, s.raw = lines, nil
  end
  local find = {}
  for i, ln in ipairs(DOC.FIND) do find[i] = ln:gsub('%[(.-)%]', '\1%1\2') end
  table.insert(secs, 1, { id = 'find', title = 'find anything: /', lines = find })
  return secs
end

function DOC.init(u, c, path)
  U, ctx = u, c
  local f = path and io.open(path, 'rb')
  local html = f and f:read('a') or ''
  if f then f:close() end
  DOC.secs = DOC.parse(html)
end

-- перенос строки по ширине; метки [ ] { } — части слова
function DOC.wrap(line, maxw, measure)
  if line == '' then return { '' } end
  local out, cur = {}, ''
  for word in line:gmatch('%S+') do
    local try = cur == '' and word or (cur .. ' ' .. word)
    if measure((try:gsub('[\1-\4]', ''))) > maxw and cur ~= '' then out[#out + 1] = cur; cur = word else cur = try end
  end
  if cur ~= '' then out[#out + 1] = cur end
  return out
end

-- поиск по всей справке: попадания { sec, line }
function DOC.search(q)
  local hits = {}
  q = (q or ''):lower()
  if q == '' then return hits end
  for si, s in ipairs(DOC.secs or {}) do
    if s.title:lower():find(q, 1, true) then hits[#hits + 1] = { sec = si, line = 1 } end
    for li, ln in ipairs(s.lines) do if ln:gsub('[\1-\4]', ''):lower():find(q, 1, true) then hits[#hits + 1] = { sec = si, line = li } end end
  end
  return hits
end
local function go_hit(k)
  local h = DOC.hits[k]
  if not h then return end
  DOC.hit = k; DOC.sec = h.sec; DOC.want_line = h.line
end

-- клавиши: true — съедена, 'leave' — закрыть
function DOC.key(c)
  local ch = c < 256 and string.char(c) or ''
  if DOC.typing then
    if c == 27 then DOC.typing = false; DOC.query = nil; DOC.hits = {}
    elseif c == 13 then DOC.typing = false
    elseif c == 8 then DOC.query = (DOC.query or ''):sub(1, -2); DOC.hits = DOC.search(DOC.query); go_hit(1)
    elseif c >= 32 and c < 127 then DOC.query = (DOC.query or '') .. ch; DOC.hits = DOC.search(DOC.query); go_hit(1)
    else return true end
    return true
  end
  local n = #(DOC.secs or {})
  if c == 27 or ch == 'q' then
    if DOC.query then DOC.query = nil; DOC.hits = {}; return true end
    return 'leave'
  elseif ch == 'o' then return 'browser'   -- 17 окт: help.html в браузере (там картинки)
  elseif ch == '/' then DOC.typing = true; DOC.query = ''; DOC.hits = {}
  elseif ch == 'n' then if #DOC.hits > 0 then go_hit(DOC.hit % #DOC.hits + 1) end
  elseif ch == 'N' then if #DOC.hits > 0 then go_hit((DOC.hit - 2) % #DOC.hits + 1) end
  -- 17 окт: j k — строка-курсор (короткий раздел не прокручивается — клавиши казались мёртвыми);
  -- на краю раздела — в соседний: справку можно читать подряд одним j
  elseif ch == 'j' or c == 1685026670 then
    if (DOC.line or 1) < (DOC.nlines or 1) then DOC.line = (DOC.line or 1) + 1
    elseif n > 0 then DOC.sec = DOC.sec % n + 1; DOC.scroll = 0; DOC.line = 1 end
  elseif ch == 'k' or c == 30064 then
    if (DOC.line or 1) > 1 then DOC.line = DOC.line - 1
    elseif n > 0 then DOC.sec = (DOC.sec - 2) % n + 1; DOC.scroll = 0; DOC.line = 1e9 end
  elseif ch == 'J' or ch == ']' or c == 1919379572 or c == 9 then DOC.sec = DOC.sec % n + 1; DOC.scroll = 0; DOC.line = 1
  elseif ch == 'K' or ch == '[' or c == 1818584692 then DOC.sec = (DOC.sec - 2) % n + 1; DOC.scroll = 0; DOC.line = 1
  elseif ch == 'g' then DOC.scroll = 0; DOC.line = 1
  elseif ch == 'G' then DOC.scroll = 1e9; DOC.line = 1e9
  elseif ch == ' ' or c == 1885824110 then DOC.line = (DOC.line or 1) + (DOC.page or 10)
  elseif c == 1885828464 then DOC.line = math.max(1, (DOC.line or 1) - (DOC.page or 10))
  else return false end
  return true
end
-- якорь текущего раздела в html (id у <h2>)
function DOC.anchor() local s = (DOC.secs or {})[DOC.sec]; return s and s.id ~= 'intro' and s.id or nil end
function DOC.wheel(d) DOC.line = math.max(1, (DOC.line or 1) + (d > 0 and -3 or 3)) end

-- текст строки с метками: [клавиша] — янтарь, {заголовок} — циан
local function draw_marked(x, y, s, maxx)
  local px, col = x, U.TEXT
  local i = 1
  while i <= #s and px < maxx do
    local j = s:find('[\1-\4]', i) or (#s + 1)
    local seg = s:sub(i, j - 1)
    -- ширина с хвостовыми пробелами (measure битмапа их не считает — слипалось «;\\»)
    if seg ~= '' then U.text(px, y, ctx.fit(seg, maxx - px), col); px = px + U.measure(seg .. '.') - U.measure('.') end
    local m = s:sub(j, j)
    col = (m == '\1' and U.AMBER) or (m == '\3' and U.CYAN) or U.TEXT
    i = j + 1
  end
end

-- окно на весь прямоугольник; возвращает hover
function DOC.draw(L, x, y, w, h)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local hover = { doc = true }
  U.set(U.BG); gfx.rect(x, y, w, h, 1)
  local secs = DOC.secs or {}
  -- шапка
  local head = 'F1 help'
  U.text(x + L.pad, y + 2, head, U.AMBER)
  local qx = x + L.pad + U.measure(head) + 3 * L.pad
  local qs
  if DOC.typing or DOC.query then qs = ('/%s%s  %d hits%s'):format(DOC.query or '', DOC.typing and '_' or '', #DOC.hits, #DOC.hits > 0 and ('  n N  ' .. DOC.hit .. ' of ' .. #DOC.hits) or '')
  else qs = '' end   -- 17 окт: клавиши — только в статусе внизу (была двойная легенда)
  U.text(qx, y + 2, ctx.fit(qs, x + w - qx - L.pad), (DOC.typing or DOC.query) and U.TEXT or U.GREY)
  local top = y + L.rh + 6
  U.set(U.LINE); gfx.rect(x, top - 3, w, 1, 1)
  -- слева — разделы
  local lw = 0
  for _, s in ipairs(secs) do lw = math.max(lw, U.measure(s.title)) end
  lw = math.min(lw + 3 * L.pad, math.floor(w * 0.28))
  for i, s in ipairs(secs) do
    local sy = top + (i - 1) * L.rh
    if sy + L.rh > y + h then break end
    local on = i == DOC.sec
    local hot = mx >= x and mx < x + lw and my >= sy and my < sy + L.rh
    if on then U.set(U.tint(U.AMBER, 0.25)); gfx.rect(x + 1, sy, lw - 2, L.rh, 1) elseif hot then U.set(U.PANEL); gfx.rect(x + 1, sy, lw - 2, L.rh, 1) end
    U.text(x + L.pad, sy + 1, ctx.fit(s.title, lw - 2 * L.pad), on and U.AMBER or (hot and U.TEXT or U.GREY))
    if hot then hover.docsec = i end
  end
  U.set(U.LINE); gfx.rect(x + lw, top - 3, 1, y + h - top + 3, 1)
  -- справа — текст раздела
  local s = secs[DOC.sec]
  if not s then return hover end
  local tx, tw = x + lw + 2 * L.pad, w - lw - 4 * L.pad
  local key = DOC.sec .. '|' .. tw
  if DOC.wkey ~= key then
    DOC.wkey = key
    local out, map = {}, {}
    for li, ln in ipairs(s.lines) do
      map[li] = #out + 1
      for _, part in ipairs(DOC.wrap(ln, tw, U.measure)) do out[#out + 1] = part end
    end
    DOC.wrapped, DOC.linemap = out, map
  end
  local lines = DOC.wrapped
  local nvis = math.max(1, math.floor((y + h - top) / L.rh) - 1)
  DOC.page = nvis - 2
  if DOC.lsec ~= DOC.sec then DOC.lsec = DOC.sec; if not DOC.line or DOC.line < 1e9 then DOC.line = 1 end end   -- раздел мышью
  if DOC.want_line then DOC.line = DOC.linemap[DOC.want_line] or 1; DOC.scroll = math.max(0, DOC.line - 3); DOC.want_line = nil end
  DOC.nlines = #lines
  DOC.line = math.max(1, math.min(DOC.line or 1, #lines))
  if DOC.line <= DOC.scroll then DOC.scroll = DOC.line - 1 elseif DOC.line > DOC.scroll + nvis then DOC.scroll = DOC.line - nvis end
  DOC.scroll = math.max(0, math.min(DOC.scroll, math.max(0, #lines - nvis)))
  U.text(tx, top, s.title, U.AMBER)
  local q = DOC.query and DOC.query ~= '' and DOC.query:lower() or nil
  for i = 1, nvis do
    local ln = lines[DOC.scroll + i]
    if not ln then break end
    local ly = top + i * L.rh
    if q and ln:gsub('[\1-\4]', ''):lower():find(q, 1, true) then U.set(U.tint(U.AMBER, 0.18)); gfx.rect(tx - 2, ly, tw + 4, L.rh, 1) end
    if DOC.scroll + i == DOC.line then U.set(U.PANEL); gfx.rect(tx - 2, ly, tw + 4, L.rh, 1); U.set(U.AMBER); gfx.rect(tx - 2, ly, 1, L.rh, 1) end
    draw_marked(tx, ly + 1, ln, tx + tw)
  end
  if ctx.vbar then ctx.vbar('doc', x + w - 3, top + L.rh, 2, nvis * L.rh, DOC.scroll, nvis, #lines) end
  return hover
end

return DOC
