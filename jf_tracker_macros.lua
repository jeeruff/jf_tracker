-- jf_tracker_macros.lua — вкладка macros (9 окт): макросы трекера в одном месте.
--
-- Три секции:
--   recorded — регистры Vim, записанные qa … q (клавиши как есть);
--   saved    — свои макросы: Data/jf_tracker_macros.txt, строка «имя<TAB>тело»
--              (пишутся :macsave a имя или руками в файле);
--   built-in — готовые действия над трекером (scramble, arp …).
-- Тело: «:команда» — строка команд трекера; иначе — клавиши Vim (печатные —
-- как есть, остальные — <код>, например <13> Enter, <27> Esc).
-- Проигрывается у курсора трекера (фокус — в трекер). j k — строка, Enter —
-- проиграть, d — удалить (recorded / saved), s — сохранить recorded под именем.
-- 16 окт: справа — редактор выбранного (кнопки play new edit name key desc share import del и поля);
-- секция shared — файлы .jfm из Data/jf_tracker_macros/ (обмен: share пишет файл, import — в свои).
-- Без reaper.* — тест tests/test_macros.lua.

local MR = { sel = 1, scroll = 0, hot = nil }

MR.BUILTIN = {
  { name = 'scramble',    body = ':scramble',     desc = 'slice notes swap their slices randomly (VISUAL, else the cursor track in the region)' },
  { name = 'arp up',      body = ':arp up',       desc = 'the chord on the cursor row becomes an arpeggio up over its length' },
  { name = 'arp random',  body = ':arp random',   desc = 'the chord on the cursor row - a random arpeggio' },
  { name = 'repeat down', body = ':repeat',       desc = 'the cursor track: what is above the cursor in the pattern repeats down to its end (Ctrl+Opt+J)' },
  { name = 'repeat all',  body = ':repeat all',   desc = 'every track: what is above the cursor row in the pattern repeats down to its end (:repeat all)' },   -- 16 окт
  { name = 'off track',   body = ':off',          desc = 'note off at the cursor row on the whole track (all its subcolumns)' },
  { name = 'off all',     body = ':off all',      desc = 'note off at the cursor row on every track' },
  { name = 'dedouble',    body = ':dedouble',     desc = 'doubled notes (same note at the same time) on the cursor row of the track - one is kept; VISUAL - in the selection' },
  -- 15 окт: модификаторы (jf_tracker_xform) — время и громкость блока / трека в регионе
  { name = 'stretch x2',  body = ':xf stretch 2',  desc = 'time x2 from the block start (twice slower); :xf stretch 0.5 - twice faster' },
  { name = 'shrink /2',   body = ':xf stretch 0.5', desc = 'time / 2: the block plays twice as fast' },
  { name = 'reverse',     body = ':xf reverse',    desc = 'retrograde: the notes of the block in reverse order' },
  { name = 'rotate',      body = ':xf rotate 4',   desc = 'cyclic shift by 4 rows inside the block (:xf rotate -4 back)' },
  { name = 'shuffle',     body = ':xf shuffle',    desc = 'the notes swap places at random' },
  { name = 'gravity',     body = ':xf gravity 2',  desc = 'the notes fall: denser to the end of the block (:xf gravity 0.5 - denser to the start)' },
  { name = 'bounce',      body = ':xf bounce 0.7', desc = 'a bouncing ball: every gap is 0.7 of the one before' },
  { name = 'fibonacci',   body = ':xf fib',        desc = 'the notes sit on Fibonacci rows from the first one: 0 1 2 3 5 8 13 ...' },
  { name = 'tuplet 3',    body = ':xf tuplet 3',   desc = 'the first 3 notes evenly over the block (a triplet over the rows)' },
  { name = 'golden fade', body = ':xf golden',     desc = 'volume: every next note is 0.618 of the one before (golden ratio)' },
}

