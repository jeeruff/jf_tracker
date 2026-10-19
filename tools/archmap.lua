-- tools/archmap.lua — таблица «файлы → за что отвечают» в ARCHITECTURE.md (10 окт).
-- Берёт первую фразу шапки-комментария каждого jf_tracker*.lua и пишет её между
-- метками <!-- files:begin --> и <!-- files:end -->. Запуск из папки трекера:
--   lua tools/archmap.lua
-- Новый модуль без группы попадает в «прочее» — допиши его в GROUP ниже.

local GROUP = {
  { 'ядро: данные и правка', { 'jf_tracker', 'model', 'edit', 'alias', 'arr', 'cmds', 'chord', 'import' } },
  { 'клавиши и команды', { 'vim', 'keys', 'whichkey', 'keyhelp', 'hints', 'instkeys', 'dspkeys', 'ctrlmouse', 'names' } },
  { 'окно: раскладка и рисование', { 'draw', 'panes', 'ui', 'themes', 'smart', 'ask', 'png', 'logo' } },
  { 'панели и вкладки', { 'matrix', 'session', 'browser', 'fxbrowser', 'sampleprops', 'slicer', 'preview', 'params', 'modmatrix', 'fxclass',
      'dspmods', 'dspbig', 'aiedit', 'lfogen', 'sgram', 'macros', 'macro', 'midimap', 'harm', 'video', 'visor', 'garden', 'orca', 'notes', 'pm', 'perf', 'audio' } },
  { 'опции, справка, служебное', { 'options', 'screensets', 'doc', 'tour', 'version' } },
}

local function header(path)
  local f = io.open(path, 'r'); if not f then return nil, 0 end
  local lines, n, txt = {}, 0, f:read('a'); f:close()
  for _ in txt:gmatch('\n') do n = n + 1 end
  for line in (txt .. '\n'):gmatch('([^\n]*)\n') do
    local c = line:match('^%-%-%s?(.*)$')
    if not c or c == '' then if #lines > 0 then break end else lines[#lines + 1] = c end
  end
  local s = table.concat(lines, ' '):gsub('^%S+%.lua%s*', ''):gsub('^%([^)]*%)%s*', ''):gsub('^—%s*', ''):gsub('^%-+%s*', '')
  local first = s:match('^(.-%.)%s') or s                -- первая фраза (до точки), длинная — обрезается ниже
  if utf8.len(first) and utf8.len(first) > 150 then first = first:sub(1, utf8.offset(first, 148) - 1) .. '…' end
  return first, n
end

local files, seen = {}, {}
local p = io.popen('ls jf_tracker*.lua')            -- инструмент разработчика, не трекер: шелл здесь можно
for name in p:lines() do files[#files + 1] = name end
p:close()

local out = { '| файл | строк | за что отвечает |', '|---|---:|---|' }
local function row(name)
  local h, n = header(name)
  out[#out + 1] = ('| `%s` | %d | %s |'):format(name, n, ((h or ''):gsub('|', '/'):gsub('<', '&lt;')))
  seen[name] = true
end
for _, g in ipairs(GROUP) do
  out[#out + 1] = ('| **%s** | | |'):format(g[1])
  for _, k in ipairs(g[2]) do
    local name = k == 'jf_tracker' and 'jf_tracker.lua' or ('jf_tracker_' .. k .. '.lua')
    if io.open(name) then row(name) end
  end
end
local rest = {}
for _, name in ipairs(files) do if not seen[name] then rest[#rest + 1] = name end end
if #rest > 0 then out[#out + 1] = '| **прочее** | | |'; for _, name in ipairs(rest) do row(name) end end

local doc = io.open('ARCHITECTURE.md', 'r'):read('a')
local a, b = doc:find('<!%-%- files:begin %-%->'), doc:find('<!%-%- files:end %-%->')
assert(a and b, 'ARCHITECTURE.md: метки files:begin / files:end не найдены')
local head = doc:sub(1, doc:find('\n', a) or a)
doc = head .. table.concat(out, '\n') .. '\n' .. doc:sub(b)
-- 19 окт: карта структуры — модули окна (реестр PN.PANELS) и префиксы клавиш NORMAL (which-key).
-- Переставил модуль / букву / префикс — перезапусти archmap: правка видна в git diff ARCHITECTURE.md
do
  local PN = dofile('jf_tracker_panes.lua')
  local m = { '| модуль (id) | подпись | буква (gt, Ctrl+W g) | место по умолчанию | когда есть |', '|---|---|---|---|---|' }
  local keys, dup = {}, {}
  for _, pn in ipairs(PN.PANELS) do
    if keys[pn.key] then dup[#dup + 1] = pn.key .. ': ' .. keys[pn.key] .. ' / ' .. pn.id end
    keys[pn.key] = pn.id
    m[#m + 1] = ('| `%s` | %s | `%s` | %s%s | %s |'):format(pn.id, pn.label, pn.key, pn.side or '', pn.tab and ', вкладка сверху' or '', pn.avail == 'merged' and 'влита (не показывается)' or (pn.avail or 'всегда'))
  end
  if #dup > 0 then m[#m + 1] = ''; m[#m + 1] = '**Дубли букв:** ' .. table.concat(dup, '; ') end
  local WK = dofile('jf_tracker_whichkey.lua')
  local names = {}
  for k in pairs(WK.T or {}) do names[#names + 1] = k end
  table.sort(names)
  local w = { '| префикс | заголовок | клавиши дальше |', '|---|---|---|' }
  for _, k in ipairs(names) do
    local h = WK.T[k]
    local ks = {}
    for _, it in ipairs(h.items or {}) do ks[#ks + 1] = '`' .. tostring(it[1]):gsub('|', '/') .. '`' end
    w[#w + 1] = ('| `%s` | %s | %s |'):format(k, (h.title or ''):gsub('|', '/'), table.concat(ks, ' '))
  end
  local txt = '### Модули окна\n\n' .. table.concat(m, '\n') .. '\n\n### Префиксы клавиш (NORMAL, which-key)\n\n' .. table.concat(w, '\n') .. '\n'
  local a2, b2 = doc:find('<!%-%- keys:begin %-%->'), doc:find('<!%-%- keys:end %-%->')
  if not (a2 and b2) then
    doc = doc .. '\n## Карта модулей и клавиш\n\nСобирает `lua tools/archmap.lua` из `PN.PANELS` (jf_tracker_panes.lua) и which-key\n(jf_tracker_whichkey.lua). Руками не править. Перед перестановкой модуля, буквы\nили префикса — сверься с этой картой; после — перезапусти скрипт и посмотри diff.\n\n<!-- keys:begin -->\n<!-- keys:end -->\n'
    a2, b2 = doc:find('<!%-%- keys:begin %-%->'), doc:find('<!%-%- keys:end %-%->')
  end
  doc = doc:sub(1, doc:find('\n', a2)) .. txt .. doc:sub(b2)
  if #dup > 0 then print('archmap: DUPLICATE pane keys: ' .. table.concat(dup, '; ')) end
end
io.open('ARCHITECTURE.md', 'w'):write(doc)
print(('archmap: %d files, %d without a group'):format(#files, #rest))
