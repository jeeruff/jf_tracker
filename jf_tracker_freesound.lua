-- jf_tracker_freesound.lua (2 ноя) — поиск звуков на freesound.org (API v2) для вкладки fs браузера.
--
-- Сеть — только curl через reaper.ExecProcess без ожидания (-1), без шелла и только по действию пользователя
-- (поиск, прослушивание строки, Enter). Конец работы curl виден по файлу-флагу: второй URL той же команды
-- (file://…/LICENSE) curl качает после первого, поэтому флаг появляется, когда первый ответ уже на диске.
-- Ключ API у каждого свой (freesound.org/apiv2/apply), :freesound key <ключ>; превью (mp3 128k) качаются
-- без ключа с cdn.freesound.org; оригиналы требуют OAuth — не делаем.
local FS = { jobs = {}, results = {}, query = '', err = nil, busy = false, count = 0 }
local R = reaper
local DIR = (debug.getinfo(1, 'S').source:match('^@(.*/)') or './')

FS.API = 'https://freesound.org/apiv2/search/text/'
FS.FIELDS = 'id,name,username,license,duration,previews,tags,url'
FS.PAGE = 50

-- ── JSON: только разбор (ответ поиска) ─────────────────────────────────────
function FS.json(s)
  local i = 1
  local function ws() i = s:find('[^ \t\r\n]', i) or #s + 1 end
  local val
  local function str()
    local out, j = {}, i + 1
    while true do
      local c = s:sub(j, j)
      if c == '' then error('json: open string') end
      if c == '"' then i = j + 1; return table.concat(out) end
      if c == '\\' then
        local e = s:sub(j + 1, j + 1)
        if e == 'u' then
          local cp = tonumber(s:sub(j + 2, j + 5), 16) or 63
          j = j + 6
          if cp >= 0xD800 and cp <= 0xDBFF and s:sub(j, j + 1) == '\\u' then   -- суррогатная пара
            local lo = tonumber(s:sub(j + 2, j + 5), 16) or 0xDC00
            cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00); j = j + 6
          end
          out[#out + 1] = utf8.char(cp)
        else
          out[#out + 1] = ({ b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' })[e] or e
          j = j + 2
        end
      else
        local k = s:find('["\\]', j) or #s + 1
        out[#out + 1] = s:sub(j, k - 1); j = k
      end
    end
  end
  function val()
    ws()
    local c = s:sub(i, i)
    if c == '{' then
      local t = {}; i = i + 1; ws()
      if s:sub(i, i) == '}' then i = i + 1; return t end
      while true do
        ws(); local k = str(); ws()
        if s:sub(i, i) ~= ':' then error('json: : expected') end
        i = i + 1; t[k] = val(); ws()
        local d = s:sub(i, i); i = i + 1
        if d == '}' then return t elseif d ~= ',' then error('json: , expected') end
      end
    elseif c == '[' then
      local t = {}; i = i + 1; ws()
      if s:sub(i, i) == ']' then i = i + 1; return t end
      while true do
        t[#t + 1] = val(); ws()
        local d = s:sub(i, i); i = i + 1
        if d == ']' then return t elseif d ~= ',' then error('json: , expected') end
      end
    elseif c == '"' then return str()
    elseif s:sub(i, i + 3) == 'true' then i = i + 4; return true
    elseif s:sub(i, i + 4) == 'false' then i = i + 5; return false
    elseif s:sub(i, i + 3) == 'null' then i = i + 4; return nil
    else
      local num = s:match('^-?%d+%.?%d*[eE]?[-+]?%d*', i)
      if not num or num == '' then error('json: bad value at ' .. i) end
      i = i + #num; return tonumber(num)
    end
  end
  return val()
end

function FS.urlenc(s)
  return (s:gsub('[^%w%-%._~]', function(c) return ('%%%02X'):format(c:byte()) end))
end

-- запрос: слова + фильтры как в списке браузера: <10s >2s — длина, cc0 — только CC0
function FS.build_url(q, key, page)
  local words, filt = {}, {}
  local lo, hi
  for t in q:gmatch('%S+') do
    local n = t:match('^<([%d%.]+)s?$'); local m = t:match('^>([%d%.]+)s?$')
    if n then hi = n elseif m then lo = m
    elseif t:lower() == 'cc0' then filt[#filt + 1] = 'license:"Creative Commons 0"'
    else words[#words + 1] = t end
  end
  if lo or hi then filt[#filt + 1] = ('duration:[%s TO %s]'):format(lo or '0', hi or '*') end
  local u = FS.API .. '?query=' .. FS.urlenc(table.concat(words, ' ')) .. '&fields=' .. FS.FIELDS .. '&page_size=' .. FS.PAGE
  if #filt > 0 then u = u .. '&filter=' .. FS.urlenc(table.concat(filt, ' ')) end
  if page and page > 1 then u = u .. '&page=' .. page end
  return u .. '&token=' .. FS.urlenc(key or '')
end

function FS.lic(url)
  url = url or ''
  if url:find('zero', 1, true) then return 'CC0' end
  if url:find('by%-nc') then return 'CC BY-NC' end
  if url:find('sampling') then return 'Sampling+' end
  if url:find('/by/', 1, true) then return 'CC BY' end
  return 'other'
end

-- ответ поиска → строки браузера
function FS.parse(txt)
  local ok, d = pcall(FS.json, txt or '')
  if not ok or type(d) ~= 'table' then return nil, 'freesound: bad answer' end
  if d.detail then return nil, 'freesound: ' .. tostring(d.detail) end
  local out = {}
  for _, h in ipairs(d.results or {}) do
    local pv = h.previews or {}
    out[#out + 1] = { id = h.id, name = h.name or tostring(h.id), user = h.username or '?', lic = FS.lic(h.license), license = h.license,
      len = tonumber(h.duration), url = h.url, mp3 = pv['preview-hq-mp3'] or pv['preview-lq-mp3'], tags = h.tags or {} }
  end
  return out, nil, d.count or #out
end

-- ── файлы и curl ────────────────────────────────────────────────────────────
function FS.dir() return R.GetResourcePath() .. '/Data/jf_tracker_freesound' end
function FS.key() return R.GetExtState('jf_tracker', 'fskey') end
function FS.set_key(k) R.SetExtState('jf_tracker', 'fskey', k or '', true) end
local function safe(s) return (s:gsub('[^%w%-%._ ]', '_'):gsub('%s+', ' '):sub(1, 60)) end
function FS.file_of(h)
  local base = safe((h.name or ''):gsub('%.[%w]+$', ''))
  return ('%s/%d %s.mp3'):format(FS.dir(), h.id or 0, base)
end
local function exists(p) local f = io.open(p, 'rb'); if f then f:close(); return true end; return false end
FS.exists = exists

-- curl в фоне: out — куда первый ответ, flag — появится в конце. fail — -f (HTTP-ошибка = нет файла)
local function curl(url, out, flag, fail)
  os.remove(out); os.remove(flag)
  local cmd = ('/usr/bin/curl -s -L %s-m 30 -o "%s" "%s" -o "%s" "file://%sLICENSE"'):format(fail and '-f ' or '', out, url, flag, DIR:gsub(' ', '%%20'))   -- пробел в file:// — только %20
  R.ExecProcess(cmd, -1)
end

function FS.search(q, page)
  local key = FS.key()
  if key == '' then FS.err = 'no API key: get one at freesound.org/apiv2/apply, then :freesound key <key>'; return false end
  R.RecursiveCreateDirectory(FS.dir(), 0)
  local out, flag = FS.dir() .. '/search.json', FS.dir() .. '/search.done'
  FS.query, FS.page, FS.err, FS.busy = q, page or 1, nil, true
  FS.jobs.search = { out = out, flag = flag, t0 = R.time_precise() }
  curl(FS.build_url(q, key, page), out, flag, false)
  return true
end

-- скачать превью строки; then(path) — когда файл на диске (play / lib)
function FS.fetch(h, then_fn)
  local p = FS.file_of(h)
  if exists(p) then then_fn(p); return p end
  if not h.mp3 then FS.err = 'freesound: no preview for ' .. (h.name or '?'); return nil end
  local j = FS.jobs['d' .. h.id]
  if j then j.then_fn = then_fn; return nil end
  R.RecursiveCreateDirectory(FS.dir(), 0)
  local part, flag = p .. '.part', p .. '.done'
  FS.jobs['d' .. h.id] = { out = part, flag = flag, final = p, h = h, then_fn = then_fn, t0 = R.time_precise() }
  curl(h.mp3, part, flag, true)
  return nil
end

-- автор и лицензия скачанного — в CREDITS.txt рядом (для титров трека)
local function credit(h, p)
  local f = io.open(FS.dir() .. '/CREDITS.txt', 'a')
  if f then f:write(('%s\t%s by %s\t%s\t%s\n'):format(p:match('[^/]+$'), h.name or '', h.user or '', h.license or '', h.url or '')); f:close() end
end

-- кадр: готовые задания. Возвращает true, если пришли результаты поиска
function FS.tick()
  local got = false
  local now = R.time_precise()
  for k, j in pairs(FS.jobs) do
    if exists(j.flag) then
      os.remove(j.flag)
      FS.jobs[k] = nil
      if k == 'search' then
        local f = io.open(j.out, 'rb'); local txt = f and f:read('a') or ''; if f then f:close() end
        local res, err, n = FS.parse(txt)
        FS.busy = false
        if res then FS.results, FS.count = res, n else FS.results, FS.err = {}, err end
        got = true
      else
        if exists(j.out) then
          os.rename(j.out, j.final); credit(j.h, j.final)
          if j.then_fn then j.then_fn(j.final) end
        else FS.err = 'freesound: download failed - ' .. (j.h.name or '?') end
      end
    elseif now - j.t0 > 40 then   -- curl умер без флага (нет curl, нет сети)
      FS.jobs[k] = nil
      if k == 'search' then FS.busy = false; FS.err = 'freesound: no answer (network?)'; got = true end
    end
  end
  return got
end

function FS.pending(h) return h and FS.jobs['d' .. h.id] ~= nil end

return FS
