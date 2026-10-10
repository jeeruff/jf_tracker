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
io.open('ARCHITECTURE.md', 'w'):write(doc)
print(('archmap: %d files, %d without a group'):format(#files, #rest))
