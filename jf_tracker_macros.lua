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
  { name = 'repeat down', body = ':repeat',       keys = 'Ctrl+Opt+J', desc = 'the cursor track: what is above the cursor in the pattern repeats down to its end' },
  { name = 'repeat all',  body = ':repeat all',   desc = 'every track: what is above the cursor row in the pattern repeats down to its end (:repeat all)' },   -- 16 окт
  { name = 'off track',   body = ':off',          desc = 'note off at the cursor row on the whole track (all its subcolumns)' },
  { name = 'off all',     body = ':off all',      hk = '`', desc = 'note off at the cursor row on every track' },
  { name = 'nooff all',   body = ':nooff all',    hk = '~', desc = 'remove every OFF on every track in what you see (project / sec / pat); the notes ring to the next event' },   -- 26 окт
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
  -- 17 окт: humanizer — уже стоящие ноты чуть разные, как живые (VISUAL — блок, иначе трек курсора в регионе)
  { name = 'humanize',          body = ':human all',     desc = 'every note a little different: timing +-10 ms, pitch +-8 cents, volume +-1.5 dB, pan, attack, length (:human all 50% - softer)' },
  { name = 'humanize no pitch', body = ':human nopitch', desc = 'the same without the pitch: timing, volume, pan, attack, length' },
  { name = 'humanize no time',  body = ':human notime',  desc = 'the same without the timing - the grid stays: pitch, volume, pan, attack, length' },
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
      local body, key, desc, hk = rest:match('^([^\t]+)\t?(%l?)\t?([^\t]*)\t?([^\t]*)$')
      if body then list[#list + 1] = { name = name, body = body, key = key ~= '' and key or nil, desc = desc ~= '' and desc or nil, hotkey = hk ~= '' and hk or nil } end   -- 16 окт: пятая — хоткей
    end
  end
  return list
end
function MR.serialize(list)
  local out = { '# jf_tracker macros: name<TAB>body[<TAB>key[<TAB>description]]; body ":command" or vim keys (<13> = Enter, <27> = Esc); key - a register letter, @key plays it' }
  for _, m in ipairs(list) do
    local tail = (m.key or m.desc or m.hotkey) and ('\t' .. (m.key or '')) or ''
    if (m.desc and m.desc ~= '') or m.hotkey then tail = tail .. '\t' .. ((m.desc or ''):gsub('[\t\n]', ' ')) end
    if m.hotkey then tail = tail .. '\t' .. m.hotkey end
    out[#out + 1] = (m.name:gsub('[\t\n]', ' ')) .. '\t' .. (m.body:gsub('\n', ' ')) .. tail
  end
  return table.concat(out, '\n') .. '\n'
end

-- 16 окт: хоткей макроса — «модификаторы-код»: C ctrl, A option, M cmd, S shift ('CA-106'); подпись — словами
function MR.hk_encode(c, m)
  return ((m.ctrl and 'C' or '') .. (m.alt and 'A' or '') .. (m.cmd and 'M' or '') .. (m.shift and 'S' or '')) .. '-' .. tostring(c)
end
local SPECIAL = { [13] = 'Enter', [9] = 'Tab', [8] = 'BS', [32] = 'Space', [27] = 'Esc', [30064] = 'Up', [1685026670] = 'Down', [1818584692] = 'Left', [1919379572] = 'Right' }
function MR.hk_label(hk, namefn)
  local mods, code = (hk or ''):match('^(%u*)%-(%d+)$')
  code = tonumber(code)
  if not code then return nil end
  local w = {}
  if mods:find('C') then w[#w + 1] = 'Ctrl' end
  if mods:find('A') then w[#w + 1] = 'Opt' end
  if mods:find('M') then w[#w + 1] = 'Cmd' end
  if mods:find('S') then w[#w + 1] = 'Shift' end
  local nm = SPECIAL[code]
  if not nm and code >= 1 and code <= 26 and mods:find('C') then nm = string.char(code + 64) end   -- Ctrl+буква приходит кодом 1..26
  if not nm and namefn then nm = namefn(code) end
  if not nm and code >= 32 and code < 127 then nm = string.char(code):upper() end
  w[#w + 1] = nm or ('#' .. code)
  return table.concat(w, '+')
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
  for _, m in ipairs(saved or {}) do rows[#rows + 1] = { kind = 'saved', name = m.name, label = m.name .. (m.key and ('  @' .. m.key) or ''), body = m.body, key = m.key, desc = m.desc, hotkey = m.hotkey } end
  -- 16 окт: shared — файлы .jfm папки обмена (i — в свои)
  if shared then
    rows[#rows + 1] = { hdr = 'shared  (.jfm files in Data/jf_tracker_macros - i imports into saved)' }
    if #shared == 0 then rows[#rows + 1] = { empty = 'none - S on a macro writes one there; put files from others there' } end
    for _, m in ipairs(shared) do rows[#rows + 1] = { kind = 'shared', name = m.name, body = m.body, key = m.key, desc = m.desc, by = m.by, file = m.file } end
  end
  rows[#rows + 1] = { hdr = 'built-in' }
  for _, m in ipairs(builtin or MR.BUILTIN) do rows[#rows + 1] = { kind = 'builtin', name = m.name, body = m.body, desc = m.desc, keys = m.keys, hotkey = m.hotkey, hk = m.hk } end
  return rows
end
local function selectable(r) return r and r.kind ~= nil end
-- 18 окт: вид lf — папки (recorded / saved / shared / built-in) слева, макросы папки посередине, свойства справа
MR.dir, MR.incol = MR.dir or 1, MR.incol or 'list'
function MR.dirs(rows)
  local out = {}
  for i, r in ipairs(rows) do
    if r.hdr then out[#out + 1] = { name = r.hdr:match('^(%S+)'), note = r.hdr:match('^%S+%s+(.*)$'), i0 = i + 1, i1 = i, n = 0 }
    elseif out[#out] then local d = out[#out]; d.i1 = i; if r.kind then d.n = d.n + 1 end end
  end
  return out
end
local function dir_of(ds, i) for k, d in ipairs(ds) do if i >= d.i0 and i <= d.i1 then return k end end end
local function first_in(rows, d) for i = d.i0, d.i1 do if selectable(rows[i]) then return i end end return d.i0 end
function MR.fix_sel(rows)
  local ds = MR.dirs(rows)
  if #ds == 0 then return end
  -- выбранный макрос задаёт папку (щелчок, новый); иначе — первый в папке
  local k = selectable(rows[MR.sel]) and dir_of(ds, MR.sel)
  if k then MR.dir = k
  else MR.dir = math.max(1, math.min(#ds, MR.dir)); MR.sel = first_in(rows, ds[MR.dir]) end
end

-- 16 окт: кнопки редактора — клавиша → действие (одна функция — одна клавиша)
MR.BUTTONS = { { 'play', 'play', 'Enter' }, { 'new', 'new', 'a' }, { 'edit', 'edit', 'e' }, { 'name', 'name', 'n' }, { 'hotkey', 'hotkey', 'K' }, { 'reg', 'reg', 'r' },
               { 'desc', 'desc', 't' }, { 'share', 'share', 'S' }, { 'import', 'import', 'i' }, { 'del', 'delete', 'd' } }
MR.KEYS = { a = 'new', e = 'edit', n = 'name', r = 'reg', t = 'desc', S = 'share', i = 'import', K = 'hotkey' }
-- клавиши вкладки: действие { kind = 'play' | 'delete' | 'save' | …, row } / true — съели / nil
function MR.key(c, rows)
  local ch = c > 0 and c < 256 and string.char(c) or ''
  MR.fix_sel(rows)
  local ds = MR.dirs(rows)
  local cd = ds[MR.dir] or { i0 = 1, i1 = #rows }
  local function step(d)
    local i = MR.sel
    repeat i = i + d until i < cd.i0 or i > cd.i1 or selectable(rows[i])
    if i >= cd.i0 and i <= cd.i1 then MR.sel = i end
  end
  local function go_dir(d)
    if #ds == 0 then return end
    MR.dir = (MR.dir - 1 + d) % #ds + 1
    MR.sel, MR.scroll = first_in(rows, ds[MR.dir]), 0
  end
  -- h / l (← →) — между папками и списком, как в lf; в папках j k — папка
  if ch == 'h' or c == 1818584692 then MR.incol = 'dirs'; return true
  elseif ch == 'l' or c == 1919379572 then MR.incol = 'list'; return true
  elseif ch == 'j' or c == 1685026670 then if MR.incol == 'dirs' then go_dir(1) else step(1) end; return true
  elseif ch == 'k' or c == 30064 then if MR.incol == 'dirs' then go_dir(-1) else step(-1) end; return true
  elseif ch == 'g' then MR.sel = first_in(rows, cd); return true
  elseif ch == 'G' then for i = cd.i1, cd.i0, -1 do if selectable(rows[i]) then MR.sel = i; break end end; return true
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
  local hv
  -- 16 окт: справа — редактор выбранного (шире 60 знаков — делим), слева список
  local ew = w >= L.cw * 60 and math.floor(w * 0.5) or 0
  local full_w = w
  w = w - ew
  -- 18 окт: lf — колонка папок (имя и число), список — только выбранной папки, её подсказка первой строкой
  local ds = MR.dirs(rows)
  local dw = 0
  for _, dd in ipairs(ds) do dw = math.max(dw, U.measure(dd.name .. ' 99')) end
  dw = dw + 3 * L.pad
  for k, dd in ipairs(ds) do
    local ry = y + (k - 1) * L.rh
    if ry + L.rh > y + h then break end
    local on = k == MR.dir
    local hot = mx >= x and mx < x + dw and my >= ry and my < ry + L.rh
    if on then U.set(U.tint(U.AMBER, (d.focused and MR.incol == 'dirs') and 0.30 or 0.15)); gfx.rect(x + 1, ry, dw - 2, L.rh, 1)
    elseif hot then U.set(U.tint(U.AMBER, 0.12)); gfx.rect(x + 1, ry, dw - 2, L.rh, 1) end
    U.text(x + L.pad, ry, dd.name, on and U.AMBER or U.TEXT)
    local ns = tostring(dd.n)
    U.text(x + dw - L.pad - U.measure(ns), ry, ns, dd.n > 0 and U.GREY or U.DIM)
    if hot then hv = { dir = k } end
  end
  U.set(U.LINE); gfx.rect(x + dw, y, 1, h, 1)
  local cd = ds[MR.dir] or { i0 = 1, i1 = #rows }
  local lx = x + dw + L.pad
  local note_h = (cd.note and cd.note ~= '') and L.rh or 0
  if note_h > 0 then U.text(lx + L.pad, y, fit(cd.note, w - dw - 3 * L.pad), U.DIM) end
  local ly = y + note_h
  local n_in = cd.i1 - cd.i0 + 1
  local nvis = math.max(1, math.floor((h - note_h) / L.rh))
  local p = MR.sel - cd.i0
  if p >= MR.scroll + nvis then MR.scroll = p - nvis + 1 end
  if p < MR.scroll then MR.scroll = p end
  MR.scroll = math.max(0, math.min(MR.scroll, math.max(0, n_in - nvis)))
  local sbw = 6
  local lw = w - dw - L.pad - sbw
  local nw = math.min(math.floor(lw * 0.4), L.cw * 18)
  for i = cd.i0 + MR.scroll, math.min(cd.i1, cd.i0 + MR.scroll + nvis - 1) do
    local r = rows[i]
    local ry = ly + (i - cd.i0 - MR.scroll) * L.rh
    local x, w = lx - 2 * L.pad, lw + 2 * L.pad
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
  -- 18 окт: полоса прокрутки списка папки — своя, видна, когда не влезло
  if n_in > nvis then
    local sx, sh = lx + lw + 1, nvis * L.rh
    U.set(U.LINE); gfx.rect(sx + 2, ly, 1, sh, 1)
    local th = math.max(L.rh, math.floor(sh * nvis / n_in))
    local ty = ly + math.floor((sh - th) * MR.scroll / math.max(1, n_in - nvis))
    U.set(U.GREY); gfx.rect(sx, ty, sbw - 1, th, 1)
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
      local hkl = r.hotkey and MR.hk_label(r.hotkey, d.key_name) or r.keys
      field('hotkey', hkl or '- (K, then press the keys)', hkl and U.CYAN or U.DIM)
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