-- клавиши ↔ строка
function MR.encode(keys)
  local out = {}
  for _, k in ipairs(keys or {}) do
    if k >= 32 and k < 127 and k ~= 60 then out[#out + 1] = string.char(k)   -- «<» — тоже кодом (иначе путается с <код>)
    else out[#out + 1] = '<' .. k .. '>' end
  end
  return table.concat(out)
end
function MR.decode(s)
  local keys, i = {}, 1
  s = s or ''
  while i <= #s do
    local code, j = s:match('^<(%d+)>()', i)
    if code then keys[#keys + 1] = tonumber(code); i = j
    else keys[#keys + 1] = s:byte(i); i = i + 1 end
  end
  return keys
end

-- файл своих макросов: «имя<TAB>тело», # — комментарий
function MR.parse(text)
  local list = {}
  for line in ((text or '') .. '\n'):gmatch('([^\n]*)\n') do
    local name, rest = line:match('^([^\t#][^\t]*)\t(.+)$')
    if name and rest then
      -- 15 окт: третья колонка — буква регистра (@x); 16 окт: четвёртая — описание
      local body, key, desc = rest:match('^([^\t]+)\t?(%l?)\t?([^\t]*)$')
      if body then list[#list + 1] = { name = name, body = body, key = key ~= '' and key or nil, desc = desc ~= '' and desc or nil } end
    end
  end
  return list
end
function MR.serialize(list)
  local out = { '# jf_tracker macros: name<TAB>body[<TAB>key[<TAB>description]]; body ":command" or vim keys (<13> = Enter, <27> = Esc); key - a register letter, @key plays it' }
  for _, m in ipairs(list) do
    local tail = (m.key or m.desc) and ('\t' .. (m.key or '')) or ''
    if m.desc and m.desc ~= '' then tail = tail .. '\t' .. (m.desc:gsub('[\t\n]', ' ')) end
    out[#out + 1] = (m.name:gsub('[\t\n]', ' ')) .. '\t' .. (m.body:gsub('\n', ' ')) .. tail
  end
  return table.concat(out, '\n') .. '\n'
end

-- 16 окт: обмен — файл .jfm (текст, по строке на поле): name / desc / by / key / body
function MR.jfm_encode(m)
  local function one(v) return ((v or ''):gsub('[\r\n]', ' ')) end
  return ('# jf_tracker macro\nname: %s\ndesc: %s\nby: %s\nkey: %s\nbody: %s\n'):format(one(m.name), one(m.desc), one(m.by), one(m.key), one(m.body))
end
function MR.jfm_decode(text)
  local m = {}
  for line in ((text or '') .. '\n'):gmatch('([^\n]*)\n') do
    local k, v = line:match('^(%a+):%s?(.*)$')
    if k then m[k] = v ~= '' and v or nil end
  end
  if not (m.name and m.body) then return nil end
  if m.key and not m.key:match('^%l$') then m.key = nil end
  return m
end
-- имя файла из имени макроса: буквы, цифры, - _
function MR.file_name(name) return ((name or 'macro'):gsub('[^%w%-_]+', '_'):gsub('^_+', ''):gsub('_+$', '')) .. '.jfm' end
-- тело для глаз: <13> → Enter, <27> → Esc, <9> → Tab, <8> → BS
local KN = { [13] = 'Enter', [27] = 'Esc', [9] = 'Tab', [8] = 'BS', [32] = 'Space', [60] = '<' }
function MR.pretty(body)
  body = body or ''
  if body:sub(1, 1) == ':' then return body end
  return (body:gsub('<(%d+)>', function(n) n = tonumber(n); return ' ' .. (KN[n] or ('<' .. n .. '>')) .. ' ' end):gsub('%s+', ' '):gsub('^%s', ''):gsub('%s$', ''))
end

-- строки вкладки: заголовки секций и макросы { kind, name, body, desc }
function MR.rows(regs, saved, builtin, shared)
  local rows = {}
  local rec = {}
  for k, v in pairs(regs or {}) do
    local n = type(k) == 'string' and k:match('^@(%l)$')
    if n and type(v) == 'table' and #v > 0 then rec[#rec + 1] = { kind = 'rec', name = n, body = MR.encode(v), keys = v } end
  end
  table.sort(rec, function(a, b) return a.name < b.name end)
  rows[#rows + 1] = { hdr = 'recorded  (qa ... q to record, @a to play in the tracker)' }
  if #rec == 0 then rows[#rows + 1] = { empty = 'none yet - q + letter starts recording, q stops' } end
  for _, r in ipairs(rec) do rows[#rows + 1] = r end
  rows[#rows + 1] = { hdr = 'saved  (s on a recorded one, or edit the file)' }
  if #(saved or {}) == 0 then rows[#rows + 1] = { empty = 'none yet' } end
  for _, m in ipairs(saved or {}) do rows[#rows + 1] = { kind = 'saved', name = m.name, label = m.name .. (m.key and ('  @' .. m.key) or ''), body = m.body, key = m.key, desc = m.desc } end
  -- 16 окт: shared — файлы .jfm папки обмена (i — в свои)
  if shared then
    rows[#rows + 1] = { hdr = 'shared  (.jfm files in Data/jf_tracker_macros - i imports into saved)' }
    if #shared == 0 then rows[#rows + 1] = { empty = 'none - S on a macro writes one there; put files from others there' } end
    for _, m in ipairs(shared) do rows[#rows + 1] = { kind = 'shared', name = m.name, body = m.body, key = m.key, desc = m.desc, by = m.by, file = m.file } end
  end
  rows[#rows + 1] = { hdr = 'built-in' }
  for _, m in ipairs(builtin or MR.BUILTIN) do rows[#rows + 1] = { kind = 'builtin', name = m.name, body = m.body, desc = m.desc } end
  return rows
end
local function selectable(r) return r and r.kind ~= nil end
function MR.fix_sel(rows)
  if not selectable(rows[MR.sel]) then
    for i, r in ipairs(rows) do if selectable(r) then MR.sel = i; return end end
  end
end

-- 16 окт: кнопки редактора — клавиша → действие (одна функция — одна клавиша)
MR.BUTTONS = { { 'play', 'play', 'Enter' }, { 'new', 'new', 'a' }, { 'edit', 'edit', 'e' }, { 'name', 'name', 'n' }, { 'key', 'reg', 'r' },
               { 'desc', 'desc', 't' }, { 'share', 'share', 'S' }, { 'import', 'import', 'i' }, { 'del', 'delete', 'd' } }
MR.KEYS = { a = 'new', e = 'edit', n = 'name', r = 'reg', t = 'desc', S = 'share', i = 'import' }
-- клавиши вкладки: действие { kind = 'play' | 'delete' | 'save' | …, row } / true — съели / nil
function MR.key(c, rows)
  local ch = c > 0 and c < 256 and string.char(c) or ''
  MR.fix_sel(rows)
  local function step(d)
    local i = MR.sel
    repeat i = i + d until i < 1 or i > #rows or selectable(rows[i])
    if i >= 1 and i <= #rows then MR.sel = i end
  end
  if ch == 'j' or c == 1685026670 then step(1); return true
  elseif ch == 'k' or c == 30064 then step(-1); return true
  elseif ch == 'g' then MR.sel = 1; MR.fix_sel(rows); return true
  elseif ch == 'G' then MR.sel = #rows; step(0); for i = #rows, 1, -1 do if selectable(rows[i]) then MR.sel = i; break end end; return true
  elseif c == 13 or ch == ' ' then return selectable(rows[MR.sel]) and { kind = 'play', row = rows[MR.sel] } or true
  elseif ch == 'd' or ch == 'x' then local r = rows[MR.sel]; return (r and (r.kind == 'rec' or r.kind == 'saved')) and { kind = 'delete', row = r } or true
  elseif ch == 's' then local r = rows[MR.sel]; return (r and r.kind == 'rec') and { kind = 'save', row = r } or true
  -- 16 окт: редактор справа — те же действия, что кнопки
  elseif MR.KEYS[ch] then local r = rows[MR.sel]; return selectable(r) and { kind = MR.KEYS[ch], row = r } or (MR.KEYS[ch] == 'new' and { kind = 'new' }) or true
  end
  return nil
end

-- рисование; d = { U, L, fit, hint, focused }; возвращает hover { i, row }
function MR.draw(d, x, y, w, h, rows)
  local U, L, fit = d.U, d.L, d.fit
  MR.fix_sel(rows)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local nvis = math.max(1, math.floor(h / L.rh))
  if MR.sel > MR.scroll + nvis then MR.scroll = MR.sel - nvis end
  if MR.sel <= MR.scroll then MR.scroll = MR.sel - 1 end
  MR.scroll = math.max(0, math.min(MR.scroll, math.max(0, #rows - nvis)))
  local hv
  -- 16 окт: справа — редактор выбранного (шире 60 знаков — делим), слева список
  local ew = w >= L.cw * 60 and math.floor(w * 0.5) or 0
  local full_w = w
  w = w - ew
  if U.vbar then U.vbar('macros', x, y, w, nvis * L.rh, MR.scroll, nvis, #rows) end   -- 15 окт: полоса всегда
  local nw = math.min(math.floor(w * 0.4), L.cw * 18)
  for i = MR.scroll + 1, math.min(#rows, MR.scroll + nvis) do
    local r = rows[i]
    local ry = y + (i - MR.scroll - 1) * L.rh
    if r.hdr then
      U.text(x + L.pad, ry, fit(r.hdr, w - 2 * L.pad), U.AMBER)
    elseif r.empty then
      U.text(x + 3 * L.pad, ry, fit(r.empty, w - 4 * L.pad), U.DIM)
    else
      local hot = mx >= x and mx < x + w and my >= ry and my < ry + L.rh
      local sel = i == MR.sel
      if sel then U.set(U.tint(U.AMBER, d.focused and 0.30 or 0.15)); gfx.rect(x + 1, ry, w - 2, L.rh, 1)
      elseif hot then U.set(U.tint(U.AMBER, 0.12)); gfx.rect(x + 1, ry, w - 2, L.rh, 1) end
      local tag = r.kind == 'rec' and ('@' .. r.name) or (r.label or r.name)
      U.text(x + 3 * L.pad, ry, fit(tag, nw - 3 * L.pad), sel and U.AMBER or ((r.kind == 'builtin' or r.kind == 'shared') and U.CYAN or U.TEXT))
      U.text(x + nw + L.pad, ry, fit(r.desc or r.body or '', w - nw - 2 * L.pad), U.GREY)
      if hot then hv = { i = i, row = r } end
      if d.hint then d.hint('macro', x, ry, w, L.rh, i) end
    end
  end
  if ew > 0 then
    local r = rows[MR.sel]
    local ex = x + w + L.pad
    local eww = full_w - w - L.pad
    U.set(U.LINE); gfx.rect(ex - L.pad // 2 - 1, y, 1, h, 1)
    -- ряд кнопок (переносом, если не влезли)
    local bx, by = ex, y
    for _, b in ipairs(MR.BUTTONS) do
      local bw = U.measure(b[1]) + 2 * L.pad
      if bx + bw > ex + eww then bx, by = ex, by + L.rh end
      local ok = b[2] == 'new' or (r and r.kind and (b[2] ~= 'delete' or r.kind == 'rec' or r.kind == 'saved') and (b[2] ~= 'import' or r.kind == 'shared'))
      local hot = ok and mx >= bx and mx < bx + bw and my >= by and my < by + L.rh
      U.set(hot and U.tint(U.AMBER, 0.3) or U.BG); gfx.rect(bx, by, bw, L.rh - 1, 1)
      U.set(hot and U.AMBER or U.LINE); gfx.rect(bx, by, bw, L.rh - 1, 0)
      U.text(bx + L.pad, by, b[1], hot and U.AMBER or (ok and U.TEXT or U.DIM))
      if hot then hv = { btn = b[2], key = b[3], row = r } end
      bx = bx + bw + 2
    end
    local fy = by + L.rh + 4
    if r and r.kind then
      local lw = U.measure('register') + 2 * L.pad
      local function field(lbl, val, col)
        if fy + L.rh > y + h then return end
        U.text(ex, fy, lbl, U.GREY)
        U.text(ex + lw, fy, fit(val or '', eww - lw), col or U.TEXT)
        fy = fy + L.rh
      end
      local KIND = { rec = 'recorded (a register)', saved = 'saved (your file)', builtin = 'built-in', shared = 'shared (a .jfm file)' }
      field('name', r.kind == 'rec' and ('@' .. r.name) or r.name, U.AMBER)
      field('kind', KIND[r.kind])
      field('register', r.kind == 'rec' and ('@' .. r.name) or (r.key and ('@' .. r.key) or '- (r sets one, then @x plays it)'), r.key and U.CYAN or U.GREY)
      field('desc', r.desc or '- (t writes one)', r.desc and U.TEXT or U.DIM)
      if r.by then field('by', r.by) end
      if r.file then field('file', r.file, U.GREY) end
      -- тело — переносом по ширине: что именно сыграется
      if fy + L.rh <= y + h then U.text(ex, fy, 'body', U.GREY) end
      local body = MR.pretty(r.body)
      local per = math.max(4, math.floor((eww - lw) / math.max(1, U.measure('m'))))
      local i0 = 1
      while i0 <= #body and fy + L.rh <= y + h do
        U.text(ex + lw, fy, body:sub(i0, i0 + per - 1), U.CYAN)
        i0 = i0 + per; fy = fy + L.rh
      end
      if #body == 0 then fy = fy + L.rh end
    elseif fy + L.rh <= y + h then
      U.text(ex, fy, fit('a - a new macro; q + letter in the tracker records one', eww), U.DIM)
    end
  end
  return hv
end

return MR
