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
-- Без reaper.* — тест tests/test_macros.lua.

local MR = { sel = 1, scroll = 0, hot = nil }

MR.BUILTIN = {
  { name = 'scramble',    body = ':scramble',     desc = 'slice notes swap their slices randomly (VISUAL, else the cursor track in the region)' },
  { name = 'arp up',      body = ':arp up',       desc = 'the chord on the cursor row becomes an arpeggio up over its length' },
  { name = 'arp random',  body = ':arp random',   desc = 'the chord on the cursor row - a random arpeggio' },
  { name = 'repeat down', body = ':repeat',       desc = 'repeat the part of the region above the cursor down to the region end' },
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
    local name, body = line:match('^([^\t#][^\t]*)\t(.+)$')
    if name and body then list[#list + 1] = { name = name, body = body } end
  end
  return list
end
function MR.serialize(list)
  local out = { '# jf_tracker macros: name<TAB>body; body ":command" or vim keys (<13> = Enter, <27> = Esc)' }
  for _, m in ipairs(list) do out[#out + 1] = (m.name:gsub('[\t\n]', ' ')) .. '\t' .. (m.body:gsub('\n', ' ')) end
  return table.concat(out, '\n') .. '\n'
end

-- строки вкладки: заголовки секций и макросы { kind, name, body, desc }
function MR.rows(regs, saved, builtin)
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
  for _, m in ipairs(saved or {}) do rows[#rows + 1] = { kind = 'saved', name = m.name, body = m.body } end
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

-- клавиши вкладки: действие { kind = 'play' | 'delete' | 'save', row } / true — съели / nil
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
  local nw = math.min(math.floor(w * 0.3), L.cw * 18)
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
      local tag = r.kind == 'rec' and ('@' .. r.name) or r.name
      U.text(x + 3 * L.pad, ry, fit(tag, nw - 3 * L.pad), sel and U.AMBER or (r.kind == 'builtin' and U.CYAN or U.TEXT))
      U.text(x + nw + L.pad, ry, fit(r.desc or r.body or '', w - nw - 2 * L.pad), U.GREY)
      if hot then hv = { i = i, row = r } end
      if d.hint then d.hint('macro', x, ry, w, L.rh, i) end
    end
  end
  return hv
end

return MR
