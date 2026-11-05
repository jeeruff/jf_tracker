-- jf_tracker_dbgshare.lua (5 ноя) — :debug share: лог отладки, который можно отправить автору.
-- Белый список, не чёрный: остаются время, числа, file:line, слова самого кода трекера (идентификаторы и
-- слова строк лога) и слова ошибок Lua; всё остальное — имена треков / файлов / регионов, пути, текст в кавычках,
-- не-ASCII — метки <path> <text> <w>. Так в отчёт не попадают ни личные данные, ни чужие инструкции.
-- Без reaper.* — тест tests/test_dbgshare.lua.
local S = {}

S.LUA_WORDS = {}
for w in ([[attempt to index call compare perform arithmetic on concatenate a an nil value field local global upvalue
  method number string table boolean function userdata bad argument expected got with in at line stack traceback
  error near unexpected symbol end of file loop for initial limit step must be invalid key next out memory
  C main chunk tail calls yield across metamethod is not too many results frame ms KB]]):gmatch('%S+') do S.LUA_WORDS[w] = true end

-- словарь — только то, что бывает в логе: слова строк с dlog (format-строки и аргументы), имена полей hover.*
-- (дамп того, что под мышью), id панелей (id = '...'), режимы; не все слова кода (их ~11 тысяч — сквозь них
-- проходила бы осмысленная фраза)
S.MODES = { normal = true, insert = true, visual = true, vline = true, cmd = true, search = true, tracker = true }
function S.vocab(sources)
  local v = {}
  for k in pairs(S.MODES) do v[k] = true end
  for _, src in ipairs(sources) do
    for line in src:gmatch('[^\n]+') do
      local code = line:gsub('%s%-%-%s.*$', '')   -- комментарий — «-- » с пробелом (--- в строке лога — не он)
      if code:find('dlog', 1, true) then for w in code:gmatch('[%a_][%w_]*') do v[w] = true end end
      for w in code:gmatch('hover%.([%a_][%w_]*)') do v[w] = true end
      for w in code:gmatch("[^%w_]id%s*=%s*'([%a_][%w_]*)'") do v[w] = true end
    end
  end
  return v
end

local function word_ok(w, vocab) return vocab[w] or S.LUA_WORDS[w] end

-- одна строка лога → безопасная строка
function S.line(s, vocab, maxlen)
  maxlen = maxlen or 400
  local ts, rest = s:match('^(%d%d:%d%d:%d%d%.%d%d%d )(.*)$')
  if not ts then ts, rest = '', s end
  local keep = {}
  local function stash(t) keep[#keep + 1] = t; return '\1' .. #keep .. '\2' end
  -- file:line кода трекера — без пути
  rest = rest:gsub('[^%s\'"]*(jf_tracker[%w_]*%.lua:%d+)', function(fl) return stash(fl) end)
  rest = rest:gsub('[^%s\'"]*(daemon_tracker[%w_]*%.lua:%d+)', function(fl) return stash(fl) end)
  -- пути (/a/b, ~/x, C:\x) — метка
  rest = rest:gsub('[~%a]?:?[/\\][^%s\'"]*[/\\][^%s\'"]*', '<path>')
  rest = rest:gsub('~/[^%s\'"]*', '<path>')
  -- текст в кавычках: идентификатор кода — остаётся, иначе <text>
  local function q(open, body)
    if body:match('^[%a_][%w_]*$') and word_ok(body, vocab) then return open .. body .. open end
    return '<text>'
  end
  rest = rest:gsub("'([^']*)'", function(b) return q("'", b) end)
  rest = rest:gsub('"([^"]*)"', function(b) return q('"', b) end)
  -- размеры 3840x2118 — числа, не слово
  rest = rest:gsub('(%d+)x(%d+)', function(a2, b2) return stash(a2 .. 'x' .. b2) end)
  -- не-ASCII (кириллица, эмодзи …) — метка
  rest = rest:gsub('[\128-\255]+', '<w>')
  -- слова: свои — остаются, чужие — <w>
  rest = rest:gsub('[%a_][%w_]*', function(w)
    if w == 'path' or w == 'text' or w == 'w' then return w end   -- части меток
    return word_ok(w, vocab) and w or '<w>'
  end)
  rest = rest:gsub('<w>[%s<w>]*<w>', '<w>')                       -- подряд — одной меткой
  rest = rest:gsub('\1(%d+)\2', function(n) return keep[tonumber(n)] end)
  if #rest > maxlen then rest = rest:sub(1, maxlen) .. ' …' end
  return ts .. rest
end

-- весь лог → текст для отправки (последние max_lines строк), заголовок — версии
function S.share(log, vocab, head, max_lines)
  local lines = {}
  for l in (log or ''):gmatch('[^\n]+') do lines[#lines + 1] = l end
  local from = math.max(1, #lines - (max_lines or 3000) + 1)
  local out = { head or 'jf_tracker debug share' }
  out[#out + 1] = 'names, paths and free text are replaced by <w> <path> <text>'
  for i = from, #lines do out[#out + 1] = S.line(lines[i], vocab) end
  return table.concat(out, '\n') .. '\n', #lines - from + 1
end

return S
