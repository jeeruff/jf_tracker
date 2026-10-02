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

local FB = {}
FB.list = {}           -- { label=, data= } от main
FB.query = ''
FB.cur = 1
FB.scroll = 0
local cache = { q = nil, list = nil, res = nil }

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
  -- подпоследовательность
  local j, sc, last = 1, 0, -1
  for i = 1, #hay do
    if hay:sub(i, i) == term:sub(j, j) then
      sc = sc + (i == last + 1 and 3 or 1); last = i; j = j + 1
      if j > #term then return sc end
    end
  end
  return nil
end

-- отфильтрованный и отсортированный список (кэш по запросу)
function FB.results()
  if cache.q == FB.query and cache.list == FB.list then return cache.res end
  local res = {}
  local terms = {}
  for t in FB.query:lower():gmatch('%S+') do terms[#terms + 1] = t end
  for _, it in ipairs(FB.list) do
    local name = FB.short(it.label)
    local hay = name:lower()
    local total, ok = 0, true
    for _, t in ipairs(terms) do
      local s = score(hay, t) or score(it.label:lower(), t)
      if not s then ok = false; break end
      total = total + s
    end
    if ok then res[#res + 1] = { it = it, s = total, name = name:lower() } end
  end
  if #terms > 0 then table.sort(res, function(a, b) if a.s ~= b.s then return a.s > b.s end return a.name < b.name end) end
  cache.q, cache.list, cache.res = FB.query, FB.list, res
  return res
end

function FB.selected()
  local r = FB.results()[FB.cur]
  return r and r.it
end

-- клавиши в фокусе: 'add' — добавить выбранный; 'leave' — фокус дальше
function FB.key(c, mods)
  mods = mods or {}
  local n = #FB.results()
  if c == 27 then
    if FB.query ~= '' then FB.query = ''; FB.cur = 1; FB.scroll = 0; return true end
    return 'leave'
  elseif c == 13 then return 'add'
  elseif c == DOWN or (mods.ctrl and c == 10) then FB.cur = math.min(math.max(1, n), FB.cur + 1)
  elseif c == UP or (mods.ctrl and c == 11) then FB.cur = math.max(1, FB.cur - 1)
  elseif c == 8 then FB.query = FB.query:sub(1, -2); FB.cur = 1; FB.scroll = 0
  elseif c >= 32 and c <= 126 then FB.query = FB.query .. string.char(c); FB.cur = 1; FB.scroll = 0
  else return false end
  return true
end

-- отрисовка в (x, y, w, h); hover = { row = i } | 'search'
function FB.draw(U, L, x, y, w, h, focused, fit)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local hover
  U.set(U.PANEL); gfx.rect(x, y, w, h, 1)
  U.set(U.LINE); gfx.rect(x + w - 1, y, 1, h, 1)
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
    local sel = idx == FB.cur
    if sel then U.set(focused and U.TEXT or U.LINE); gfx.rect(x + 1, ry, w - 3, L.rh, 1) end
    local name, kind = FB.short(r.it.label)
    local kw = kind ~= '' and (U.measure(kind) + L.pad) or 0
    U.text(x + L.pad, ry + 1, fit(name, w - 2 * L.pad - kw), (sel and focused) and U.BG or U.TEXT)
    if kw > 0 and w > kw * 3 then U.text(x + w - L.pad - kw + L.pad, ry + 1, kind, (sel and focused) and U.BG or U.DIM) end
    if mx >= x and mx < x + w - 1 and my >= ry and my < ry + L.rh then hover = { row = idx } end
  end
  return hover
end

return FB
