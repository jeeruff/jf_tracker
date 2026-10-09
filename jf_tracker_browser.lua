-- jf_tracker_browser.lua — сайдбар-браузер (справа от трекера).
--
-- Вкладки: `pm` — проекты из индекса jf_pm (Enter — внутрь проекта как в папку:
-- tracks (Enter/drag — вставить трек chunk'ом), samples (как файлы), regions
-- (Enter/drag — сабпроект, обрезанный по региону), markers; drag проекта → сабпроект,
-- Space — рендер проекта), `auto` — автопревью строки под курсором; строку
-- можно тащить мышью на колонку трека: файл → item в строке, .rpp → сабпроект.
-- `files` — папки и аудио-файлы корня (`:browse <путь>`, по
-- умолчанию ~/samples, ExtState jf_tracker/browse); `db` — базы Media
-- Explorer REAPER: список из reaper.ini [reaper_sexplorer] (ShortcutN =
-- NN.ReaperFileList, подпись ShortcutTN), файлы — из MediaDB/NN.ReaperFileList
-- (строки FILE "путь", DATA l:длина), разбор кешируется по базе. Кнопки в
-- шапке: files / db, `<>` — узкий/широкий сайдбар, `x` — спрятать (:side).
-- Фокус — по Tab (трекер → матрица → браузер). j/k — курсор, Enter — войти в
-- папку / базу или добавить файл в трек DEPOT (он становится инструментом
-- пула), Backspace или `-` — наверх, Space — прослушать (1 с через трек
-- курсора), `/` — фильтр по имени (набор, Enter/Esc — закончить, Esc при
-- пустом фильтре — снять), `t` — сменить вкладку, `w` — ширина, `q` —
-- спрятать, Tab — назад.
-- Чтение диска — EnumerateSubdirectories / EnumerateFiles / io.open; это не
-- reaper.* проекта, модель не трогается.

local B = {}
local R = reaper
local ctx

B.root = nil
B.path = nil
B.entries = {}      -- показанные строки (после фильтра)
B.all = {}          -- строки текущего места без фильтра
B.cur = 1
B.scroll = 0
B.focus = false
B.mode = 'files'    -- 'files' | 'db' | 'pm'
B.pm = nil          -- карточки jf_pm (ленивое чтение индекса jf_pm_index.json)
B.grid = true       -- pm как сетка карточек (jf_tracker_pm, 6 окт); false — список
B.grid_cols = 1     -- колонок в сетке (ставит отрисовка, читают клавиши / колесо)
B.pm_sort = (R.GetExtState and R.GetExtState('jf_tracker', 'pmsort') ~= '' and R.GetExtState('jf_tracker', 'pmsort')) or 'date'
B.pm_daw = (R.GetExtState and R.GetExtState('jf_tracker', 'pmdaw') ~= '' and R.GetExtState('jf_tracker', 'pmdaw')) or 'all'
B.pm_scroll = { v = 0 }   -- прокрутка сетки в рядах
B.auto = true       -- автопревью: курсор на файле → слушаем (кнопка play; по умолчанию вкл, 5 окт)
B.keys = false      -- клавиатура играет выбранный файл с высотой (кнопка keys, 5 окт)
B.drag = nil        -- перетаскивание: { e=, x0=, y0=, active= }
B.db = nil          -- открытая база { file=, title= } или nil (список баз)
B.dbs = nil         -- базы из reaper.ini (ленивое чтение)
B.dbcache = {}      -- file → список файлов базы
B.filter = ''       -- подстрока фильтра (без регистра)
B.filtering = false -- идёт набор фильтра
B.pmproj = nil      -- открытый проект pm: { e=, dir=, tracks=, samples=, regions=, markers= }
B.pmdir = nil       -- подпапка внутри проекта: 'tracks' | 'samples' | 'regions' | 'markers'
B.wave = false      -- мини-волны у файлов (кнопка wave)
-- навигация по папкам (2 окт): история назад / вперёд (< > и H L), закладки
-- 1..5 (клик по пустой — запомнить текущую папку, по занятой — перейти;
-- Shift+клик — перезаписать, Cmd+клик — очистить; клавиши 1..5 / Shift+1..5),
-- * — новая папка (:mkdir), строка пути под кнопками: клик по папке — туда
B.back, B.fwd = {}, {}
-- *.* — все файлы, не только звук; .* — скрытые (имя с точки); 2 окт, сохраняются
B.all_files = R.GetExtState and R.GetExtState('jf_tracker', 'brall') == '1' or false
-- прослушивание через выделенный трек (кнопка track, 2 окт); по умолчанию включено
B.via_track = not (R.GetExtState and R.GetExtState('jf_tracker', 'brtrack') == '0')
-- sync (3 окт): пока проект играет, прослушивание файла стартует с начала следующего такта
B.sync = R.GetExtState and R.GetExtState('jf_tracker', 'brsync') == '1'
B.hidden = R.GetExtState and R.GetExtState('jf_tracker', 'brhid') == '1' or false
B.marks = {}
B.crumbs = {}       -- сегменты пути последней отрисовки { label=, path= }
-- закладок 10 (5 окт): 1..9 и 0; Shift — перезаписать
B.NMARKS = 10
local MARK_SHIFT = { ['!'] = 1, ['@'] = 2, ['#'] = 3, ['$'] = 4, ['%'] = 5, ['^'] = 6, ['&'] = 7, ['*'] = 8, ['('] = 9, [')'] = 10 }
local function load_marks()
  for i = 1, B.NMARKS do
    local v = R.GetExtState and R.GetExtState('jf_tracker', 'bmark' .. i) or ''
    B.marks[i] = (v ~= '' and v) or nil
  end
end

local AUDIO = { wav = true, aif = true, aiff = true, flac = true, mp3 = true, ogg = true, m4a = true, wv = true, caf = true,
                rx2 = true, rex = true, xrni = true, jfcurve = true }   -- jfcurve — кривые automation (6 окт)   -- REX / Renoise-Redux: Enter = импорт с нарезкой (2 окт)
local function shown(name) return B.hidden or name:sub(1, 1) ~= '.' end
local function wanted(name)
  local ext = name:match('%.([%w]+)$')
  return B.all_files or (ext ~= nil and AUDIO[ext:lower()] == true)
end

function B.init(c, root)
  ctx = c
  -- ~/samples, если есть; иначе домашняя папка (релиз 5 окт)
  local home = os.getenv('HOME') or '/'
  local has = function(d) return reaper.EnumerateFiles and (reaper.EnumerateFiles(d, 0) or reaper.EnumerateSubdirectories(d, 0)) end
  B.root = root or (has(home .. '/samples') and (home .. '/samples') or home)
  B.path = B.root
  load_marks()
  B.refresh()
end

-- ── zoxide (9 окт): частота × давность заходов в папки ─────────────────
-- Каждый заход в папку (B.go) — очко ей; ранг = очки × множитель давности
-- (как zoxide: час ×4, день ×2, неделя ×0.5, старше ×0.25). Сумма очков
-- больше B.ZMAX — всё ×0.9, совсем малые забываются. База — текст
-- Data/jf_tracker_z.txt «очки<TAB>время<TAB>путь». :z слова — прыжок,
-- :zi — список (fzf). Слова — по порядку в пути, последнее — в имени папки.
B.ZMAX = 10000
function B.zrank(e, now)
  local age = now - (e.t or 0)
  local k = age < 3600 and 4 or (age < 86400 and 2 or (age < 604800 and 0.5 or 0.25))
  return (e.n or 0) * k
end
-- лучшие пути под слова; exists(path) → bool (проверка, что папка жива)
function B.zquery(db, words, now, exists, cur)
  local out = {}
  for path, e in pairs(db) do
    if path ~= cur then
      local lp, pos, ok = path:lower(), 1, true
      for i, w in ipairs(words) do
        local a, b = lp:find(w:lower(), pos, true)
        if not a then ok = false; break end
        pos = b + 1
        if i == #words then
          local last = lp:match('([^/]+)/?$') or lp
          if not last:find(w:lower(), 1, true) then ok = false end
        end
      end
      if ok and (not exists or exists(path)) then out[#out + 1] = { path = path, rank = B.zrank(e, now) } end
    end
  end
  table.sort(out, function(a, b) if a.rank ~= b.rank then return a.rank > b.rank end return a.path < b.path end)
  return out
end
function B.zadd(db, path, now)
  -- сначала старение (сумма с новым очком больше предела), потом очко —
  -- только что открытая папка не забывается
  local sum = 1
  for _, x in pairs(db) do sum = sum + x.n end
  if sum > B.ZMAX then
    for p, x in pairs(db) do x.n = x.n * 0.9; if x.n < 1 then db[p] = nil end end
  end
  local e = db[path]
  if not e then e = { n = 0 }; db[path] = e end
  e.n, e.t = e.n + 1, now
end
local function zfile() return R.GetResourcePath and (R.GetResourcePath() .. '/Data/jf_tracker_z.txt') or nil end
function B.zload()
  if B.zdb then return B.zdb end
  B.zdb = {}
  local f = zfile() and io.open(zfile(), 'r')
  if f then
    for line in f:lines() do
      local n, t, p = line:match('^([%d%.]+)\t(%d+)\t(.+)$')
      if n then B.zdb[p] = { n = tonumber(n), t = tonumber(t) } end
    end
    f:close()
  end
  return B.zdb
end
function B.zsave()
  local fn = zfile()
  if not (fn and B.zdb) then return end
  if R.RecursiveCreateDirectory then R.RecursiveCreateDirectory(R.GetResourcePath() .. '/Data', 0) end
  local f = io.open(fn, 'w')
  if not f then return end
  for p, e in pairs(B.zdb) do f:write(('%.2f\t%d\t%s\n'):format(e.n, e.t or 0, p)) end
  f:close()
end
local function dir_exists(p) return R.EnumerateFiles and (R.EnumerateFiles(p, 0) ~= nil or R.EnumerateSubdirectories(p, 0) ~= nil) end
-- :z слова → прыжок; nil — нет совпадений
function B.z(words)
  local list = B.zquery(B.zload(), words, os.time(), dir_exists, B.path)
  if list[1] then B.go(list[1].path); return list[1].path end
  return nil
end
function B.zlist()
  return B.zquery(B.zload(), {}, os.time(), dir_exists, nil)
end

-- перейти в папку (с записью в историю)
function B.go(path, no_hist)
  if not path or path == '' or path == B.path then return end
  B.zadd(B.zload(), path, os.time()); B.zsave()      -- zoxide: заход в папку
  if not no_hist then
    B.back[#B.back + 1] = B.path
    if #B.back > 100 then table.remove(B.back, 1) end
    B.fwd = {}
  end
  if B.mode ~= 'files' then B.mode = 'files'; B.pmproj, B.pmdir, B.db = nil, nil, nil end
  B.path = path; B.cur = 1; B.filter = ''; B.filtering = false
  B.refresh()
end
function B.history(d)
  local from, to = d < 0 and B.back or B.fwd, d < 0 and B.fwd or B.back
  local p = table.remove(from)
  if not p then if ctx.msg then ctx.msg(d < 0 and 'no folder back' or 'no folder forward') end; return end
  to[#to + 1] = B.path
  B.go(p, true)
end
function B.mark(i, how)
  if how == 'set' or (how == nil and not B.marks[i]) then
    B.marks[i] = B.path
    if R.SetExtState then R.SetExtState('jf_tracker', 'bmark' .. i, B.path, true) end
    if ctx.msg then ctx.msg(('bookmark %d = %s'):format(i, B.path)) end
  elseif how == 'clear' then
    B.marks[i] = nil
    if R.DeleteExtState then R.DeleteExtState('jf_tracker', 'bmark' .. i, true) end
    if ctx.msg then ctx.msg(('bookmark %d cleared'):format(i)) end
  else B.go(B.marks[i]) end
end
-- новая папка в текущей (имя из :mkdir)
function B.mkdir(name)
  name = (name or ''):gsub('^%s+', ''):gsub('%s+$', ''):gsub('/', '-')
  if name == '' then if ctx.msg then ctx.msg('mkdir: give a name') end; return false end
  local p = B.path .. '/' .. name
  R.RecursiveCreateDirectory(p, 0)
  B.refresh()
  for i, e in ipairs(B.entries) do if e.dir and e.name == name then B.cur = i end end
  if ctx.msg then ctx.msg('folder created: ' .. p) end
  return true
end
-- сегменты полного пути: «/», «Users», … (клик — перейти)
function B.path_parts(path)
  local out = { { label = '/', path = '/' } }
  local acc = ''
  for seg in path:gmatch('[^/]+') do
    acc = acc .. '/' .. seg
    out[#out + 1] = { label = seg, path = acc }
  end
  return out
end

function B.refresh()
  local out = {}
  local i = 0
  while true do
    local d = R.EnumerateSubdirectories(B.path, i)
    if not d then break end
    if shown(d) then out[#out + 1] = { name = d, dir = true } end
    i = i + 1
  end
  table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
  local files = {}
  i = 0
  while true do
    local f = R.EnumerateFiles(B.path, i)
    if not f then break end
    local ext = f:match('%.([%w]+)$')
    if shown(f) and wanted(f) then
      files[#files + 1] = { name = f, dir = false, other = not (ext and AUDIO[ext:lower()]) or nil }
    end
    i = i + 1
  end
  table.sort(files, function(a, b) return a.name:lower() < b.name:lower() end)
  for _, f in ipairs(files) do out[#out + 1] = f end
  B.set_all(out)
end

-- ── поиск прямо в списке (fzf-синтаксис, 2 окт) ─────────────────────────
-- Контекст: в папке (files) — рекурсивно от ТЕКУЩЕЙ папки (индекс на папку,
-- строится при первом символе, до 20000 строк); в открытой базе — по базе;
-- список баз / pm / proj — по текущему списку. Термы через пробел — все
-- должны совпасть: обычный — нечётко (подпоследовательность, бонус за начало
-- слова и подряд), 'text — точная подстрока, ^text — начало имени,
-- text$ — конец имени, !text — исключить.
local function fz(hay, q)
  local score, pos, prev = 0, 1, -1
  for i = 1, #q do
    local c = q:sub(i, i)
    local f = hay:find(c, pos, true)
    if not f then return nil end
    score = score + ((f == prev + 1) and 5 or 1) - math.min(f - pos, 20) * 0.05
    if f == 1 or hay:sub(f - 1, f - 1):match('[/%s_%-%.%(%)%[%]]') then score = score + 3 end
    prev, pos = f, f + 1
  end
  return score - #hay * 0.01
end
local function fmatch(e, terms)
  local hay = (e.label or e.name):lower()
  local base = (e.name:match('[^/]+$') or e.name):lower()
  local total = 0
  for _, t0 in ipairs(terms) do
    local t, neg = t0, false
    if t:sub(1, 1) == '!' then neg, t = true, t:sub(2) end
    local sc
    if t == '' then sc = 0
    elseif t:sub(1, 1) == "'" then sc = hay:find(t:sub(2), 1, true) and 10 or nil
    elseif t:sub(1, 1) == '^' then sc = (base:sub(1, #t - 1) == t:sub(2)) and 10 or nil
    elseif #t > 1 and t:sub(-1) == '$' then local s = t:sub(1, -2); sc = (base:sub(-#s) == s) and 10 or nil
    else sc = fz(hay, t) end
    if neg then if sc then return nil end
    else if not sc then return nil end; total = total + sc end
  end
  return total
end

B.findidx = {}
-- рекурсивный индекс папки (относительные пути, папки тоже)
function B.folder_index(path)
  local idx = B.findidx[path]
  if idx then return idx end
  idx = {}
  local function scan(dir, rel, depth)
    if #idx >= 20000 or depth > 12 then return end
    local i = 0
    while true do
      local d = R.EnumerateSubdirectories(dir, i)
      if not d then break end
      if shown(d) then
        local r = (rel ~= '' and (rel .. '/') or '') .. d
        idx[#idx + 1] = { name = r, label = r, path = dir .. '/' .. d, dir = true }
        scan(dir .. '/' .. d, r, depth + 1)
      end
      i = i + 1
    end
    i = 0
    while true do
      local f = R.EnumerateFiles(dir, i)
      if not f then break end
      local ext = f:match('%.([%w]+)$')
      if shown(f) and wanted(f) then
        local r = (rel ~= '' and (rel .. '/') or '') .. f
        idx[#idx + 1] = { name = r, label = r, path = dir .. '/' .. f, dir = false }
      end
      i = i + 1
    end
  end
  scan(path, '', 0)
  B.findidx[path] = idx
  return idx
end

-- применить запрос к B.all → B.entries (запрос пуст — обычный список)
function B.set_all(list)
  B.all = list
  local q = B.filter:lower()
  if q == '' then B.entries = list
  else
    local src = (B.mode == 'files' and B.path) and B.folder_index(B.path) or list
    local terms = {}
    for t in q:gmatch('%S+') do terms[#terms + 1] = t end
    local hits = {}
    for _, e in ipairs(src) do
      local sc = fmatch(e, terms)
      if sc then hits[#hits + 1] = { e = e, sc = sc } end
    end
    table.sort(hits, function(a, b) return a.sc > b.sc end)
    B.entries = {}
    for i = 1, math.min(#hits, 3000) do B.entries[i] = hits[i].e end
  end
  if B.cur > #B.entries then B.cur = math.max(1, #B.entries) end
  if B.cur < 1 then B.cur = 1 end
  B.scroll = 0
end

-- начать поиск в списке (/ или кнопка find)
function B.start_find()
  B.filtering = true; B.filter = ''; B.cur = 1
  B.set_all(B.all)
end

-- ── базы Media Explorer ───────────────────────────────────────────────────
local function res_path() return R.GetResourcePath and R.GetResourcePath() or (os.getenv('HOME') .. '/Library/Application Support/REAPER') end

function B.read_dbs()
  local dbs = {}
  local fh = io.open(res_path() .. '/reaper.ini', 'r')
  if fh then
    local sect = false
    local files, titles = {}, {}
    for line in fh:lines() do
      local h = line:match('^%[(.-)%]')
      if h then sect = (h == 'reaper_sexplorer')
      elseif sect then
        local n, v = line:match('^Shortcut(%d+)=(.+)$')
        if n and v:match('%.ReaperFileList$') then files[n] = v end
        local tn, tv = line:match('^ShortcutT(%d+)=(.+)$')
        if tn then titles[tn] = tv end
      end
    end
    fh:close()
    local keys = {}
    for n in pairs(files) do keys[#keys + 1] = n end
    table.sort(keys, function(a, b) return tonumber(a) < tonumber(b) end)
    for _, n in ipairs(keys) do
      dbs[#dbs + 1] = { name = (titles[n] or files[n]):gsub('^DB: ', ''), file = files[n], dir = true, db = true }
    end
  end
  return dbs
end

-- файлы базы: FILE "путь" … / DATA … l:м:сс.ссс …
function B.read_db(file)
  local cached = B.dbcache[file]
  if cached then return cached end
  local out = {}
  local fh = io.open(res_path() .. '/MediaDB/' .. file, 'r')
  if fh then
    local last
    for line in fh:lines() do
      local path = line:match('^FILE "(.-)"')
      if path then
        last = { name = path:match('[^/]+$') or path, path = path, dir = false }
        out[#out + 1] = last
      elseif last and line:sub(1, 5) == 'DATA ' then
        local m, sec = line:match(' l:(%d+):([%d%.]+)')
        if m then last.len = tonumber(m) * 60 + tonumber(sec) end
      end
    end
    fh:close()
  end
  table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
  B.dbcache[file] = out
  return out
end

function B.refresh_db()
  if B.db then B.set_all(B.read_db(B.db.file))
  else B.dbs = B.read_dbs(); B.set_all(B.dbs) end
end

-- ── jf_pm: проекты из индекса менеджера проектов ─────────────────────────
-- jf_pm_core.lua (Scripts/jf_pm) читает jf_pm_index.json; карточка: name,
-- path, mtime, duration, render_file, track_names. Сортировка — по mtime (свежие сверху).
-- модуль карточек (6 окт): есть, когда главный отдал ctx.pm_mod и опция pm cards
local function PMm() return ctx and ctx.pm_mod and ctx.pm_cards and ctx.pm_cards() and ctx.pm_mod() or nil end
B.pm_mod = PMm
function B.read_pm()
  if B.pm then return B.pm end
  local PM = PMm()
  if PM then
    -- индекс в памяти, читается по кускам; пока грузится — пустой список
    PM.ensure()
    PM.on_ready = function() B.pm = nil; if B.mode == 'pm' and not B.pmproj then B.set_all(B.read_pm()) end end
    if not PM.ready then B.pm_loading = true; return {} end
    B.pm_loading = nil
    B.pm_folders = nil
    B.pm = PM.sort(PM.entries(PM.idx, { daw = B.pm_daw }), B.pm_sort)
    if #B.pm == 0 and PM.empty then B.pm_folders = true; B.pm = B.read_pm_folder() end
    return B.pm
  end
  local out = {}
  local dir = res_path() .. '/Scripts/jf_pm'
  local ok, core = pcall(dofile, dir .. '/jf_pm_core.lua')
  if ok and type(core) == 'table' and core.load_index then
    local ok2, idx = pcall(core.load_index)
    if ok2 and idx and idx.projects then
      for path, c in pairs(idx.projects) do
        local ext = (path:match('%.(%w+)$') or ''):lower()
        local base = path:match('[^/]+$') or ''
        if ext == 'rpp' and base:sub(1, 1) ~= '.' and not base:find('TemporaryUnsaved', 1, true) then
          -- мета карточки (3 окт): темп, тональности, теги (Finder + свои), статус —
          -- видны справа от имени и ищутся поиском списка
          local meta = {}
          local bpm = core.card_bpm and core.card_bpm(c)
          if bpm then meta[#meta + 1] = math.floor(bpm + 0.5) .. 'bpm' end
          if type(c.keys) == 'table' and #c.keys > 0 then meta[#meta + 1] = table.concat(c.keys, ' ') end
          if type(c.fs_tags) == 'table' then for t in pairs(c.fs_tags) do meta[#meta + 1] = '#' .. t end end
          if type(c.tags_extra) == 'table' then for _, t in ipairs(c.tags_extra) do meta[#meta + 1] = '#' .. t end
          elseif type(c.tags_extra) == 'string' and c.tags_extra ~= '' then meta[#meta + 1] = '#' .. c.tags_extra end
          local st = c.status_over or (c.ext or {}).STATUS   -- статус .rpp — в ext (6 окт)
          if st and st ~= '' then meta[#meta + 1] = '[' .. st .. ']' end
          local nm = c.name or (path:match('[^/]+$') or path)
          local ms = table.concat(meta, ' ')
          out[#out + 1] = { name = nm, path = path, pm = true, dir = false, meta = ms ~= '' and ms or nil,
                            label = ms ~= '' and (nm .. ' ' .. ms) or nil,
                            mtime = tonumber(c.mtime) or 0, len = tonumber(c.duration),
                            render = c.render_file ~= '' and c.render_file or nil, tracks = c.track_names }
        end
      end
    end
  end
  table.sort(out, function(a, b) return a.mtime > b.mtime end)
  -- без jf_pm (5 окт): индекса нет или он пуст — папки и .rpp по диску, с папки
  -- проектов REAPER по умолчанию; Enter — внутрь папки / проекта, h — выше
  if #out == 0 then
    B.pm_folders = true
    out = B.read_pm_folder()
  else B.pm_folders = nil end
  B.pm = out
  return out
end

-- папка проектов по умолчанию: Options → Paths (defsavepath), иначе
-- ~/Documents/REAPER Media, иначе домашняя
function B.pm_root()
  local home = os.getenv('HOME') or '/'
  local p = R.get_config_var_string and select(2, R.get_config_var_string('defsavepath'))
  if p and p ~= '' then return p end
  local media = home .. '/Documents/REAPER Media'
  if R.EnumerateSubdirectories and (R.EnumerateSubdirectories(media, 0) or R.EnumerateFiles(media, 0)) then return media end
  return home
end

function B.read_pm_folder()
  B.pmfolder = B.pmfolder or B.pm_root()
  local dir, out = B.pmfolder, {}
  local i = 0
  while R.EnumerateSubdirectories do
    local d = R.EnumerateSubdirectories(dir, i)
    if not d then break end
    if d:sub(1, 1) ~= '.' then out[#out + 1] = { name = d, dir = true, pmfolder = dir .. '/' .. d } end
    i = i + 1
  end
  table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
  local files = {}
  i = 0
  while R.EnumerateFiles do
    local f = R.EnumerateFiles(dir, i)
    if not f then break end
    if f:lower():match('%.rpp$') and f:sub(1, 1) ~= '.' and not f:find('TemporaryUnsaved', 1, true) then
      files[#files + 1] = { name = f:gsub('%.[Rr][Pp][Pp]$', ''), path = dir .. '/' .. f, pm = true, dir = false, mtime = 0 }
    end
    i = i + 1
  end
  table.sort(files, function(a, b) return a.name:lower() < b.name:lower() end)
  for _, f in ipairs(files) do out[#out + 1] = f end
  return out
end

-- правка карточки jf_pm (3 окт): теги (tags_extra) и статус (status_over —
-- поверх STATUS из .rpp, как в канбане jf_pm); пишется индекс jf_pm_index.json
-- ядром jf_pm. fn(card) правит карточку; true — записано
function B.pm_core()
  local ok, core = pcall(dofile, res_path() .. '/Scripts/jf_pm/jf_pm_core.lua')
  return ok and type(core) == 'table' and core.load_index and core or nil
end
function B.pm_edit(path, fn)
  local PM = PMm()
  if PM and PM.ready then
    -- индекс в памяти: правка сразу, запись отложенно (PM.flush)
    if not PM.edit(path, fn) then return false end
    for _, e in ipairs(B.pm or {}) do if e.path == path then local ne = PM.entry(path, e.card); for k, v in pairs(ne) do e[k] = v end end end
    if B.mode == 'pm' and not B.pmproj then B.set_all(B.pm or B.read_pm()) end
    return true
  end
  local core = B.pm_core()
  if not core then return false end
  local idx = core.load_index()
  local card = idx and idx.projects and idx.projects[path]
  if not card then return false end
  fn(card)
  -- безопасная запись: JSON собирается заранее (save_index открывает файл до
  -- кодирования — ошибка оставила бы пустой индекс), прежний — в .bak
  local okj = pcall(core.json_encode, idx)
  if not okj then return false end
  local src = io.open(core.index_path(), 'rb')
  if src then
    local data = src:read('*a'); src:close()
    local bak = io.open(core.index_path() .. '.bak', 'wb')
    if bak then bak:write(data); bak:close() end
  end
  core.save_index(idx)
  B.pm = nil                                   -- перечитать мету
  if B.mode == 'pm' and not B.pmproj then B.set_all(B.read_pm()) end
  return true
end
function B.pm_card(path)
  local PM = PMm()
  if PM and PM.ready then return PM.card(path), { STATUSES = PM.STATUSES, STATUS_EN = PM.STATUS_EN } end
  local core = B.pm_core()
  local idx = core and core.load_index()
  return idx and idx.projects and idx.projects[path], core
end

-- файл для прослушивания проекта: рендер из карточки, иначе jf_preview.wav рядом
function B.pm_preview(e)
  local PM = PMm()
  if PM and e.card then return PM.find_audio(e.card) end
  if e.render and e.render ~= '' then return e.render end
  local dir = e.path:match('^(.*)/[^/]+$')
  local f = dir and io.open(dir .. '/jf_preview.wav', 'rb')
  if f then f:close(); return dir .. '/jf_preview.wav' end
  return nil
end

-- ── внутрь проекта: .rpp как папка (tracks / samples / regions / markers) ──
-- Текст проекта читается напрямую: блоки <TRACK …> верхнего уровня (имя из
-- NAME, FILE внутри — абсолютизируются относительно папки проекта, сырой
-- chunk — для вставки трека через SetTrackStateChunk), регионы и маркеры —
-- строки MARKER (flags&1 = регион: пара строк начало/конец).
function B.scan_project(path)
  local fh = io.open(path, 'rb'); if not fh then return nil end
  local dir = path:match('^(.*)/[^/]+$') or '.'
  local proj = { tracks = {}, samples = {}, regions = {}, markers = {} }
  local depth, cur, seen = 0, nil, {}
  local region_open = {}
  local function absf(f) if f:sub(1, 1) == '/' then return f end; return dir .. '/' .. f end
  for line in fh:lines() do
    local st = line:match('^%s*(.-)%s*$')
    local first = st:sub(1, 1)
    if first == '<' then
      depth = depth + 1
      if depth == 2 and st:match('^<TRACK') then cur = { name = '', lines = { line }, files = {} } end
      if cur and depth > 2 then cur.lines[#cur.lines + 1] = line end
    elseif st == '>' then
      if cur and depth == 2 then
        cur.lines[#cur.lines + 1] = line
        cur.chunk = table.concat(cur.lines, '\n')
        cur.lines = nil
        proj.tracks[#proj.tracks + 1] = { name = cur.name ~= '' and cur.name or ('track ' .. (#proj.tracks + 1)), chunk = cur.chunk, nfiles = #cur.files, trk = true, dir = false }
        cur = nil
      elseif cur then cur.lines[#cur.lines + 1] = line end
      depth = depth - 1
    else
      if cur then
        if depth == 2 and cur.name == '' then local nm = st:match('^NAME%s+"(.-)"') or st:match('^NAME%s+(%S+)'); if nm then cur.name = nm end end
        local f = st:match('^FILE%s+"(.-)"') or st:match('^FILE%s+(%S+)')
        if f then
          local af = absf(f)
          cur.files[#cur.files + 1] = af
          if not seen[af] then seen[af] = true; proj.samples[#proj.samples + 1] = { name = af:match('[^/]+$') or af, path = af, dir = false } end
          -- в chunk путь должен быть абсолютным, иначе вставленный трек потеряет медиа
          if f ~= af then cur.lines[#cur.lines] = line:gsub('FILE%s+"?' .. f:gsub('%p', '%%%0') .. '"?', 'FILE "' .. af .. '"', 1) end
        else cur.lines[#cur.lines] = line end
      end
      if depth == 1 then
        local id, pos, nm, flags = st:match('^MARKER%s+(%d+)%s+([%d%.%-]+)%s+"(.-)"%s+(%d+)')
        if not id then id, pos, nm, flags = st:match('^MARKER%s+(%d+)%s+([%d%.%-]+)%s+(%S+)%s+(%d+)') end
        if id then
          pos, flags = tonumber(pos), tonumber(flags) or 0
          if flags & 1 == 1 then
            if region_open[id] then region_open[id].fin = pos; region_open[id] = nil
            else local r = { name = nm, pos = pos, fin = pos, rgn = true, dir = false }; region_open[id] = r; proj.regions[#proj.regions + 1] = r end
          else proj.markers[#proj.markers + 1] = { name = nm, pos = pos, mark = true, dir = false } end
        end
      end
    end
  end
  fh:close()
  for _, r in ipairs(proj.regions) do r.name = ('%s  %.1fs'):format(r.name ~= '' and r.name or 'region', r.fin - r.pos) end
  for _, m in ipairs(proj.markers) do m.name = ('%s  @%.1fs'):format(m.name ~= '' and m.name or 'marker', m.pos) end
  return proj
end

function B.pm_open(e)
  local proj = B.scan_project(e.path)
  if not proj then B.filter = ''; return false end
  proj.e = e
  B.pmproj, B.pmdir = proj, nil
  B.cur = 1; B.filter = ''; B.filtering = false
  B.refresh_pm()
  return true
end

function B.refresh_pm()
  local pr = B.pmproj
  if not pr then B.set_all(B.read_pm()); return end
  if not B.pmdir then
    B.set_all({ { name = ('tracks (%d)'):format(#pr.tracks), dir = true, pmdir = 'tracks' },
                { name = ('samples (%d)'):format(#pr.samples), dir = true, pmdir = 'samples' },
                { name = ('regions (%d)'):format(#pr.regions), dir = true, pmdir = 'regions' },
                { name = ('markers (%d)'):format(#pr.markers), dir = true, pmdir = 'markers' } })
  else B.set_all(pr[B.pmdir] or {}) end
end

-- ── proj: все аудио-источники текущего проекта (как Project Bay: у Bay нет
-- ReaScript API, а то, что реально используется, — это items проекта, в том
-- числе библиотека после =LIB). Уникальные по файлу; трек и число items.
-- наборы lib (4 окт): шаблоны треков TrackTemplates/jf_kits; Enter — в lib трека
function B.read_kits()
  local out = {}
  local dir = res_path() .. '/TrackTemplates/jf_kits'
  local i = 0
  while true do
    local fn = R.EnumerateFiles and R.EnumerateFiles(dir, i)
    if not fn then break end
    if fn:lower():match('%.rtracktemplate$') then out[#out + 1] = { name = fn:gsub('%.[Rr][Tt]rack[Tt]emplate$', ''), path = dir .. '/' .. fn, kit = true } end
    i = i + 1
  end
  table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
  if #out == 0 then out[1] = { name = '(no kits yet - save button in the lib)', kit = false, dir = false, empty = true } end
  return out
end

function B.read_proj()
  local seen, out = {}, {}
  for i = 0, R.CountMediaItems(0) - 1 do
    local it = R.GetMediaItem(0, i)
    local tk = R.GetActiveTake(it)
    if tk and not R.TakeIsMIDI(tk) then
      local src = R.GetMediaItemTake_Source(tk)
      local fn = src and R.GetMediaSourceFileName(src, '') or ''
      if fn ~= '' then
        local e = seen[fn]
        if not e then
          local tr = R.GetMediaItem_Track(it)
          local _, tn = R.GetTrackName(tr)
          e = { name = fn:match('[^/]+$') or fn, path = fn, dir = false, proj = true, n = 0, track = tn }
          seen[fn] = e; out[#out + 1] = e
        end
        e.n = e.n + 1
      end
    end
  end
  table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
  return out
end

-- вкладка fx (7 окт, опция browser left): список эффектов внутри браузера —
-- рисует main (B.fx_draw), hover — в B.fx_hover
B.fx_draw, B.fx_hover = nil, nil
function B.set_mode(m)
  if m == 'fx' and B.fx_draw then B.mode = 'fx'; return end
  if m ~= 'files' and m ~= 'db' and m ~= 'pm' and m ~= 'proj' and m ~= 'kits' then return end
  B.mode = m; B.cur = 1; B.filter = ''; B.filtering = false
  B.pmproj, B.pmdir = nil, nil
  B.pm_scroll.v = 0
  if m == 'files' then B.refresh() elseif m == 'db' then B.refresh_db() elseif m == 'proj' then B.set_all(B.read_proj()) elseif m == 'kits' then B.set_all(B.read_kits()) else B.set_all(B.read_pm()) end
end

-- кнопки шапки: files | db | size | hide
function B.click(what)
  if what == 'files' or what == 'db' or what == 'pm' or what == 'proj' or what == 'kits' or what == 'fx' then B.set_mode(what)
  elseif what == 'auto' then B.auto = not B.auto
  elseif what == 'keys' then B.keys = not B.keys
  elseif what == 'pvvol' then B.vol_drag = true
  elseif what == 'pvwave' then if B.pv_path and ctx.preview_from then ctx.preview_from(B.pv_path, B.pv_frac or 0) end
  elseif what == 'find' then B.start_find(); if ctx.set_focus then ctx.set_focus('browser') end
  elseif what == 'wave' then B.wave = not B.wave
  elseif what == 'track' then
    B.via_track = not B.via_track
    if R.SetExtState then R.SetExtState('jf_tracker', 'brtrack', B.via_track and '1' or '0', true) end
    if ctx.msg then ctx.msg(B.via_track and 'listen through the selected track (its FX)' or 'listen direct (no track FX)') end
  elseif what == 'sync' then
    B.sync = not B.sync
    if R.SetExtState then R.SetExtState('jf_tracker', 'brsync', B.sync and '1' or '0', true) end
    if ctx.msg then ctx.msg(B.sync and 'sync: while the project plays, files start on the next bar' or 'sync off: files start at once') end
  elseif what == 'allfiles' or what == 'hidden' then
    if what == 'allfiles' then B.all_files = not B.all_files else B.hidden = not B.hidden end
    if R.SetExtState then
      R.SetExtState('jf_tracker', 'brall', B.all_files and '1' or '0', true)
      R.SetExtState('jf_tracker', 'brhid', B.hidden and '1' or '0', true)
    end
    B.findidx = {}
    if B.mode == 'files' then B.refresh() end
    if ctx.msg then ctx.msg(('browser: %s, hidden files %s'):format(B.all_files and 'all files' or 'audio only', B.hidden and 'shown' or 'hidden')) end
  elseif what == 'back' then B.history(-1)
  elseif what == 'fwd' then B.history(1)
  elseif what == 'mkdir' then if ctx.browser_mkdir_prompt then ctx.browser_mkdir_prompt() end
  elseif what:match('^bm%d+$') then
    local m = ctx.mods and ctx.mods() or {}
    B.mark(tonumber(what:sub(3)), m.cmd and 'clear' or (m.shift and 'set' or nil))
  elseif what:match('^crumb%d+$') then
    local c = B.crumbs[tonumber(what:match('%d+'))]
    if c then B.go(c.path) end
  -- pm-сетка (6 окт): вид, сортировка, фильтр DAW, big
  elseif what == 'pmgrid' or what == 'pmlist' then B.grid = what == 'pmgrid'; B.pm_scroll.v = 0; B.scroll = 0
  elseif what == 'pmsort' then
    local PM = PMm(); local L = PM and PM.SORTS or { 'date' }
    local k = 1; for i, v in ipairs(L) do if v == B.pm_sort then k = i end end
    B.pm_sort = L[k % #L + 1]
    if R.SetExtState then R.SetExtState('jf_tracker', 'pmsort', B.pm_sort, true) end
    local cur = B.entries[B.cur]
    B.pm = nil; B.set_all(B.read_pm())
    if cur then for i, e in ipairs(B.entries) do if e.path == cur.path then B.cur = i; break end end end
    if ctx.msg then ctx.msg('pm: sort by ' .. B.pm_sort .. (B.pm_sort == 'date' and ' (newest first, pinned on top)' or '')) end
  elseif what == 'pmdaw' then
    local PM = PMm(); local L = PM and PM.DAWS or { 'all' }
    local k = 1; for i, v in ipairs(L) do if v == B.pm_daw then k = i end end
    B.pm_daw = L[k % #L + 1]
    if R.SetExtState then R.SetExtState('jf_tracker', 'pmdaw', B.pm_daw, true) end
    B.pm = nil; B.cur = 1; B.set_all(B.read_pm())
    if ctx.msg then ctx.msg('pm: ' .. ({ all = 'all projects', rpp = 'REAPER projects only', other = 'other DAWs only' })[B.pm_daw]) end
  elseif what == 'pmbig' then if ctx.pm_big then ctx.pm_big() end
  elseif what == 'pmshape' then
    local PM = PMm(); if PM then PM.shape = PM.next_shape(PM.shape); B.pm_scroll.v = 0; PM.invalidate(); if ctx.msg then ctx.msg('pm cards: ' .. PM.shape) end; if R.SetExtState then R.SetExtState('jf_tracker', 'pmshape', PM.shape, true) end end
  elseif what == 'size' then if ctx.side_toggle_width then ctx.side_toggle_width() end
  elseif what == 'hide' then if ctx.side_hide then ctx.side_hide() end end
end

function B.full(e)
  if e.path then return e.path end
  return B.path .. '/' .. e.name
end

function B.enter()
  local e = B.entries[B.cur]
  if not e then return end
  if e.db then B.db = e; B.cur = 1; B.filter = ''; B.refresh_db()
  elseif e.pmdir then B.pmdir = e.pmdir; B.cur = 1; B.filter = ''; B.refresh_pm()
  elseif e.pmfolder then B.pmfolder = e.pmfolder; B.pm = nil; B.cur = 1; B.filter = ''; B.set_all(B.read_pm())   -- папка проектов (без jf_pm)
  elseif e.dir then B.go(B.full(e))
  elseif e.pm and B.grid and PMm() then if ctx.pm_open_project then ctx.pm_open_project(e.path, e.name) end   -- сетка: Enter — открыть (внутрь — Shift+Enter)
  elseif e.pm then B.pm_open(e)                         -- проект → внутрь, как папка
  elseif e.kit then if ctx.kit_load then ctx.kit_load(e.path, e.name) end   -- набор → lib трека курсора
  elseif (e.name or ''):lower():match('%.jfcurve$') then if ctx.curve_load then ctx.curve_load(B.full(e)) end   -- кривая → открытый automation item (6 окт)
  elseif e.empty then return
  elseif e.trk then if ctx.drop_track then ctx.drop_track(e, B.pmproj and B.pmproj.e) end
  elseif e.rgn then if ctx.drop_region_at_cursor then ctx.drop_region_at_cursor(B.pmproj.e.path, e) end
  elseif e.mark then return
  elseif e.other and not (e.name or ''):lower():match('%.xrni$') and not (e.name or ''):lower():match('%.rx2$') and not (e.name or ''):lower():match('%.rex$') then
    if ctx.open_file then ctx.open_file(B.full(e)) end                -- не звук (*.*): MIDI / видео / прочее
  else ctx.add_to_depot(B.full(e)) end
end

-- путь для прослушивания строки (nil — нечего слушать)
function B.preview_path(e)
  if not e or e.dir or e.db or e.trk or e.rgn or e.mark then return nil end
  if (e.name or ''):lower():match('%.xrni$') then return nil end       -- архив инструмента, не звук
  if (e.name or ''):lower():match('%.jfcurve$') then return nil end    -- кривая — не звук
  if e.other then return nil end                                      -- не звук (*.*): не слушаем
  if e.pm then return B.pm_preview(e) end
  return B.full(e)
end

function B.up()
  if B.filter ~= '' then B.filter = ''; B.filtering = false; B.set_all(B.all); return end
  if B.mode == 'db' then
    if B.db then B.db = nil; B.cur = 1; B.refresh_db() end
    return
  end
  if B.mode == 'pm' then
    if B.pmdir then B.pmdir = nil; B.cur = 1; B.refresh_pm()
    elseif B.pmproj then B.pmproj = nil; B.cur = 1; B.set_all(B.read_pm())
    elseif B.pm_folders and B.pmfolder then
      local parent = B.pmfolder:match('(.*)/[^/]+$')
      if parent and parent ~= '' then B.pmfolder = parent; B.pm = nil; B.cur = 1; B.set_all(B.read_pm()) end
    end
    return
  end
  -- выше корня :browse тоже можно (полный путь в строке пути, 2 окт)
  if B.path == '/' then return end
  local parent = B.path:match('(.*)/[^/]+$')
  if parent then B.go(parent ~= '' and parent or '/') end
end

-- строка описания для статус-бара
function B.describe(idx)
  local e = B.entries[idx]
  if not e then return '' end
  if e.db then return ('database %s (%s) - Enter: open'):format(e.name, e.file) end
  if e.dir then return '' end                                       -- 5 окт: без имени / пути папки
  if e.pm and e.card and PMm() then return PMm().describe(e) end
  if e.pm then
    local len = e.len and e.len > 0 and (' %d:%02d'):format(math.floor(e.len / 60), math.floor(e.len % 60)) or ''
    return ('project %s%s - Enter: inside, o: open in REAPER, T: tags, s: status, drag to track: subproject, Space: preview%s'):format(e.path, len, B.pm_preview(e) and '' or ' (no render)')
  end
  if e.pmdir then return 'inside project: ' .. e.name .. ' - Enter: open' end
  if e.kit then return ('kit %s (REAPER track template) - Enter: its samples into the lib of the cursor track'):format(e.name) end
  if e.trk then return ('track "%s" (%d files) - Enter / drag: insert this track into the project (state chunk)'):format(e.name, e.nfiles or 0) end
  if e.rgn then return ('region %s [%.2f - %.2f] - Enter: subproject trimmed to region @cursor, drag: to track/row'):format(e.name, e.pos, e.fin) end
  if e.mark then return 'marker ' .. e.name end
  if e.proj then return ('%s - used %d× (first on %s); Enter: to the lib of the cursor track, drag: to track, v: sample view'):format(e.path, e.n, e.track or '?') end
  local len = e.len and (' %d:%05.2f'):format(math.floor(e.len / 60), e.len % 60) or ''
  return ('%sEnter: to lib, Space: preview, v: view in sample tab, drag: to track'):format(len ~= '' and (len:sub(2) .. ' - ') or '')
end

function B.preview()
  local pth = B.preview_path(B.entries[B.cur])
  if pth then ctx.preview_file(pth) end
end

-- клавиши в фокусе браузера; true — съедена
function B.key(c)
  local ch = c < 256 and string.char(c) or ''
  if B.filtering then
    -- набор запроса: символы сужают список (fzf), стрелки ходят по результатам,
    -- Enter — закончить набор (результаты остаются), Esc — сбросить, BS — стереть
    if c == 27 then B.filtering = false; B.filter = ''; B.set_all(B.all)
    elseif c == 13 then B.filtering = false
    elseif c == 1685026670 then B.cur = math.min(#B.entries, B.cur + 1)
    elseif c == 30064 then B.cur = math.max(1, B.cur - 1)
    elseif c == 8 then B.filter = B.filter:sub(1, -2); B.cur = 1; B.set_all(B.all)
    elseif c >= 32 and c < 127 then B.filter = B.filter .. ch; B.cur = 1; B.set_all(B.all)
    else return false end
    return true
  end
  if B.keys and ctx.browser_note and ctx.browser_note(c) then return true end   -- keys: q 2 w 3 e … — файл с высотой
  -- pm-сетка (6 окт): свои клавиши (hjkl по сетке, Enter открыть, Space слушать, p pin …)
  if B.mode == 'pm' and B.grid and not B.pmproj and not B.pm_folders and PMm() then
    if c == 27 and ctx.pm_big_on and ctx.pm_big_on() and B.filter == '' then if ctx.pm_big then ctx.pm_big() end; return true end
    if PMm().key(c, B, ctx.mods and ctx.mods() or {}) then return true end
  end
  if ch:match('^%d$') then B.mark(ch == '0' and 10 or tonumber(ch))
  elseif MARK_SHIFT[ch] then B.mark(MARK_SHIFT[ch], 'set')
  elseif ch == 'H' then B.history(-1)
  elseif ch == 'L' then B.history(1)
  elseif ch == '*' then if ctx.browser_mkdir_prompt then ctx.browser_mkdir_prompt() end
  elseif ch == '/' or ch == 'f' then B.start_find()                           -- поиск прямо в списке (2 окт)
  elseif ch == 't' then B.set_mode(({ files = 'db', db = (B.panes and 'proj' or 'pm'), pm = 'proj', proj = 'kits', kits = 'files' })[B.mode] or 'files')   -- 9 окт: в панелях pm — своя панель
  elseif ch == 'p' then B.click('auto')
  elseif ch == 'o' then local e = B.entries[B.cur]; if e and e.pm and ctx.pm_open_project then ctx.pm_open_project(e.path, e.name) end
  elseif ch == 'T' then local e = B.entries[B.cur]; if e and e.pm and ctx.pm_tags then ctx.pm_tags(e) end        -- теги jf_pm
  elseif ch == 's' then local e = B.entries[B.cur]; if e and e.pm and ctx.pm_status then ctx.pm_status(e) end     -- статус jf_pm
  elseif ch == 'v' then local e = B.entries[B.cur]; local pth = B.preview_path(e); if pth and ctx.sample_view then ctx.sample_view(pth) end
  elseif ch == 'w' then B.click('size')
  elseif ch == 'q' then B.click('hide')
  elseif c == 27 and B.filter ~= '' then B.filter = ''; B.set_all(B.all)
  elseif ch == 'j' or c == 1685026670 then B.cur = math.min(#B.entries, B.cur + 1)
  elseif ch == 'k' or c == 30064 then B.cur = math.max(1, B.cur - 1)
  elseif ch == 'g' then B.cur = 1
  elseif ch == 'G' then B.cur = #B.entries
  elseif c == 13 and ctx.mods and ctx.mods().cmd then if ctx.browser_replace then ctx.browser_replace() end   -- Cmd+Enter: заменить сэмпл инструмента
  elseif c == 13 and ctx.mods and ctx.mods().alt then   -- Opt+Enter (7 окт): файл — слайсом выбранного инструмента
    local e = B.entries[B.cur]
    if e and not (e.dir or e.db or e.pm or e.pmdir or e.kit or e.trk or e.rgn or e.mark or e.other or e.empty) and ctx.lib_append_slice then ctx.lib_append_slice(B.full(e)) end
  elseif c == 13 or ch == 'l' then B.enter()
  elseif c == 8 or ch == '-' or ch == 'h' then B.up()
  elseif ch == ' ' then B.preview()
  elseif c == 9 or c == 27 then ctx.toggle_focus()
  else return false end
  return true
end

-- отрисовка в прямоугольнике (x, y, w, h); возвращает hover-индекс
-- hover: число — строка списка, строка — кнопка шапки ('files','db','size','hide')
-- кнопки закладок 1..5: занятая — циан, текущая папка — янтарь, пустая — тускло
function B.draw_marks(btn, bx, by, U)
  B.mark_rects = {}
  for i = 1, B.NMARKS do
    local p = B.marks[i]
    local x0 = bx
    bx = btn(bx, by, tostring(i % 10), 'bm' .. i, p ~= nil and p == B.path, p and U.CYAN or U.DIM)
    B.mark_rects[i] = { x0, by, bx - x0 }
  end
  return bx
end

function B.draw(U, L, x, y, w, h)
  U.set(U.PANEL); gfx.rect(x, y, w, h, 1)          -- левая граница — общая линия сайдбара (своя давала двойную, 3 окт)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local hover
  -- кнопки текстом: сверху — куда идти (files db pm proj), снизу — вид
  -- (wave auto <> x). Шапка и подвал по одной строке.
  local function btn(bx, by, label, what, on, tc)
    local bw = U.measure(label) + 2 * L.pad
    local hot = mx >= bx and mx < bx + bw and my >= by and my < by + L.rh
    U.set(hot and U.tint(U.AMBER, 0.3) or (on and U.tint(U.AMBER, 0.15) or U.BG)); gfx.rect(bx, by, bw, L.rh, 1)
    U.set(on and U.AMBER or U.LINE); gfx.rect(bx, by, bw, L.rh, 0)
    U.text(bx + L.pad, by + 1, label, on and U.AMBER or (hot and U.TEXT or (tc or U.GREY)))
    if hot then hover = what end
    if ctx.hint then ctx.hint('browserbtn', bx, by, bw, L.rh, what) end
    return bx + bw + L.pad
  end
  local wrap_marks = false
  do
    local bx = x + L.pad + 2
    -- 9 окт: панели — pm и fx отдельными панелями, у браузера только файлы
    for _, t in ipairs(B.panes and { 'files', 'db', 'proj', 'kits' } or (B.fx_draw and { 'files', 'db', 'pm', 'proj', 'kits', 'fx' } or { 'files', 'db', 'pm', 'proj', 'kits' })) do
      if bx + U.measure(t) + 2 * L.pad > x + w then break end
      bx = btn(bx, y, t, t, B.mode == t)
    end
    if B.mode == 'fx' and B.fx_draw then           -- вкладка fx: под строкой вкладок — список эффектов
      B.fx_hover = B.fx_draw(x, y + L.rh + 3, w, h - L.rh - 3)
      return hover
    end
    B.fx_hover = nil
    -- закладки 1..5 справа в том же ряду; не влезают — во второй ряд
    local mw = B.NMARKS * (U.measure('5') + 3 * L.pad)
    if bx + mw <= x + w then B.draw_marks(btn, x + w - mw - L.pad, y, U) else wrap_marks = true end
  end
  do
    local by = y + h - L.rh - 2
    local bx = x + L.pad + 2
    for _, b in ipairs({ { 'find', 'find', false }, { 'wave', 'wave', B.wave },
                         { 'track', 'track', B.via_track }, { 'sync', 'sync', B.sync }, { '*.*', 'allfiles', B.all_files }, { '.*', 'hidden', B.hidden } }) do
      if bx + U.measure(b[1]) + 2 * L.pad > x + w then break end
      bx = btn(bx, by, b[1], b[2], b[3])
    end
    h = h - L.rh - 4
  end
  -- над кнопками (2 окт): мини-волна проигрываемого / выбранного файла с
  -- позицией (клик — играть с этого места) и слайдер громкости прослушивания
  do
    local sy = y + h - L.rh - 2                     -- строка слайдера
    local wh = 2 * L.rh                             -- высота мини-волны
    local wy = sy - wh - 2
    local x0, ww = x + L.pad + 2, w - 2 * L.pad - 4
    local pos, len, ppath
    if ctx.preview_pos then pos, len, ppath = ctx.preview_pos() end      -- (a and f() отрезал бы хвост значений)
    local path = ppath or B.preview_path(B.entries[B.cur])
    U.set(U.BG); gfx.rect(x0, wy, ww, wh, 1)
    U.set(U.LINE); gfx.rect(x0, wy, ww, wh, 0)
    local pk = path and ww > 8 and ctx.file_peaks and ctx.file_peaks(path, ww)
    local cy, hh = wy + math.floor(wh / 2), math.floor(wh / 2) - 1
    U.set(ppath and U.CYAN or U.GREY)
    if pk and pk.n > 0 then
      for px = 0, ww - 1 do
        local i = math.floor(px / ww * pk.n) + 1
        local a, b = pk.min[i] or 0, pk.max[i] or 0
        if b - a < 0.03 then a, b = -0.015, 0.015 end
        gfx.line(x0 + px, cy - b * hh, x0 + px, cy - a * hh)
      end
    else gfx.line(x0, cy, x0 + ww - 1, cy) end
    if pos and len and len > 0 then
      local px = x0 + math.floor(math.max(0, math.min(1, pos / len)) * (ww - 1))
      U.set(U.AMBER); gfx.rect(px, wy, 1, wh, 1)
    end
    if mx >= x0 and mx < x0 + ww and my >= wy and my < wy + wh and path then
      hover = 'pvwave'; B.pv_frac = (mx - x0) / ww; B.pv_path = path
    end
    -- слайдер громкости: подпись | дорожка | dB
    local vol = ctx.preview_vol and ctx.preview_vol() or 1
    local db = vol > 1e-6 and 20 * math.log(vol, 10) or -60
    local frac = (math.max(-40, math.min(6, db)) + 40) / 46
    local lbl, vs = 'vol', db <= -40 and '-inf' or ('%+.1f'):format(db)
    -- play / keys — на строке плеера (5 окт): автопрослушивание и клавиатура
    -- с высотой выбранного файла
    local px0 = x0
    for _, b in ipairs({ { 'play', 'auto', B.auto }, { 'keys', 'keys', B.keys } }) do px0 = btn(px0, sy, b[1], b[2], b[3]) end
    local lx0 = px0 + L.pad
    local lw, vw = U.measure(lbl) + L.pad, U.measure('-40.0') + L.pad
    local sx0, sw = lx0 + lw, math.max(8, x0 + ww - lx0 - lw - vw)
    local hot = mx >= sx0 - 2 and mx < sx0 + sw + 2 and my >= sy and my < sy + L.rh
    U.text(lx0, sy, lbl, U.GREY)
    U.set(U.DIM); gfx.rect(sx0, sy + math.floor(L.rh / 2) - 1, sw, 2, 1)
    U.set(hot and U.AMBER or U.TEXT); gfx.rect(sx0, sy + 4, math.max(1, math.floor(frac * sw + 0.5)), L.rh - 8, 1)
    U.text(sx0 + sw + L.pad, sy, vs, U.GREY)
    if hot then hover = 'pvvol'; B.pv_vol_frac = math.max(0, math.min(1, (mx - sx0) / sw)) end
    if B.vol_drag then
      if gfx.mouse_cap & 1 == 1 then
        local f = math.max(0, math.min(1, (mx - sx0) / sw))
        ctx.preview_set_vol(f <= 0.001 and 0 or 10 ^ ((f * 46 - 40) / 20))
      else B.vol_drag = false end
    end
    h = h - wh - L.rh - 6
  end
  y = y + L.rh + 2; h = h - L.rh - 2
  -- управляющая строка (2 окт): < > * [1..5] и полный путь, клик по папке — туда
  do
    local bx = x + L.pad + 2
    if B.mode == 'files' then
      bx = btn(bx, y, '<', 'back', false)
      bx = btn(bx, y, '>', 'fwd', false)
      bx = btn(bx, y, '*', 'mkdir', false)
      if wrap_marks then bx = B.draw_marks(btn, bx, y, U) end
      if B.filter == '' and not B.filtering then
        local parts = B.path_parts(B.path)
        -- влезают последние сегменты; срезанное начало — «..»
        local avail = x + w - L.pad - bx
        local sep = U.measure('/')
        local first, used = #parts + 1, 0
        for i = #parts, 1, -1 do
          local wi = U.measure(parts[i].label) + (i > 2 and sep or 0)
          if used + wi > avail - U.measure('..') then break end
          used = used + wi; first = i
        end
        B.crumbs = {}
        local cx = bx
        if first > 1 then U.text(cx, y + 1, '..', U.DIM); cx = cx + U.measure('..') end
        for i = first, #parts do
          local pt = parts[i]
          if i > 2 and i > first then U.text(cx, y + 1, '/', U.DIM); cx = cx + sep end   -- после корня «/» свой слэш не нужен
          local wi = U.measure(pt.label)
          local hot = mx >= cx and mx < cx + wi and my >= y and my < y + L.rh
          local last = i == #parts
          U.text(cx, y + 1, pt.label, hot and U.AMBER or (last and U.TEXT or U.CYAN))
          B.crumbs[i] = pt
          if hot then hover = 'crumb' .. i end
          if ctx.hint then ctx.hint('browserbtn', cx, y, wi, L.rh, 'crumb' .. i) end
          cx = cx + wi
        end
        y = y + L.rh + 2; h = h - L.rh - 2
      end
    end
    if bx > x + L.pad + 2 and (B.filter ~= '' or B.filtering) then
      -- поиск: та же строка, после кнопок
      local scope = 'in folder'
      U.text(bx, y + 1, ctx.fit('/' .. B.filter .. (B.filtering and '_' or '') .. ('  %s: %d'):format(scope, #B.entries), x + w - L.pad - bx), U.AMBER)
      y = y + L.rh + 2; h = h - L.rh - 2
    end
  end
  -- путь / база / фильтр (не files: прежняя строка «где я»)
  local where
  if B.mode == 'files' then local rel = B.path:sub(#B.root + 2); where = rel ~= '' and rel or '/'
  elseif B.mode == 'proj' then where = ('project: %d sources'):format(#B.all)
  elseif B.mode == 'pm' then where = B.pmproj and ('@' .. (B.pmproj.e.name or '') .. (B.pmdir and ('/' .. B.pmdir) or '')) or (B.pm_folders and ('projects: ' .. (B.pmfolder or '')) or ('jf_pm: %d projects'):format(#B.all))
  else where = B.db and ('db ' .. B.db.name) or 'databases' end
  if B.filter ~= '' or B.filtering then
    local scope = B.mode == 'files' and 'in folder' or (B.mode == 'db' and B.db and 'in db' or 'in list')
    where = where .. ' /' .. B.filter .. (B.filtering and '_' or '') .. ('  %s: %d'):format(scope, #B.entries)
  end
  if B.mode ~= 'files' then
    local tx0 = x + L.pad + 2
    -- pm (6 окт): кнопки вида / сортировки / DAW / big перед текстом
    if B.mode == 'pm' and not B.pmproj and not B.pm_folders and B.pm_mod() then
      local bx = tx0
      bx = btn(bx, y, B.grid and 'list' or 'grid', B.grid and 'pmlist' or 'pmgrid', false)
      bx = btn(bx, y, B.pm_sort or 'date', 'pmsort', false)
      bx = btn(bx, y, B.pm_daw or 'all', 'pmdaw', false)
      if bx + U.measure('big') + 2 * L.pad <= x + w then bx = btn(bx, y, 'big', 'pmbig', ctx.pm_big_on and ctx.pm_big_on()) end
      if bx + U.measure('sq') + 2 * L.pad <= x + w then bx = btn(bx, y, ({ wide = 'wd', compact = 'cp', square = 'sq' })[B.pm_mod().shape] or 'wd', 'pmshape', false) end
      tx0 = bx
      if B.pm_loading then where = ('jf_pm: loading %d %%'):format(math.floor(((B.pm_mod().loading or {}).frac or 0) * 100)) end
    end
    if tx0 < x + w - 4 * L.cw then U.text(tx0, y + 1, ctx.fit(where, x + w - L.pad - tx0), (B.filtering and U.AMBER or U.GREY)) end
    y = y + L.rh; h = h - L.rh
  end
  -- pm-сетка карточек (6 окт): вместо строк списка
  if B.mode == 'pm' and B.grid and not B.pmproj and not B.pm_folders and B.pm_mod() then
    local PM = B.pm_mod()
    local hv, cols = PM.draw_grid(L, x, y, w - 2, h, B.entries, B.cur, B.focus, B.pm_scroll)
    B.grid_cols = cols
    if hv then hover = hv end
    return hover
  end
  local nvis = math.floor(h / L.rh)
  -- за курсором — только когда он сдвинулся (4 окт): полосой / колесом листается
  if B.last_cur ~= B.cur then
    B.last_cur = B.cur
    if B.cur - 1 < B.scroll then B.scroll = B.cur - 1 end
    if B.cur - 1 >= B.scroll + nvis then B.scroll = B.cur - nvis end
  end
  B.scroll = math.max(0, math.min(B.scroll, math.max(0, #B.entries - nvis)))
  local vb = { x + w - 2, y, nvis }           -- тоненький скролл-бар — после строк (волны его не закрывают)
  for i = 1, nvis do
    local idx = B.scroll + i
    local e = B.entries[idx]
    if not e then break end
    local ry = y + (i - 1) * L.rh
    if idx == B.cur then
      U.set(B.focus and U.TEXT or U.LINE); gfx.rect(x + 1, ry, w - 2, L.rh, 1)
    end
    local col = (idx == B.cur and B.focus) and U.BG or ((e.dir or e.db) and U.CYAN or ((e.pm or e.trk or e.rgn) and U.AMBER or U.TEXT))
    local glyph = e.db and '#' or (e.pm and '@' or (e.kit and '*' or (e.trk and '=' or (e.rgn and '[' or (e.mark and '|' or (e.dir and '/' or ' '))))))
    local is_file = not (e.dir or e.db or e.pm or e.trk or e.rgn or e.mark)
    local tw = w - 2 * L.pad
    if B.wave and is_file then tw = math.floor(tw * 0.55) end
    U.text(x + L.pad, ry + 1, ctx.fit(glyph .. e.name, tw), col)
    -- мета проекта pm справа (темп, тональность, теги, статус) — если влезает
    if e.meta then
      local nw = U.measure(glyph .. e.name) + L.pad
      if nw + U.measure('000bpm') < tw then
        U.text(x + L.pad + nw, ry + 1, ctx.fit(e.meta, tw - nw), (idx == B.cur and B.focus) and U.BG or U.GREY)
      end
    end
    if B.wave and is_file and ctx.file_peaks then
      -- мини-волна файла справа от имени (нативные пики REAPER, кеш по пути)
      local wx, ww = x + L.pad + tw + L.pad, w - 2 * L.pad - tw - L.pad
      local pk = ww > 8 and ctx.file_peaks(B.full(e), ww)
      local cy, hh = ry + L.rh / 2, L.rh / 2 - 1
      U.set((idx == B.cur and B.focus) and U.BG or U.readable(U.mix(U.TEXT, U.CYAN, 0.4), U.BG, 4.0))
      if pk and pk.n > 0 then
        for px = 0, ww - 1 do
          local i = math.floor(px / ww * pk.n) + 1
          local a, b = pk.min[i] or 0, pk.max[i] or 0
          if b - a < 0.03 then a, b = -0.015, 0.015 end
          gfx.line(wx + px, cy - b * hh, wx + px, cy - a * hh)
        end
      else gfx.line(wx, cy, wx + ww, cy) end
    end
    if mx >= x and mx < x + w and my >= ry and my < ry + L.rh then hover = idx end
    if ctx.hint then ctx.hint('browser', x + 2, ry, w - 4, L.rh, idx) end
  end
  if ctx.vbar then ctx.vbar('browser', vb[1], vb[2], 2, vb[3] * L.rh, B.scroll, vb[3], #B.entries) end
  -- закладка под мышью (5 окт): точный путь всплывашкой под кнопкой, по ширине
  -- сайдбара (длинный — с начала обрезан …); статус-бар путём не засоряем
  local bi = type(hover) == 'string' and tonumber(hover:match('^bm(%d+)$'))
  local r = bi and B.mark_rects and B.mark_rects[bi]
  if r then
    local p = B.marks[bi]
    local txt = p or 'empty - click: remember this folder'
    local maxw = w - 2 * L.pad - 2
    if U.measure(txt) > maxw then
      while #txt > 4 and U.measure('…' .. txt) > maxw do txt = txt:sub(2) end
      txt = '…' .. txt
    end
    local tw2 = U.measure(txt) + 2 * L.pad
    local px = math.max(x + 1, math.min(x + w - tw2 - 1, r[1]))
    local py = r[2] + L.rh + 1
    U.set(U.PANEL); gfx.rect(px, py, tw2, L.rh + 2, 1)
    U.set(U.AMBER); gfx.rect(px, py, tw2, L.rh + 2, 0)
    U.text(px + L.pad, py + 1, txt, p and U.TEXT or U.GREY)
  end
  return hover
end

-- «призрак» перетаскиваемой строки у курсора мыши (рисуется поверх всего)
function B.draw_drag(U, L)
  local d = B.drag
  if not d or not d.active then return end
  local label = (d.e.pm and '@' or ' ') .. d.e.name
  local bw = U.measure(label) + 2 * L.pad
  local x, y = gfx.mouse_x + 12, gfx.mouse_y - L.rh // 2
  U.set(U.AMBER); gfx.rect(x, y, bw, L.rh, 1)
  U.set(U.BG); gfx.rect(x, y, bw, L.rh, 0)
  U.text(x + L.pad, y + 1, label, U.BG, U.AMBER)
end

return B
