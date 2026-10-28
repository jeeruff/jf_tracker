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

local TX = dofile((debug.getinfo(1, 'S').source:match('^@(.*/)') or './') .. 'jf_tracker_utf8.lua')   -- 20 окт: набор Юникодом (кириллица)
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
B.drum = false      -- 19 окт: drum — выбранный файл сразу в активный пэд drumrs5k (слышно в игре), выкл — выбор фиксируется
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
-- 11 окт: scroll (по умолчанию вкл) — колесо листает список, курсор стоит (двигают щелчок, j k, f)
B.wscroll = not (R.GetExtState and R.GetExtState('jf_tracker', 'brwscroll') == '0')
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
                rx2 = true, rex = true, xrni = true, sfz = true, jfcurve = true }   -- 11 окт: sfz — Enter: сэмплы в lib   -- jfcurve — кривые automation (6 окт)   -- REX / Renoise-Redux: Enter = импорт с нарезкой (2 окт)
local function shown(name) return B.hidden or name:sub(1, 1) ~= '.' end
local function wanted(name, map)
  local ext = name:match('%.([%w]+)$')
  if map and B.SM then local t = B.SM.ext_type(name); return t ~= nil and B.mapV.types[t] == true end   -- 27 окт (8): карта — по типам
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
  if how == 'set' or (how == nil and not B.marks[i]) then   -- how == 'go' — только переход (пустая не ставится)
    B.marks[i] = B.path
    if R.SetExtState then R.SetExtState('jf_tracker', 'bmark' .. i, B.path, true) end
    if ctx.msg then ctx.msg(('bookmark %d = %s'):format(i, B.path)) end
  elseif how == 'clear' then
    B.marks[i] = nil
    if R.DeleteExtState then R.DeleteExtState('jf_tracker', 'bmark' .. i, true) end
    if ctx.msg then ctx.msg(('bookmark %d cleared'):format(i)) end
  else
    if not B.marks[i] then if ctx.msg then ctx.msg(('bookmark %d is empty - Shift+%d sets it'):format(i, i % 10)) end; return end
    B.go(B.marks[i])
  end
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

-- ── 27 окт: КОЛОНКИ как в lf (Miller columns): широкий браузер в режиме files — родитель | папка | превью ──
-- список папки для соседних колонок (те же фильтры, что B.refresh), кеш 2 с; до 3000 строк
local LDC = {}
local function join(dir, name) return (dir == '/' and '' or dir) .. '/' .. name end
local function list_dir(path, nocache)   -- nocache (27 окт): обход дерева картой — без кеша (сотни папок не копятся)
  local now = R.time_precise and R.time_precise() or os.clock()
  local c = LDC[path]
  if c and now - c.t < 2 then return c.list end
  local out, files, i = {}, {}, 0
  while #out < 3000 do
    local d = R.EnumerateSubdirectories(path, i)
    if not d then break end
    if shown(d) then out[#out + 1] = { name = d, dir = true } end
    i = i + 1
  end
  table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
  i = 0
  while #files < 3000 do
    local f = R.EnumerateFiles(path, i)
    if not f then break end
    if shown(f) and wanted(f, nocache) then files[#files + 1] = { name = f } end
    i = i + 1
  end
  table.sort(files, function(a, b) return a.name:lower() < b.name:lower() end)
  for _, f in ipairs(files) do out[#out + 1] = f end
  if not nocache then LDC[path] = { t = now, list = out } end
  return out
end
B.list_dir = list_dir
-- колонка-список: hi — имя подсвеченной (текущая папка в родителе); → hover 'tagN'
local function draw_col(U, L, list, x, y, w, h, hi_name, tag, mx, my)
  local nvis = math.floor(h / L.rh)
  local hi
  if hi_name then for i, e in ipairs(list) do if e.name == hi_name then hi = i; break end end end
  local first = hi and math.max(0, math.min(hi - math.floor(nvis / 2), #list - nvis)) or 0
  local hv
  for i = 1, nvis do
    local idx = first + i
    local e = list[idx]
    if not e then break end
    local ry = y + (i - 1) * L.rh
    local hot = mx >= x and mx < x + w and my >= ry and my < ry + L.rh
    if idx == hi then U.set(U.tint(U.AMBER, 0.22)); gfx.rect(x, ry, w, L.rh, 1)
    elseif hot then U.set(U.tint(U.AMBER, 0.12)); gfx.rect(x, ry, w, L.rh, 1) end
    U.text(x + L.pad, ry + 1, ctx.fit((e.dir and '/' or ' ') .. e.name, w - 2 * L.pad), idx == hi and U.AMBER or (hot and U.TEXT or (e.dir and U.CYAN or U.GREY)))
    if hot then hv = tag .. idx end
  end
  if #list == 0 then U.text(x + L.pad, y + 1, 'empty', U.DIM) end
  return hv
end

-- ── 27 окт: КАРТА папки (jf_tracker_smap): граф пересобирается при смене папки; вид (зум, сдвиг) — общий ──
B.mapV = { zoom = 1, px = 0, py = 0, grav = 0.5, dim = 0.5, style = R.GetExtState and R.GetExtState('jf_tracker', 'mapstyle') ~= '' and R.GetExtState('jf_tracker', 'mapstyle') or 'graph' }   -- 27 окт: вид помнится
-- 27 окт: подвкладки карты — что раскладывать: files (папка браузера), db (база / все базы), proj (источники проекта), pm (проекты jf_pm)
B.map_src = 'files'
B.MAP_SRCS = { 'files', 'db', 'proj', 'pm' }
-- ключ (дёшево, каждый кадр) и список файлов (только при смене ключа) для источника
local function map_source()
  local src = B.map_src
  if src == 'db' then
    local k = 'db:' .. (B.db and B.db.file or '*')
    return k, function()
      local dbs = B.db and { B.db } or (B.dbs or B.read_dbs())
      local all = {}
      for _, d in ipairs(dbs) do for _, e in ipairs(B.read_db(d.file)) do all[#all + 1] = { path = e.path, name = e.name, sub = d.name } end end
      return all   -- 27 окт (2): все файлы баз, без выборки
    end
  elseif src == 'proj' then
    return 'proj:' .. R.CountMediaItems(0), function()
      local out = {}
      for _, e in ipairs(B.read_proj()) do out[#out + 1] = { path = e.path, name = e.name, sub = e.track } end
      return out
    end
  elseif src == 'pm' then
    local list = B.read_pm()
    return 'pm:' .. #list, function()
      local out = {}
      for _, e in ipairs(list) do if e.path then out[#out + 1] = { path = e.path, name = e.name, sub = (e.path:match('([^/]+)/[^/]+$') or '') } end end
      return out
    end
  end
  return B.mp() .. '|' .. B.types_key(), nil
end
function B.types_key() local t = {}; for _, k in ipairs(B.SM.TYPES) do if B.mapV.types[k] then t[#t + 1] = k end end; return table.concat(t, ',') end
-- 27 окт (2): мини-lf слева от карты (источник files): .. и подпапки текущей папки; клик / l / Enter — войти, h — выше
-- 27 окт (2): индекс карты на диске: Data/jf_tracker_mapcache/<папка>.txt
function B.map_cache_file(root)
  local dir = R.GetResourcePath() .. '/Data/jf_tracker_mapcache'
  R.RecursiveCreateDirectory(dir, 0)
  return dir .. '/' .. root:gsub('[^%w%-_.]', '_') .. '.txt'
end
-- 27 окт (4): карта показывает папку, открытую в браузере (пользователь); мини-lf карты ходит по ней же
B.map_dcur = 1
function B.mp() return B.path end
function B.map_dirs()
  local out = {}
  local mp = B.mp()
  if mp ~= '/' then out[1] = { name = '..', dir = true, up = true } end
  for _, e in ipairs(list_dir(mp)) do if e.dir then out[#out + 1] = e end end
  return out
end
function B.map_cd(path)
  if not path or path == '' or path == B.mp() then return end
  local from = B.path
  if B.mode == 'files' then B.go(path)          -- история, zoxide, список браузера
  else   -- браузер на другой вкладке (db, pm …) — её список не трогаем, только папка
    B.zadd(B.zload(), path, os.time()); B.zsave()
    B.back[#B.back + 1] = B.path; B.fwd = {}
    B.path = path
  end
  B.map_dcur = 1
  for i, e in ipairs(B.map_dirs()) do if (path .. '/' .. e.name) == from then B.map_dcur = i end end   -- выше — курсор на папке, откуда пришли
  B.mapG = nil
end
function B.map_enter(i)
  local e = B.map_dirs()[i or B.map_dcur]
  if not e then return end
  local mp = B.mp()
  if e.up then B.map_cd(mp:match('(.*)/[^/]+$') or '/') else B.map_cd((mp == '/' and '' or mp) .. '/' .. e.name) end
  if B.map_src ~= 'files' then B.map_src = 'files' end
end
-- 27 окт (2): случайный сэмпл — найти то, до чего списком не дойдёшь: в секторе / группе под мышью, иначе из всех; сразу слушать
-- 27 окт (9): этап 2 — анализ: очередь (что слушали + группа под мышью), по 2 файла за кадр, пики строятся в фоне
local function an_file() return R.GetResourcePath() .. '/Data/jf_tracker_mapan.txt' end
B.an_q, B.an_qs, B.an_t = {}, {}, 0
function B.an_push(path) if path and not B.SM.AN[path] and not B.an_qs[path] then B.an_qs[path] = true; B.an_q[#B.an_q + 1] = path end end
function B.an_tick(G)
  if not B.an_loaded then B.an_loaded = true; pcall(B.SM.an_load, an_file()) end
  local hb = B.map_hv and (B.map_hv.hub or (B.map_hv.node and B.map_hv.node.h))
  if hb and hb ~= B.an_hub then
    B.an_hub = hb
    for i = 1, math.min(#hb.list, 400) do B.an_push(hb.list[i].path) end
  end
  local done = 0
  local i = 1
  while i <= #B.an_q and done < 2 and i <= 6 do
    local pth = B.an_q[i]
    local pk = ctx.file_peaks and ctx.file_peaks(pth, 32, 0, 1, true)
    if pk then
      local a = B.SM.an_from_peaks(pk)
      if a and ctx.file_len_of then a.d = ctx.file_len_of(pth) end   -- 27 окт: длина — для песчинок
      if a then B.SM.AN[pth] = a; B.SM.an_dirty = true; B.SM.an_n = (B.SM.an_n or 0) + 1 end
      table.remove(B.an_q, i); B.an_qs[pth] = nil; done = done + 1
      local n = G and G.bypath and G.bypath[pth]
      if n then n.h.an_new = (n.h.an_new or 0) + 1 end
    else i = i + 1 end
  end
  local now = R.time_precise()
  if now - B.an_t > 1.5 then   -- раз в 1.5 с: перестроить группы с новыми данными, сохранить
    B.an_t = now
    for _, h in ipairs((G and G.hubs) or {}) do if (h.an_new or 0) > 0 then h.an_new = 0; B.SM.an_resort(G, h) end end
    B.SM.an_save(an_file())
  end
end
-- 27 окт (8): типы файлов карты (по умолчанию — сэмплы)
if B.mapV.style == 'tree' then B.mapV.style = 'graph' end   -- 27 окт: вид tree скрыт
for k in (R.GetExtState and R.GetExtState('jf_tracker', 'mapflt') or ''):gmatch('[^,]+') do if B.SM then B.SM.FON[k] = true end end   -- 28 окт: фильтры помнятся
B.mapV.types = {}
do
  local ts = R.GetExtState and R.GetExtState('jf_tracker', 'maptypes') or ''
  if ts == '' then ts = 'samples' end
  for k in ts:gmatch('[^,]+') do B.mapV.types[k] = true end
end
-- 27 окт (5): опции модуля map (вкладка modules) — из ExtState при загрузке
do
  local function g(k) local v = tonumber(R.GetExtState and R.GetExtState('jf_tracker', 'mod_map_' .. k) or ''); return v end
  if B.SM then
    B.SM.DARK = g('dark') or B.SM.DARK; B.SM.RECOVER = g('recover') or B.SM.RECOVER
    B.map_ship_on = g('ship') == 1   -- корабль — опцией (по умолчанию нет)
    B.SM.SIZE_MAX = g('sizes') or B.SM.SIZE_MAX; B.SM.EDGES_MAX = g('edges') or B.SM.EDGES_MAX; B.SM.NEB_MAX = g('stars') or B.SM.NEB_MAX
  end
end
-- 27 окт (6): файл под мышью на карте (точка, строка истории, отсек корабля) — для меню файла (ПКМ)
function B.map_file_of(id)
  if id == 'mapnode' then local n = B.map_hv and B.map_hv.node; return n and n.path end
  if id == 'maphub' then   -- 27 окт (7): карточка / группа — её последний сыгранный файл (нет — первый)
    local hb = B.map_hv and B.map_hv.hub
    if not hb then return nil end
    local G = B.mapG
    for _, e in ipairs(B.map_hist) do local n = G and G.bypath and G.bypath[e.path]; if n and n.h == hb then return e.path end end
    return hb.list and hb.list[1] and hb.list[1].path
  end
  local i = id:match('^maphist(%d+)$')
  if i then local e = B.map_hist[tonumber(i)]; return e and e.path end
  i = id:match('^rec(%d+)$')   -- 27 окт (7): отмеченные в широком плеере браузера — то же меню файла
  if i then return (B.mk_list or {})[tonumber(i)] end
  i = id:match('^mapmk(%d+)$')
  if i then local o = (B.sel_order or {})[tonumber(i)]; return o and o.full end
  i = id:match('^mapship(%d+)$')
  if i then local o = (B.sel_order or {})[tonumber(i)]; return o and o.full end
  return nil
end
-- 27 окт (5): история карты — что проиграно из неё (новое первым); шаг — номер прослушивания (точки гаснут по нему)
B.map_hist, B.map_step = {}, 0
-- 27 окт (8): history и marked — на диске (Data/jf_tracker_maphist.txt, jf_tracker_marked.txt), переживают рестарт
local function hist_file() return R.GetResourcePath() .. '/Data/jf_tracker_maphist.txt' end
local function marked_file() return R.GetResourcePath() .. '/Data/jf_tracker_marked.txt' end
function B.map_hist_save()
  local f = io.open(hist_file(), 'w'); if not f then return end
  f:write(tostring(B.map_step), '\n')
  for _, e in ipairs(B.map_hist) do f:write(e.step, '\t', e.path, '\t', e.name or '', '\n') end
  f:close()
end
function B.marked_save()
  local f = io.open(marked_file(), 'w'); if not f then return end
  for _, o in ipairs(B.sel_order or {}) do if o.full then f:write(o.full, '\t', (o.e and o.e.name) or '', '\n') end end
  f:close()
  B.marked_sig = #(B.sel_order or {}) .. ':' .. tostring((B.sel_order or {})[#(B.sel_order or {})] and B.sel_order[#B.sel_order].full)
end
-- отметки поменялись (m в браузере, двойной клик, lib / save, clear) — на диск; зовут браузер и карта каждый кадр (дёшево)
function B.marked_tick()
  local list = B.sel_order or {}
  local sig = #list .. ':' .. tostring(list[#list] and list[#list].full)
  if sig ~= B.marked_sig then B.marked_save() end
end
function B.hist_load()
  local f = io.open(hist_file(), 'r')
  if f then
    B.map_step = tonumber(f:read('*l') or '') or 0
    for line in f:lines() do
      local st, pth, nm = line:match('^(%d+)\t([^\t]*)\t(.*)$')
      if pth and pth ~= '' then B.map_hist[#B.map_hist + 1] = { step = tonumber(st), path = pth, name = nm ~= '' and nm or pth:match('[^/]+$') } end
    end
    f:close()
  end
  B.mapV.hist, B.mapV.step = B.map_hist, B.map_step
  f = io.open(marked_file(), 'r')
  if f then
    for line in f:lines() do
      local pth, nm = line:match('^([^\t]+)\t?(.*)$')
      if pth and not B.sel[pth] then
        B.sel[pth] = true
        B.sel_order[#B.sel_order + 1] = { key = pth, e = { name = nm ~= '' and nm or pth:match('[^/]+$'), path = pth }, full = pth }
      end
    end
    f:close()
  end
  B.marked_sig = #B.sel_order .. ':' .. tostring(B.sel_order[#B.sel_order] and B.sel_order[#B.sel_order].full)
end
function B.map_play(path, name, keep)
  if not path then return end
  if B.an_push then B.an_push(path) end   -- 27 окт (9): сыгранное — в анализ
  B.map_step = B.map_step + 1
  local kept = false
  if keep then   -- 27 окт (8): ещё раз из истории — строка на месте (не прыгает наверх), только свежесть
    for _, e in ipairs(B.map_hist) do if e.path == path then e.step = B.map_step; kept = true; break end end
  end
  if not kept then
    for i = #B.map_hist, 1, -1 do if B.map_hist[i].path == path then table.remove(B.map_hist, i) end end
    table.insert(B.map_hist, 1, { path = path, name = name or path:match('[^/]+$') or path, step = B.map_step })
  end
  while #B.map_hist > 200 do B.map_hist[#B.map_hist] = nil end
  B.mapV.hist, B.mapV.step = B.map_hist, B.map_step
  B.map_hist_save()
  B.pl = nil
  ctx.preview_file(path)
end
B.map_last_hub = nil
function B.map_random()
  local G = B.mapG
  if not G or G.building or #G.nodes == 0 then return end
  local hb = B.map_hv and B.map_hv.hub or (B.map_hv and B.map_hv.node and B.map_hv.node.h)
  if not hb and B.mapV.sys and B.mapV.style == 'nebula' then for _, h0 in ipairs(G.hubs) do if h0.name == B.mapV.sys then hb = h0 end end end   -- в системе — из неё
  local list = hb and hb.list or G.nodes
  local n = list[math.random(#list)]
  if not n then return end
  B.map_play(n.path, n.name)
  if ctx.msg then ctx.msg(('random%s: %s  (r - another one; Shift+click the group - mark it)'):format(hb and (' in ' .. hb.name) or '', n.name)) end
end
-- клавиши панели map: j k — папки мини-lf, l / Enter — войти, h — выше, t — следующий источник, v — graph / nebula
-- 27 окт (8): зоны панели map (Cmd+h / l, Cmd+j / k): lf | map | hist / marked; → true, если переход внутри
B.MAP_ZONES = { 'lf', 'map', 'side' }
function B.map_zone_step(dir)
  local z = B.mapV.zone or 'map'
  if dir == 'l' or dir == 'r' then
    local order = { lf = 1, map = 2, hist = 3, marked = 3 }
    local i = order[z] + (dir == 'r' and 1 or -1)
    if i < 1 or i > 3 then return false end
    B.mapV.zone = ({ 'lf', 'map', 'hist' })[i]
  elseif dir == 'd' or dir == 'u' then
    if z == 'hist' and dir == 'd' then B.mapV.zone = 'marked'
    elseif z == 'marked' and dir == 'u' then B.mapV.zone = 'hist'
    else return false end
  end
  B.mapV.hcur = B.mapV.hcur or 1; B.mk_cur = B.mk_cur or 1; B.mk_active = B.mapV.zone == 'marked' or nil
  if ctx.msg then ctx.msg('map: ' .. B.mapV.zone .. ' (Cmd+h j k l - the next part; j k Enter there)') end
  return true
end
function B.map_key(c)
  local ch = c < 256 and string.char(c) or ''
  local z = B.mapV.zone
  if z == 'hist' then
    local n = #B.map_hist
    if ch == 'j' or c == 1685026670 then B.mapV.hcur = math.min(n, (B.mapV.hcur or 1) + 1); local e = B.map_hist[B.mapV.hcur]; if e then B.map_play(e.path, e.name, true) end; return true end
    if ch == 'k' or c == 30064 then B.mapV.hcur = math.max(1, (B.mapV.hcur or 1) - 1); local e = B.map_hist[B.mapV.hcur]; if e then B.map_play(e.path, e.name, true) end; return true end
    if c == 13 then local e = B.map_hist[B.mapV.hcur or 1]; if e then B.map_mark(e.path, e.name) end; return true end
    if ch == 'p' and ctx.map_print_menu then ctx.map_print_menu(); return true end
  elseif z == 'marked' then
    local n = #(B.sel_order or {})
    if ch == 'j' or c == 1685026670 then B.mk_cur = math.min(n, (B.mk_cur or 1) + 1); local o = B.sel_order[B.mk_cur]; if o then B.map_play(o.full, o.e and o.e.name, true) end; return true end
    if ch == 'k' or c == 30064 then B.mk_cur = math.max(1, (B.mk_cur or 1) - 1); local o = B.sel_order[B.mk_cur]; if o then B.map_play(o.full, o.e and o.e.name, true) end; return true end
  end
  -- 27 окт (8): marked (строка под мышью / последняя щёлкнутая): x / dd — снять, Enter — в lib, Opt+Enter — в папку lib
  local mi = B.mk_target()
  local mo = mi and (B.sel_order or {})[mi]
  if mo then
    if ch == 'x' or (ch == 'd' and B.mk_d) then B.mk_d = nil; B.map_mark(mo.full, mo.e and mo.e.name, true); return true end
    if ch == 'd' then B.mk_d = true; if ctx.msg then ctx.msg('d - d again: unmark ' .. ((mo.e and mo.e.name) or '')) end; return true end
    B.mk_d = nil
    if c == 13 and ctx.mods and ctx.mods().alt and ctx.files_to_folder then local p = mo.full; B.map_mark(p, nil, true); ctx.files_to_folder({ p }); return true end
    if c == 13 then B.mk_to_lib(mi); return true end
  end
  if z == 'map' or z == 'hist' or z == 'marked' then if ch == 'j' or ch == 'k' or ch == 'h' or ch == 'l' then return false end end
  if ch == 'j' or ch == 'k' or ch == 'h' or ch == 'l' or c == 1685026670 or c == 30064 then B.mk_active = nil end   -- мини-lf снова главный
  local n = #B.map_dirs()
  if ch == 'j' or c == 1685026670 then B.map_dcur = math.min(n, B.map_dcur + 1)
  elseif ch == 'k' or c == 30064 then B.map_dcur = math.max(1, B.map_dcur - 1)
  elseif ch == 'l' or c == 13 or c == 1919379572 then B.map_enter()
  elseif ch == 'h' or c == 1818584692 then local mp = B.mp(); if mp ~= '/' then B.map_cd(mp:match('(.*)/[^/]+$') or '/') end
  elseif ch == 'g' then B.map_dcur = 1
  elseif ch == 'G' then B.map_dcur = n
  elseif ch == 't' then
    local i = 1
    for k, v in ipairs(B.MAP_SRCS) do if v == B.map_src then i = k end end
    B.map_src = B.MAP_SRCS[i % #B.MAP_SRCS + 1]; B.mapG = nil
    if ctx.msg then ctx.msg('map: ' .. B.map_src) end
  elseif ch == 'v' then B.mapV.style = ({ graph = 'cards', cards = 'nebula', nebula = 'sand', sand = 'graph' })[B.mapV.style or 'graph'] or 'graph'; B.mapV.sys = nil; R.SetExtState('jf_tracker', 'mapstyle', B.mapV.style, true); if ctx.msg then ctx.msg('map: ' .. B.mapV.style .. ' view') end
  elseif ch == 'r' then B.map_random()
  elseif c == 27 and B.mapV.sys then B.mapV.sys = nil; B.mapV.zoom, B.mapV.px, B.mapV.py = 1, 0, 0
  elseif (ch == '+' or ch == '=') and B.mapV.style == 'cards' then B.SM.cardz = math.min(6, (B.SM.cardz or 1.5) * 1.25)   -- 27 окт (8): размер карточек
  elseif ch == '-' and B.mapV.style == 'cards' then B.SM.cardz = math.max(0.6, (B.SM.cardz or 1.5) / 1.25)
  elseif ch == '+' or ch == '=' then B.mapV.zoom = math.min(8, (B.mapV.zoom or 1) * 1.25)
  elseif ch == '-' then B.mapV.zoom = math.max(0.3, (B.mapV.zoom or 1) / 1.25)
  elseif ch == '0' then B.mapV.zoom, B.mapV.px, B.mapV.py = 1, 0, 0
  else return false end
  return true
end
-- 27 окт (3): панель map: строка источников + где, мини-lf (files) и карта
function B.map_pane(U, L, x, y, w, h)
  U.set(U.PANEL); gfx.rect(x, y, w, h, 1)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local hover
  local bx, by = x + L.pad + 2, y + 2
  for _, sname in ipairs(B.MAP_SRCS) do
    local on = B.map_src == sname
    local bw = U.measure(sname) + 2 * L.pad
    local hot = mx >= bx and mx < bx + bw and my >= by and my < by + L.rh
    U.set(hot and U.tint(U.AMBER, 0.3) or (on and U.tint(U.AMBER, 0.15) or U.BG)); gfx.rect(bx, by, bw, L.rh, 1)
    U.set(on and U.AMBER or U.LINE); gfx.rect(bx, by, bw, L.rh, 0)
    U.text(bx + L.pad, by + 1, sname, on and U.AMBER or (hot and U.TEXT or U.GREY))
    if hot then hover = 'mapsrc_' .. sname end
    bx = bx + bw + L.pad
  end
  local sw = B.map_src
  local where = sw == 'files' and B.mp() or (sw == 'db' and (B.db and ('db ' .. B.db.name) or 'all databases') or (sw == 'proj' and 'project sources' or 'jf_pm projects'))
  if B.nmarked() > 0 then where = where .. ('  (%d marked)'):format(B.nmarked()) end
  if bx < x + w - 4 * L.cw then U.text(bx, by + 1, ctx.fit(where, x + w - L.pad - bx), U.GREY) end
  local top = y + L.rh + 4
  -- 27 окт (7): снизу — плеер браузера с его кнопками (одна функция B.player_block)
  local function btn(bx0, by0, label, what, on)
    local bw = U.measure(label) + 2 * L.pad
    local hot = mx >= bx0 and mx < bx0 + bw and my >= by0 and my < by0 + L.rh
    U.set(hot and U.tint(U.AMBER, 0.3) or (on and U.tint(U.AMBER, 0.15) or U.BG)); gfx.rect(bx0, by0, bw, L.rh, 1)
    U.set(on and U.AMBER or U.LINE); gfx.rect(bx0, by0, bw, L.rh, 0)
    U.text(bx0 + L.pad, by0 + 1, label, on and U.AMBER or (hot and U.TEXT or U.GREY))
    if hot then hover = what end
    return bx0 + bw + L.pad
  end
  local mh = y + h - top - 1
  local ph, phv = B.player_block(U, L, x, top, w, mh, btn, { buttons = true, marked = false })
  local hv = B.map_draw_fn(U, L, x + 1, top, w - 2, ph)
  B.map_hv_id = hover or phv or hv   -- 27 окт (8): под мышью — для клавиш marked (x / dd / Enter)
  -- 27 окт (8): протяжка с зажатой кнопкой по точкам — каждая новая звучит и ложится в историю (путь)
  if B.map_drag then
    if gfx.mouse_cap & 1 == 0 then B.map_drag = nil
    else
      local n = B.map_hv and B.map_hv.node
      if n and n.path ~= B.map_drag.last then B.map_drag.last = n.path; B.map_play(n.path, n.name) end
    end
  end
  return B.map_hv_id
end
-- 27 окт (5): отмеченные файлы — корабль в духе FTL справа снизу карты: отсеки — классы (kick, snare, pads, fx …),
-- в отсеке — имена файлов; двери между отсеками, двигатели слева, нос справа; lib — отмеченные в lib, save — и сохранить набором
function B.map_ship(U, L, x, y, w, h)
  local list = B.sel_order or {}
  if #list == 0 then return nil end   -- 27 окт: нечего показать — корабля нет (пустой закрывал карту)
  local cw, rh = L.cw, L.rh
  local mx, my = gfx.mouse_x, gfx.mouse_y
  -- отсеки по классам
  local rooms, by = {}, {}
  for i, o in ipairs(list) do
    local nm = (o.e and o.e.name) or (o.full or ''):match('[^/]+$') or '?'
    local parent = (o.full or ''):match('([^/]+)/[^/]+$')
    local cat = B.SM and B.SM.category(nm, parent) or 'other'
    cat = cat:gsub('^/', '')
    local r = by[cat]
    if not r then r = { name = cat, files = {} }; by[cat] = r; rooms[#rooms + 1] = r end
    r.files[#r.files + 1] = { i = i, name = nm:gsub('%.[%w]+$', ''), full = o.full }
  end
  table.sort(rooms, function(a, b) return #a.files > #b.files end)
  local RW = cw * 12                                   -- ширина отсека
  local LINES = 4                                       -- имён в отсеке, дальше «+N»
  local RH = rh * (LINES + 1) + 4
  local nr = math.max(1, #rooms)
  local per = math.ceil(nr / 2)                         -- две палубы: верхняя и нижняя
  local bodyw = per * (RW + 3) + 6
  local SW = bodyw + cw * 6                             -- + двигатели и нос
  local SH = (nr > 1 and 2 or 1) * (RH + 3) + rh + 8
  if SW > w - 8 or SH > h - 8 then
    -- не влезает — сжать: меньше имён в отсеке
    LINES = math.max(1, math.floor(((h - 8 - rh - 8) / ((nr > 1) and 2 or 1) - 4) / rh) - 1)
    RH = rh * (LINES + 1) + 4
    SH = (nr > 1 and 2 or 1) * (RH + 3) + rh + 8
    if SW > w - 8 or SH > h - 8 or LINES < 1 then return nil end
  end
  local sx, sy = x + w - SW - 6, y + h - SH - 6
  local edge = U.mix(U.LINE, U.TEXT, 0.5)
  local hull = U.mix(U.PANEL, U.LINE, 0.55)
  local bx0, by0 = sx + cw * 3, sy + rh + 4             -- корпус с отсеками
  local bx1, by1 = bx0 + bodyw, sy + SH
  local midy = math.floor((by0 + by1) / 2)
  -- двигатели: две гондолы сверху и снизу у кормы, сопла светятся янтарём
  local pw, ph = cw * 4, math.max(6, math.floor((by1 - by0) * 0.28))
  for k = 0, 1 do
    local py = k == 0 and (by0 - math.floor(ph / 2)) or (by1 - math.ceil(ph / 2))
    U.set(hull); gfx.rect(sx + cw, py, pw, ph, 1)
    U.set(edge); gfx.rect(sx + cw, py, pw, ph, 0)
    U.set(U.AMBER); gfx.rect(sx + cw - 3, py + 2, 3, ph - 4, 1)
    U.set(U.tint(U.AMBER, 0.5)); gfx.rect(sx + cw - 6, py + 3, 3, ph - 6, 1)
  end
  -- корпус: срезанные углы, нос — клином вправо
  local cut = math.min(6, math.floor((by1 - by0) / 4))
  U.set(hull)
  gfx.rect(bx0 + cut, by0, bodyw - cut, by1 - by0, 1); gfx.rect(bx0, by0 + cut, cut, by1 - by0 - 2 * cut, 1)
  for t = 0, cut - 1 do gfx.rect(bx0 + cut - t, by0 + t, 1, by1 - by0 - 2 * t, 1) end
  local nose = cw * 2
  for t = 0, nose do
    local hh = math.floor((by1 - by0) / 2 * (1 - t / (nose + 1)))
    gfx.rect(bx1 + t, midy - hh, 1, 2 * hh, 1)
  end
  U.set(edge)
  gfx.line(bx0 + cut, by0, bx1, by0); gfx.line(bx0 + cut, by1, bx1, by1)
  gfx.line(bx0, by0 + cut, bx0, by1 - cut); gfx.line(bx0, by0 + cut, bx0 + cut, by0); gfx.line(bx0, by1 - cut, bx0 + cut, by1)
  gfx.line(bx1, by0, bx1 + nose, midy); gfx.line(bx1, by1, bx1 + nose, midy)
  -- рубка сверху: счёт и кнопки
  local hv
  local tx = bx0 + 4
  local function btn(lab, id)
    local tw = U.measure(lab) + 2 * L.pad
    local hot = mx >= tx and mx < tx + tw and my >= sy and my < sy + rh
    U.set(hot and U.tint(U.AMBER, 0.3) or U.PANEL); gfx.rect(tx, sy, tw, rh, 1)
    U.set(hot and U.AMBER or edge); gfx.rect(tx, sy, tw, rh, 0)
    U.text(tx + L.pad, sy, lab, hot and U.AMBER or U.TEXT)
    if hot then hv = id end
    tx = tx + tw + 2
  end
  U.set(U.BG); gfx.rect(tx - 2, sy, U.measure('000 marked') + 4, rh, 1)
  U.text(tx, sy, ('%d marked'):format(#list), U.AMBER); tx = tx + U.measure('000 marked') + 4
  btn('lib', 'mapshiplib'); btn('save', 'mapshipsave')
  -- отсеки: две палубы, двери (янтарные чёрточки) между соседями
  local playing
  if ctx.preview_pos then local _, _, p = ctx.preview_pos(); playing = p end
  for k, r in ipairs(rooms) do
    local col_i, row_i = (k - 1) % per, (k - 1) // per
    local rx = bx0 + 4 + col_i * (RW + 3)
    local ry = by0 + 4 + row_i * (RH + 3)
    U.set(U.BG); gfx.rect(rx, ry, RW, RH, 1)
    U.set(edge); gfx.rect(rx, ry, RW, RH, 0)
    if col_i > 0 then U.set(U.AMBER); gfx.rect(rx - 3, ry + math.floor(RH / 2) - 4, 3, 8, 1) end   -- дверь к соседу слева
    if row_i > 0 then U.set(U.AMBER); gfx.rect(rx + math.floor(RW / 2) - 4, ry - 3, 8, 3, 1) end   -- дверь вверх
    U.text(rx + 3, ry + 1, ctx.fit(r.name:upper() .. ' ' .. #r.files, RW - 6), U.GREY)
    for j = 1, math.min(#r.files, LINES) do
      local f = r.files[j]
      local fy = ry + 1 + j * rh
      local hot = mx >= rx and mx < rx + RW and my >= fy and my < fy + rh
      local last = j == LINES and #r.files > LINES
      if last then U.text(rx + 3, fy, ('+%d'):format(#r.files - LINES + 1), U.GREY)
      else
        if hot then U.set(U.tint(U.AMBER, 0.2)); gfx.rect(rx + 1, fy, RW - 2, rh, 1); hv = 'mapship' .. f.i end
        U.text(rx + 3, fy, ctx.fit(f.name, RW - 6), (playing == f.full) and U.AMBER or (hot and U.TEXT or U.CYAN))
      end
    end
  end
  return hv
end
local map_draw_inner
local function map_draw(U, L, x, y, w, h)
  if not B.SM then return nil end
  local hv0
  if B.map_src == 'files' and w >= L.cw * 40 then
    local dw = math.min(math.floor(w * 0.25), L.cw * 26)
    local dirs = B.map_dirs()
    B.map_dcur = math.max(1, math.min(#dirs, B.map_dcur))
    U.set(U.PANEL); gfx.rect(x, y, dw, h, 1)
    hv0 = draw_col(U, L, dirs, x, y + 1, dw - 2, h - 2, dirs[B.map_dcur] and dirs[B.map_dcur].name, 'mapdir', gfx.mouse_x, gfx.mouse_y)
    if B.map_focus and B.mapV.zone == 'lf' then U.set(U.AMBER); gfx.rect(x, y, dw - 1, h, 0) end   -- 28 окт: часть в фокусе — рамкой
    U.set(U.LINE); gfx.rect(x + dw - 1, y, 1, h, 1)
    x, w = x + dw, w - dw
  end
  -- 27 окт (7): справа — history (сверху) и marked (снизу), во всех видах; корабль — опцией (modules > map)
  local sv
  if w >= L.cw * 44 then
    local sw = math.min(L.cw * 22, math.floor(w * 0.3))
    sv = B.map_side(U, L, x + w - sw, y, sw, h)
    if B.map_focus and (B.mapV.zone == 'hist' or B.mapV.zone == 'marked') then
      local hh = math.floor(h / 2)
      U.set(U.AMBER); gfx.rect(x + w - sw, B.mapV.zone == 'hist' and y or (y + hh), sw, B.mapV.zone == 'hist' and hh or (h - hh), 0)
    end
    w = w - sw
  end
  local hv = map_draw_inner(U, L, x, y, w, h)
  if B.map_focus and (B.mapV.zone or 'map') == 'map' then U.set(U.AMBER); gfx.rect(x, y, w, h, 0) end
  local sh = B.map_ship_on and B.map_ship(U, L, x, y, w, h)
  return hv0 or sv or sh or hv
end
-- правая панель карты: history (что сыграно с карты) и marked (отмеченные; двойной клик по файлу на карте / в истории — сюда)
function B.map_side(U, L, x, y, w, h)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local inside = mx >= x and mx < x + w and my >= y and my < y + h
  local h1 = math.floor(h / 2)
  local hv = B.SM.hist_panel(U, L, B.mapV, x, y, w, h1, ctx.fit, mx, my, inside)
  if hv then hv = hv.hprint and 'maphprint' or ('maphist' .. hv.hist) end
  -- marked
  local y2 = y + h1
  local list = B.sel_order or {}
  B.marked_tick()
  U.set(U.PANEL); gfx.rect(x, y2, w, h - h1, 1)
  U.set(U.mix(U.LINE, U.TEXT, 0.35)); gfx.rect(x, y2, w, 1, 1); gfx.rect(x, y2, 1, h - h1, 1)
  local tx = x + L.pad
  U.text(tx, y2 + 2, ('marked %d'):format(#list), #list > 0 and U.AMBER or U.GREY); tx = tx + U.measure('marked 000') + 4
  if #list > 0 then
    for _, b in ipairs({ { 'lib', 'mapshiplib' }, { 'save', 'mapshipsave' }, { 'clear', 'mapmkclear' } }) do
      local bw = U.measure(b[1]) + 2 * L.pad
      if tx + bw <= x + w - 2 then
        local hot = mx >= tx and mx < tx + bw and my >= y2 + 2 and my < y2 + 2 + L.rh
        U.set(hot and U.tint(U.AMBER, 0.3) or U.BG); gfx.rect(tx, y2 + 2, bw, L.rh - 1, 1)
        U.set(hot and U.AMBER or U.LINE); gfx.rect(tx, y2 + 2, bw, L.rh - 1, 0)
        U.text(tx + L.pad, y2 + 2, b[1], hot and U.AMBER or U.TEXT)
        if hot then hv = b[2] end
        tx = tx + bw + 2
      end
    end
  end
  local playing
  if ctx.preview_pos then local _, _, p = ctx.preview_pos(); playing = p end
  local n = math.floor((h - h1 - L.rh - 4) / L.rh)
  for i = 1, math.min(n, #list) do
    local o = list[i]
    local ry = y2 + L.rh + 4 + (i - 1) * L.rh
    local hot = inside and my >= ry and my < ry + L.rh
    if hot then U.set(U.tint(U.AMBER, 0.2)); gfx.rect(x + 1, ry, w - 1, L.rh, 1); hv = 'mapmk' .. i end
    local nm = ((o.e and o.e.name) or (o.full or ''):match('[^/]+$') or ''):gsub('%.[%w]+$', '')
    U.text(x + L.pad, ry, ctx.fit(nm, w - 2 * L.pad), (playing == o.full) and U.AMBER or (hot and U.TEXT or U.CYAN))
  end
  if #list == 0 then U.text(x + L.pad, y2 + L.rh + 4, ctx.fit('double click a file to keep it here', w - 2 * L.pad), U.DIM) end
  return hv
end
-- 27 окт (8): marked: файл в lib (и снять отметку); в папку lib — Opt+Enter
function B.mk_to_lib(i)
  local o = (B.sel_order or {})[i]
  if not (o and o.full) then return end
  if ctx.add_to_depot then ctx.add_to_depot(o.full) end
  B.map_mark(o.full, o.e and o.e.name, true)
end
-- строка marked под мышью, иначе последняя щёлкнутая
function B.mk_target()
  local id = B.map_hv_id
  local i = id and id:match('^mapmk(%d+)$')
  return tonumber(i) or (B.mk_active and B.mk_cur) or nil
end
-- двойной щелчок по тому же id за 0.35 с
function B.map_dbl(id)
  local now = R.time_precise()
  local d = B.map_lc and B.map_lc.id == id and now - B.map_lc.t < 0.35
  B.map_lc = { id = id, t = now }
  return d
end
-- отметить / снять файл (тот же список, что m в браузере)
function B.map_mark(path, name, off)
  if not path then return end
  if off then
    B.sel[path] = nil
    for i, o in ipairs(B.sel_order) do if o.key == path or o.full == path then table.remove(B.sel_order, i); break end end
  elseif not B.sel[path] then
    B.sel[path] = true
    B.sel_order[#B.sel_order + 1] = { key = path, e = { name = name or path:match('[^/]+$'), path = path }, full = path }
  end
  if ctx.msg then ctx.msg(('%s %s - marked: %d (lib / save in the marked list)'):format(off and 'unmarked' or 'marked', name or path:match('[^/]+$') or '', #B.sel_order)) end
end
B.map_draw_fn = map_draw
map_draw_inner = function(U, L, x, y, w, h)
  local G = B.mapG
  local key, files = map_source()
  if not G or G.root ~= key then
    if files then G = B.SM.from_files(key, files())   -- 27 окт: files — готовый список (db / proj / pm)
    else
      -- 27 окт (2): папка — из индекса на диске сразу; фоном — тихая проверка изменений (подмена, только если другое)
      G = B.SM.load_cache(key, B.map_cache_file(key))
      -- 27 окт (10): проверка изменений — не чаще раза в сутки на папку (обход 6700 папок по кадрам — десятки секунд CPU)
      local ck = 'mapchk_' .. key:gsub('[^%w]', '_')
      local last = tonumber(R.GetExtState('jf_tracker', ck)) or 0
      if G then
        if os.time() - last > 86400 then G.bg = B.SM.sig_build(B.mp(), list_dir); R.SetExtState('jf_tracker', ck, tostring(os.time()), true) end
      else G = B.SM.build(B.mp(), list_dir); R.SetExtState('jf_tracker', ck, tostring(os.time()), true) end
      G.root = key
    end
    B.mapG = G; B.mapV.zoom, B.mapV.px, B.mapV.py = 1, 0, 0
  end
  if ctx.prof_ext then R.SetExtState('jf_dbg', 'mapst', ('b=%s rd=%s n=%d dirs=%d st=%d bg=%s key=%s'):format(tostring(G.building), tostring(G.rd ~= nil), #G.nodes, G.ndirs or 0, G.stack and #G.stack or -1, tostring(G.bg ~= nil), tostring(G.root)) .. (' rp=%d k=%s'):format(B.SM.repaints or 0, tostring(B.SM.last_bkey)), false) end
  if not G.building and B.SM.AN then B.an_tick(G) end   -- 27 окт (9): этап 2 — анализ по кусочку
  if G.bg and not G.building then   -- 27 окт (9): проверка — после чтения индекса
    if B.SM.sig_scan(G.bg, 0) then   -- 0 — одна папка за кадр
      local S = G.bg
      G.bg = nil
      local n0, h0 = B.SM.sig_of(G)
      if S.n ~= n0 or S.h ~= h0 then   -- поменялось — полный пересбор (с индикатором), потом в индекс
        local nw = B.SM.build(B.mp(), list_dir); nw.root = key
        B.mapG = nw; G = nw
        if ctx.msg then ctx.msg(('map: the folder changed (%d -> %d files) - reading it again'):format(n0, S.n)) end
      end
    end
  elseif not files and not G.building and not G.cached and not G.saved then
    G.saved = true; B.SM.save_cache(G, B.map_cache_file(key))   -- первый скан — в индекс
  end
  G.grav = B.mapV.grav
  local sl = B.map_sl   -- 27 окт: протяжка ползунка gravity / dimension
  if sl then
    if gfx.mouse_cap & 1 == 1 then
      local v = math.max(0, math.min(1, (gfx.mouse_x - sl.x) / math.max(1, sl.w)))
      if B.mapV[sl.which] ~= v then B.mapV[sl.which] = v; if sl.which == 'grav' then G.temp = math.max(G.temp, 0.06) end end
    else B.map_sl = nil end
  end
  local playing
  if ctx.preview_pos then local _, _, p = ctx.preview_pos(); playing = p end
  local hv = B.SM.draw(U, L, G, x, y, w, h, B.mapV, playing, ctx.fit)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local inside = mx >= x and mx < x + w and my >= y and my < y + h
  if inside and gfx.mouse_wheel ~= 0 and B.mapV.style == 'cards' then   -- 27 окт (8): карточки — колесо листает
    B.SM.cards_scroll = (B.SM.cards_scroll or 0) - gfx.mouse_wheel / 120 * L.rh * 3; gfx.mouse_wheel = 0
  end
  if inside and gfx.mouse_wheel ~= 0 then   -- колесо — зум к центру
    B.mapV.zoom = math.max(0.3, math.min(8, B.mapV.zoom * (gfx.mouse_wheel > 0 and 1.15 or 1 / 1.15))); gfx.mouse_wheel = 0
  end
  local pan = B.map_pan
  if pan then
    if gfx.mouse_cap & 1 == 1 then B.mapV.px, B.mapV.py = pan.px + mx - pan.mx, pan.py + my - pan.my else B.map_pan = nil end
  end
  B.map_hv = hv
  if hv and hv.mfilter then return 'mapflt_' .. hv.mfilter elseif hv and hv.hprint then return 'maphprint' elseif hv and hv.mtype then return 'mapty_' .. hv.mtype elseif hv and hv.hist then return 'maphist' .. hv.hist elseif hv and hv.slider then return 'mapsl' elseif hv and hv.back then return 'mapback' elseif hv and hv.style then return 'mapstyle' elseif hv and hv.random then return 'maprandom' elseif hv and hv.node then return 'mapnode' elseif hv and hv.hub then return 'maphub' elseif inside then return 'mapbg' end
  return nil
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
-- 17 окт: длина файла (с) — для фильтра >2s / <0.5s; кэш по пути, файл открывается один раз
B.lencache = {}
local function file_len(e)
  if e.dir or not e.path then return nil end
  local v = B.lencache[e.path]
  if v == nil then
    v = false
    local src = R.PCM_Source_CreateFromFile and R.PCM_Source_CreateFromFile(e.path)
    if src then v = R.GetMediaSourceLength(src) or false; R.PCM_Source_Destroy(src) end
    B.lencache[e.path] = v
  end
  return v or nil
end
B.file_len = file_len
local function fmatch(e, terms)
  local hay = (e.label or e.name):lower()
  local base = (e.name:match('[^/]+$') or e.name):lower()
  local total, exact = 0, true
  for _, t0 in ipairs(terms) do
    local t, neg = t0, false
    if t:sub(1, 1) == '!' or (t:sub(1, 1) == '-' and #t > 1) then neg, t = true, t:sub(2) end   -- 17 окт: -drum = !drum
    local sc
    local cmp, num = t:match('^([<>])(%d*%.?%d+)s?$')   -- 17 окт: >2s / <0.5s — по длине файла (папки не проходят)
    if cmp then
      local l = file_len(e)
      sc = (l and ((cmp == '>' and l > tonumber(num)) or (cmp == '<' and l < tonumber(num)))) and 0 or nil
    elseif t == '' then sc = 0
    elseif neg then sc = hay:find(t, 1, true) and 0 or nil   -- 17 окт: «без» — по подстроке (нечёткое «без» выкидывало лишнее)
    elseif t:sub(1, 1) == "'" then sc = hay:find(t:sub(2), 1, true) and 10 or nil
    elseif t:sub(1, 1) == '^' then sc = (base:sub(1, #t - 1) == t:sub(2)) and 10 or nil
    elseif #t > 1 and t:sub(-1) == '$' then local s = t:sub(1, -2); sc = (base:sub(-#s) == s) and 10 or nil
    else sc = fz(hay, t); if sc and not hay:find(t, 1, true) then exact = false end end   -- 19 окт: подстрока — точное совпадение
    if neg then if sc then return nil end
    else if not sc then return nil end; total = total + sc end
  end
  return total, exact
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
    table.sort(terms, function(a, b) local la, lb = a:match('^[<>]') ~= nil, b:match('^[<>]') ~= nil; return (not la) and lb end)   -- 17 окт: длина — последней (файл открывается только у совпавших по словам)
    local hits, ex = {}, {}
    for _, e in ipairs(src) do
      local sc, exact = fmatch(e, terms)
      if sc then hits[#hits + 1] = { e = e, sc = sc }; if exact then ex[#ex + 1] = hits[#hits] end end
    end
    -- 19 окт: есть совпадения подстрокой (alarm в имени) — только они; нечёткое (a…l…a…r…m) — когда точных нет
    if #ex > 0 then hits = ex end
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
  -- 11 окт: пресеты lib (jf_libs + прежние jf_kits) — Enter заменяет lib трека курсора
  for _, e in ipairs(ctx.lib_presets and ctx.lib_presets() or {}) do out[#out + 1] = { name = e.name, path = e.path, kit = true } end
  if #out == 0 then out[1] = { name = '(no lib presets yet - the preset name in the lib header: save)', kit = false, dir = false, empty = true } end
  return out
end

-- 16 окт: пресеты инструментов — TrackTemplates/presets/<категория>/*.RTrackTemplate (ctx.presets_list)
function B.read_presets()
  local out = {}
  for _, e in ipairs(ctx.presets_list and ctx.presets_list(B.prdir) or {}) do out[#out + 1] = e end
  if #out == 0 then out[1] = { name = B.prdir and '(empty - n saves the cursor track here)' or '(no presets yet - n saves the cursor track as one)', empty = true } end
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
  -- 17 окт: бэкапы проекта сверху — автосохранения REAPER (.rpp-bak в AutoSaves / рядом / !unsaved), новые первыми
  local baks = {}
  local _, pfile = R.EnumProjects(-1, '')
  local pdir = pfile and pfile:match('^(.*)/[^/]+$')
  local base = pfile and (pfile:match('([^/]+)%.[Rr][Pp][Pp]$') or '')
  local dirs = {}
  if pdir then dirs[#dirs + 1] = pdir .. '/AutoSaves'; dirs[#dirs + 1] = pdir end
  if R.get_config_var_string then local ok, v = R.get_config_var_string('autosavedir_unsaved'); if ok and v ~= '' and not pdir then dirs[#dirs + 1] = v end end
  for _, d in ipairs(dirs) do
    local i = 0
    while true do
      local f = R.EnumerateFiles(d, i)
      if not f then break end
      if f:lower():match('%.rpp%-bak$') and (not base or base == '' or f:sub(1, #base) == base) then
        local stamp = f:match('(%d%d%d%d%-%d%d%-%d%d_%d%d%d%d)') or ''
        baks[#baks + 1] = { name = ('backup %s'):format(stamp ~= '' and (stamp:sub(1, 10) .. ' ' .. stamp:sub(12, 13) .. ':' .. stamp:sub(14, 15)) or f), path = d .. '/' .. f, bak = true, dir = false, stamp = stamp ~= '' and stamp or f }
      end
      i = i + 1
    end
  end
  table.sort(baks, function(a, b) return a.stamp > b.stamp end)
  local res = {}
  for k = 1, math.min(#baks, 40) do res[#res + 1] = baks[k] end
  for _, e in ipairs(out) do res[#res + 1] = e end
  return res
end

-- вкладка fx (7 окт, опция browser left): список эффектов внутри браузера —
-- рисует main (B.fx_draw), hover — в B.fx_hover
B.fx_draw, B.fx_hover = nil, nil
function B.set_mode(m)
  if m == 'fx' and B.fx_draw then B.mode = 'fx'; return end
  if m == 'map' then if ctx.pane_focus then ctx.pane_focus('map') end; return end   -- 27 окт (3): карта — своя панель
  if m ~= 'files' and m ~= 'db' and m ~= 'pm' and m ~= 'proj' and m ~= 'libs' and m ~= 'presets' and m ~= 'recent' then return end
  B.mode = m; B.cur = 1; B.filter = ''; B.filtering = false
  B.pmproj, B.pmdir = nil, nil
  B.pm_scroll.v = 0
  if m == 'presets' then B.prdir = nil end
  if m == 'files' then B.refresh() elseif m == 'db' then B.refresh_db() elseif m == 'proj' then B.set_all(B.read_proj()) elseif m == 'libs' then B.set_all(B.read_kits()) elseif m == 'presets' then B.set_all(B.read_presets()) elseif m == 'recent' then B.recent_list() else B.set_all(B.read_pm()) end
end

-- кнопки шапки: files | db | size | hide
function B.click(what)
  -- 9 окт: панели — кнопка файлового режима в панели pm переводит в панель browser
  if B.pmpane and B.mode == 'pm' and (what == 'files' or what == 'db' or what == 'proj' or what == 'libs') and ctx.browser_from_pm then
    ctx.browser_from_pm(what); return
  end
  if what == 'files' or what == 'db' or what == 'pm' or what == 'proj' or what == 'libs' or what == 'presets' or what == 'recent' or what == 'map' or what == 'fx' then B.set_mode(what)
  elseif what == 'auto' then B.auto = not B.auto
  elseif what == 'keys' then B.keys = not B.keys
  elseif what == 'drum' then B.drum = not B.drum; if ctx.drum_audition_toggle then ctx.drum_audition_toggle(B.drum) end
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
  elseif what == 'wscroll' then
    B.wscroll = not B.wscroll
    if R.SetExtState then R.SetExtState('jf_tracker', 'brwscroll', B.wscroll and '1' or '0', true) end
    if ctx.msg then ctx.msg(B.wscroll and 'wheel scrolls the list, the cursor stays (click, j k, f move it)' or 'wheel moves the cursor') end
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
    B.mark(tonumber(what:sub(3)), m.alt and 'clear' or (m.shift and 'set' or nil))   -- 20 окт: Opt+клик — очистить (было Cmd)
  elseif what == 'mapnode' then   -- 27 окт: узел карты — слушать
    local n = B.map_hv and B.map_hv.node
    if n and (n.path or ''):lower():match('%.rpp$') then if ctx.msg then ctx.msg('map: project ' .. n.name .. '  (' .. n.cat .. ') - open it in the pm tab') end   -- 27 окт: проект не слушается
    elseif n and B.map_dbl('n:' .. n.path) then B.map_mark(n.path, n.name)   -- 27 окт (7): двойной — в marked
    elseif n then B.map_drag = { last = n.path }; B.map_play(n.path, n.name); if ctx.msg then ctx.msg('map: ' .. n.name .. '  (' .. n.cat .. ')') end end
  elseif what == 'mapstyle' then B.mapV.style = (B.map_hv and B.map_hv.style) or 'graph'; B.mapV.sys = nil; R.SetExtState('jf_tracker', 'mapstyle', B.mapV.style, true); if ctx.msg then ctx.msg('map: ' .. B.mapV.style .. ' view  (v - next view, r - a random sample)') end
  elseif what == 'maprandom' then B.map_random()
  elseif what:match('^mapdir%d+$') then B.map_dcur = tonumber(what:sub(7)); B.map_enter()
  elseif what == 'mapshiplib' then B.enter_marked()
  elseif what == 'mapmkclear' then B.sel, B.sel_order = {}, {}; if ctx.msg then ctx.msg('marked: cleared') end
  elseif what == 'mapshipsave' then if ctx.marked_to_lib_save then ctx.marked_to_lib_save() end
  elseif what:match('^mapship%d+$') then   -- 27 окт (4): отмеченный файл в корабле — слушать
    local o = (B.sel_order or {})[tonumber(what:sub(8))]
    if o and o.full then B.map_play(o.full, o.e and o.e.name); if ctx.msg then ctx.msg('marked: ' .. (o.e and o.e.name or o.full) .. '  (Space in the browser - all of them in a row)') end end
  elseif what:match('^maphist%d+$') then   -- 27 окт (5): строка истории — ещё раз
    local e = B.map_hist[tonumber(what:sub(8))]
    if e and B.map_dbl('n:' .. e.path) then B.map_mark(e.path, e.name)
    elseif e then B.map_play(e.path, e.name, true); if ctx.msg then ctx.msg('history: ' .. e.name .. '  (double click - into marked)') end end
  elseif what:match('^mapmk%d+$') then   -- 27 окт (7): marked: клик — слушать, двойной — снять отметку
    local o = (B.sel_order or {})[tonumber(what:sub(6))]
    B.mk_cur = tonumber(what:sub(6)); B.mk_active = true
    if o and B.map_dbl('m:' .. (o.full or '')) then B.mk_to_lib(B.mk_cur)   -- 27 окт (8): двойной — в lib (снять — x / dd)
    elseif o and o.full then B.map_play(o.full, o.e and o.e.name) end
  elseif what == 'pvslx' then   -- 27 окт: плеер — новый трек со slixer и этим файлом
    if B.pv_cur then ctx.to_slixer(B.pv_cur, nil, nil, true) elseif ctx.msg then ctx.msg('slixer: play or select a file first') end
  elseif what == 'pvdrum' then   -- 27 окт: плеер — пэд drumrs5k (есть рэк на треке — в свободную ноту, нет — новый рэк)
    if B.pv_cur and ctx.drum_add_files then ctx.drum_add_files({ B.pv_cur }) elseif ctx.msg then ctx.msg('drumrs5k: play or select a file first') end
  elseif what == 'maphprint' then if ctx.map_print_menu then ctx.map_print_menu() end   -- 27 окт (8): история — в трекер
  elseif what:match('^mapflt_') then   -- 28 окт: фильтр карты вкл / выкл — группы пересобираются из того же списка
    local k = what:sub(8)
    B.SM.FON[k] = not B.SM.FON[k] or nil
    local t = {}; for kk in pairs(B.SM.FON) do t[#t + 1] = kk end
    R.SetExtState('jf_tracker', 'mapflt', table.concat(t, ','), true)
    local G = B.mapG
    if G and not G.building then G.nodes = G.raw; G.neb, G.gal, G.lab_order, G.tree = nil, nil, nil, nil; B.SM.finish(G) end
    if ctx.msg then ctx.msg(('map filter %s %s: %d of %d files'):format(k, B.SM.FON[k] and 'on' or 'off', G and #G.nodes or 0, G and #(G.raw or {}) or 0)) end
  elseif what:match('^mapty_') then   -- 27 окт (8): типы файлов карты вкл / выкл
    local t = what:sub(7)
    B.mapV.types[t] = not B.mapV.types[t] or nil
    R.SetExtState('jf_tracker', 'maptypes', B.types_key(), true)
    B.mapG = nil
    if ctx.msg then ctx.msg('map: ' .. (B.types_key() ~= '' and B.types_key() or 'nothing') .. ' (samples midi rex automation items track templates)') end
  elseif what == 'mapback' then B.mapV.sys = nil; B.mapV.zoom, B.mapV.px, B.mapV.py = 1, 0, 0
  elseif what == 'maphub' and not (ctx.mods and ctx.mods().shift) and B.map_hv and B.map_hv.sector then   -- 27 окт (2): nebula — сектор в систему (на весь вид)
    B.mapV.sys = B.map_hv.hub.name; B.mapV.zoom, B.mapV.px, B.mapV.py = 1, 0, 0
    if ctx.msg then ctx.msg(('map: %s system - %d file(s); galaxy / Esc - back, r - random from it'):format(B.map_hv.hub.name, B.map_hv.hub.n)) end
  elseif what == 'maphub' and not (ctx.mods and ctx.mods().shift) then   -- 27 окт (2): клик — приблизить группу; Shift+клик — отметить её файлы
    local hb = B.map_hv and B.map_hv.hub
    if hb then B.mapV.zoom = math.min(8, (B.mapV.zoom or 1) * 2.5); if ctx.msg then ctx.msg(('map: %s - %d file(s); Shift+click marks them, wheel / drag - zoom / move'):format(hb.name, hb.n)) end end
  elseif what == 'maphub' then   -- 27 окт: Shift+клик по категории — её файлы в отметки (Space — плейлистом, Enter — в lib)
    local hb = B.map_hv and B.map_hv.hub
    if hb and B.mapG then
      local nn = 0
      for _, n in ipairs(B.mapG.nodes) do
        if n.h == hb and not B.sel[n.path] then B.sel[n.path] = true; B.sel_order[#B.sel_order + 1] = { key = n.path, e = { name = n.name, path = n.path }, full = n.path }; nn = nn + 1 end
      end
      if ctx.msg then ctx.msg(('map: %s - %d file(s) marked (Space - play them in a row, Enter - into the lib, u - unmark)'):format(hb.name, nn)) end
    end
  elseif what == 'projmap' then B.map_src = 'proj'; B.mapG = nil; B.set_mode('map'); if ctx.msg then ctx.msg('map: the sources of the project (the map pane)') end
  elseif what:match('^mapsrc_') then B.map_src = what:sub(8); B.mapG = nil; if ctx.msg then ctx.msg('map: ' .. B.map_src) end
  elseif what == 'mapsl' then local s0 = B.map_hv; if s0 then B.map_sl = { which = s0.slider, x = s0.x, w = s0.w } end
  elseif what == 'mapbg' then B.map_pan = { mx = gfx.mouse_x, my = gfx.mouse_y, px = B.mapV.px, py = B.mapV.py }
  elseif what:match('^rec%d+$') then   -- 27 окт: отмеченный файл (плеер большого браузера) — играть
    local pth = (B.mk_list or {})[tonumber(what:sub(4))]
    if pth then B.pl = nil; ctx.preview_file(pth) end
  elseif what:match('^pcol%d+$') then   -- 27 окт: колонка родителя — туда (папка) / к файлу в ней
    local e = B.pcol and B.pcol.list[tonumber(what:sub(5))]
    if e then
      if e.dir then B.go(join(B.pcol.path, e.name))
      else B.go(B.pcol.path); for i, x in ipairs(B.entries) do if x.name == e.name then B.cur = i; break end end end
    end
  elseif what:match('^ncol%d+$') then   -- 27 окт: колонка превью — внутрь папки под курсором
    local e = B.ncol and B.ncol.list[tonumber(what:sub(5))]
    if e then
      local name = e.name
      if e.dir then B.go(join(B.ncol.path, name))
      else B.go(B.ncol.path); for i, x in ipairs(B.entries) do if x.name == name then B.cur = i; break end end end
    end
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

-- отметка строк (10 окт, как Insert в Midnight Commander / пробел в ranger):
-- m — отметить / снять строку и шаг вниз, M — снять все. Ключ — полный путь,
-- поэтому отметки живут при переходах по папкам: собрать файлы из разных
-- папок и Enter — все в lib по порядку отметки
B.sel, B.sel_order = {}, {}
local function markable(e) return e and not (e.dir or e.db or e.pmdir or e.pmfolder or e.empty or e.mark) end
function B.mkey(e) return e and (e.pm and ('pm:' .. (e.path or e.name)) or B.full(e)) end
function B.nmarked() return #B.sel_order end
function B.is_marked(e) return e and B.sel[B.mkey(e)] ~= nil end
function B.toggle_mark()
  local e = B.entries[B.cur]
  if markable(e) then
    local k = B.mkey(e)
    if B.sel[k] then
      B.sel[k] = nil
      for i, o in ipairs(B.sel_order) do if o.key == k then table.remove(B.sel_order, i); break end end
    else
      B.sel[k] = true
      B.sel_order[#B.sel_order + 1] = { key = k, e = e, full = B.full(e) }
    end
    if ctx.msg then ctx.msg(('%d marked - Enter: all into the lib, u: unmark all'):format(#B.sel_order)) end
  end
  B.cur = math.min(#B.entries, B.cur + 1)
end
-- 17 окт: мышью — Cmd+щелчок отмечает / снимает строку, Shift+щелчок — отрезок от прошлой строки (отметки, как m)
function B.mark_at(i, on)
  local e = B.entries[i]
  if not markable(e) then return end
  local k = B.mkey(e)
  if on == nil then on = not B.sel[k] end
  if on and not B.sel[k] then B.sel[k] = true; B.sel_order[#B.sel_order + 1] = { key = k, e = e, full = B.full(e) }
  elseif not on and B.sel[k] then
    B.sel[k] = nil
    for j, o in ipairs(B.sel_order) do if o.key == k then table.remove(B.sel_order, j); break end end
  end
end
function B.mark_range(a, b)
  for i = math.min(a, b), math.max(a, b) do B.mark_at(i, true) end
  if ctx.msg then ctx.msg(('%d marked - Enter: all into the lib, u: unmark all'):format(#B.sel_order)) end
end
function B.clear_marks()
  B.sel, B.sel_order = {}, {}
  if ctx.msg then ctx.msg('marks cleared') end
end
-- Enter при отметках: отмеченные файлы — в lib по порядку отметки (проекты pm,
-- дорожки, регионы — пока только файлы); отметки снимаются
function B.enter_marked()
  local n = 0
  for _, o in ipairs(B.sel_order) do
    local e = o.e
    if not (e.pm or e.trk or e.rgn or e.kit or e.other) and ctx.add_to_depot then ctx.add_to_depot(o.full); n = n + 1 end
  end
  B.sel, B.sel_order = {}, {}
  if ctx.msg then ctx.msg(('%d file(s) into the lib'):format(n)) end
  return n
end

function B.enter()
  local e = B.entries[B.cur]
  if not e then return end
  if e.bak then   -- 17 окт: бэкап — открыть (REAPER спросит, сохранить ли текущий)
    R.Main_openProject(e.path); if ctx.msg then ctx.msg('opened ' .. e.name .. ' - File > Save as to keep it as the project') end; return
  end
  if e.db then B.db = e; B.cur = 1; B.filter = ''; B.refresh_db()
  elseif e.pmdir then B.pmdir = e.pmdir; B.cur = 1; B.filter = ''; B.refresh_pm()
  elseif e.pmfolder then B.pmfolder = e.pmfolder; B.pm = nil; B.cur = 1; B.filter = ''; B.set_all(B.read_pm())   -- папка проектов (без jf_pm)
  elseif e.dir then B.go(B.full(e))
  elseif e.pm and B.grid and PMm() then if ctx.pm_open_project then ctx.pm_open_project(e.path, e.name) end   -- сетка: Enter — открыть (внутрь — Shift+Enter)
  elseif e.pm then B.pm_open(e)                         -- проект → внутрь, как папка
  elseif e.kit then if ctx.kit_load then ctx.kit_load(e.path, e.name) end   -- набор → lib трека курсора
  elseif e.prdir then B.prdir = e.prdir; B.cur = 1; B.filter = ''; B.set_all(B.read_presets())   -- 16 окт: папка пресетов (pad bass …)
  elseif e.preset then if ctx.preset_load then ctx.preset_load(e.path, e.name) end   -- пресет → цепочка FX трека курсора
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
  if (e.name or ''):lower():match('%.xrni$') or (e.name or ''):lower():match('%.sfz$') then return nil end   -- инструмент (архив / текст SFZ), не звук
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
  if B.mode == 'presets' then
    if B.prdir then B.prdir = nil; B.cur = 1; B.set_all(B.read_presets()) end
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
  local parent, child = B.path:match('(.*)/([^/]+)$')
  if parent then
    B.go(parent ~= '' and parent or '/')
    for i, e in ipairs(B.entries) do if e.dir and e.name == child then B.cur = i; break end end   -- 27 окт: как в lf — курсор на папке, из которой вышли
  end
end

-- строка описания для статус-бара
function B.describe(idx)
  local e = B.entries[idx]
  if not e then return '' end
  if e.bak then return e.name .. ' - an autosave of this project; Enter / double click: open it (REAPER asks to save the current one)' end
  if e.db then return ('database %s (%s) - Enter: open'):format(e.name, e.file) end
  if e.dir then return '' end                                       -- 5 окт: без имени / пути папки
  if e.pm and e.card and PMm() then return PMm().describe(e) end
  if e.pm then
    local len = e.len and e.len > 0 and (' %d:%02d'):format(math.floor(e.len / 60), math.floor(e.len % 60)) or ''
    return ('project %s%s - Enter: inside, o: open in REAPER, T: tags, s: status, drag to track: subproject, Space: preview%s'):format(e.path, len, B.pm_preview(e) and '' or ' (no render)')
  end
  if e.pmdir then return 'inside project: ' .. e.name .. ' - Enter: open' end
  if e.kit then return ('lib preset %s (REAPER track template) - Enter: it replaces the lib of the cursor track (Cmd+Z back)'):format(e.name) end
  if e.preset then return ('instrument preset %s (track template) - Enter: its fx chain on the cursor track, the items stay (Cmd+Z back); n saves the cursor track here'):format(e.name) end
  if e.prdir then return ('presets folder %s - Enter: inside, h: back, n: save the cursor track here'):format(e.name) end
  if e.trk then return ('track "%s" (%d files) - Enter / drag: insert this track into the project (state chunk)'):format(e.name, e.nfiles or 0) end
  if e.rgn then return ('region %s [%.2f - %.2f] - Enter: subproject trimmed to region @cursor, drag: to track/row'):format(e.name, e.pos, e.fin) end
  if e.mark then return 'marker ' .. e.name end
  if e.proj then return ('%s - used %d× (first on %s); Enter: to the lib of the cursor track, drag: to track, v: sample view'):format(e.path, e.n, e.track or '?') end
  local len = e.len and (' %d:%05.2f'):format(math.floor(e.len / 60), e.len % 60) or ''
  return ('%sEnter: to lib, Space: preview, v: view in sample tab, drag: to track'):format(len ~= '' and (len:sub(2) .. ' - ') or '')
end

function B.preview()
  if B.pl then B.pl = nil; if ctx.preview_stop then ctx.preview_stop() end; if ctx.msg then ctx.msg('playlist: stopped') end; return end
  if #B.sel_order > 1 then B.pl_start(); return end   -- 27 окт: отмеченные — плейлистом
  local pth = B.preview_path(B.entries[B.cur])
  if pth then ctx.preview_file(pth) end
end
-- 27 окт: что прозвучало — в recent: больше 0.5 с или включалось 2+ раза (любой путь: Space, auto, щелчок, плейлист)
B.plays = {}
function B.hear_tick()
  if not ctx.preview_pos then return end
  local pos, len, path = ctx.preview_pos()
  local H = B.hear or {}
  B.hear = H
  if not (pos and path) then H.path = nil; return end
  if path ~= H.path or pos < (H.pos or 0) - 0.1 then   -- новый запуск
    H.path, H.done = path, false
    B.plays[path] = (B.plays[path] or 0) + 1
    if B.plays[path] >= 2 then B.add_recent(path); H.done = true end
  end
  H.pos = pos
  if not H.done and (pos >= 0.5 or (len and len > 0 and len < 0.5 and pos >= len - 0.05)) then B.add_recent(path); H.done = true end
end
-- 27 окт: НЕДАВНИЕ — последние 50 прослушанных файлов (вкладка recent), Data/jf_tracker_recent.txt
B.RECENT_MAX = 50
local function rfile() return R.GetResourcePath and (R.GetResourcePath() .. '/Data/jf_tracker_recent.txt') or nil end
function B.recent_load()
  if B.recent then return B.recent end
  B.recent = {}
  local f = rfile() and io.open(rfile(), 'r')
  if f then for line in f:lines() do if line ~= '' then B.recent[#B.recent + 1] = line end end; f:close() end
  return B.recent
end
function B.add_recent(path)
  if not path or path == '' then return end
  local rc = B.recent_load()
  for i = #rc, 1, -1 do if rc[i] == path then table.remove(rc, i) end end
  table.insert(rc, 1, path)
  while #rc > B.RECENT_MAX do table.remove(rc) end
  local fn = rfile()
  local f = fn and io.open(fn, 'w')
  if f then f:write(table.concat(rc, '\n'), '\n'); f:close() end
  if B.mode == 'recent' and not B.pl then B.recent_list() end
end
function B.recent_list()
  local out = {}
  for _, pth in ipairs(B.recent_load()) do
    out[#out + 1] = { name = pth:match('([^/]+)$') or pth, path = pth, meta = (pth:match('(.*)/[^/]+$') or ''):match('([^/]+)$') }
  end
  B.set_all(out)
end
-- 27 окт: ПЛЕЙЛИСТ — отмеченные файлы (m) по очереди, в порядке отметки: Space — играть / стоп; конец файла — следующий
function B.pl_start()
  local list = {}
  for _, o in ipairs(B.sel_order) do if o.full and B.preview_path(o.e) then list[#list + 1] = o.full end end
  if #list == 0 then return end
  B.pl = { list = list, i = 0 }
  B.pl_next()
end
function B.pl_next()
  local pl = B.pl
  if not pl then return end
  pl.i = pl.i + 1
  if pl.i > #pl.list then B.pl = nil; if ctx.msg then ctx.msg('playlist: done') end; return end
  local pth = pl.list[pl.i]
  ctx.preview_file(pth)
  pl.t0 = R.time_precise and R.time_precise() or os.clock()
  if ctx.msg then ctx.msg(('playlist %d / %d: %s (Space - stop)'):format(pl.i, #pl.list, pth:match('([^/]+)$') or pth)) end
end
function B.pl_tick()
  local pl = B.pl
  if not (pl and ctx.preview_pos) then return end
  local now = R.time_precise and R.time_precise() or os.clock()
  if now - (pl.t0 or 0) < 0.4 then return end              -- превью ещё стартует
  local pos, len, path = ctx.preview_pos()
  if pos and path ~= pl.list[pl.i] then B.pl = nil; return end   -- играет другое (щелчок, auto) — плейлист уступает
  if not pos or (len and len > 0 and pos >= len - 0.03) then B.pl_next() end
end

function B.refilter_soon() if R.time_precise then B.filter_due = R.time_precise() + 0.25 else B.set_all(B.all) end end
-- клавиши в фокусе браузера; true — съедена
function B.key(c)
  local ch = c < 256 and string.char(c) or ''
  if B.filtering then
    -- набор запроса: символы сужают список (fzf), стрелки ходят по результатам,
    -- Enter — закончить набор (результаты остаются), Esc — сбросить, BS — стереть
    if c == 27 then B.filtering = false; B.filter = ''; B.set_all(B.all)
    elseif c == 13 then B.filtering = false; if B.filter_due then B.filter_due = nil; B.set_all(B.all) end
    elseif c == 1685026670 then B.cur = math.min(#B.entries, B.cur + 1)
    elseif c == 30064 then B.cur = math.max(1, B.cur - 1)
    elseif c == 8 then B.filter = TX.bs(B.filter); B.cur = 1; B.refilter_soon()   -- 19 окт: ищем, когда набор замер на 0.25 с
    elseif TX.char(c) then B.filter = B.filter .. TX.char(c); B.cur = 1; B.refilter_soon()   -- 20 окт: и кириллица
    else return false end
    return true
  end
  if B.keys and ctx.browser_note and ctx.browser_note(c) then return true end   -- keys: q 2 w 3 e … — файл с высотой
  -- pm-сетка (6 окт): свои клавиши (hjkl по сетке, Enter открыть, Space слушать, p pin …)
  if B.mode == 'pm' and B.grid and not B.pmproj and not B.pm_folders and PMm() then
    if c == 27 and ctx.pm_big_on and ctx.pm_big_on() and B.filter == '' then if ctx.pm_big then ctx.pm_big() end; return true end
    if PMm().key(c, B, ctx.mods and ctx.mods() or {}) then return true end
  end
  -- 20 окт: цифры — счётчик, как в Vim (10j 5k 3G); закладка — '1 … '0 (как метки Vim 'a), Shift+цифра — поставить
  if B.quote then
    B.quote = nil
    if ch:match('^%d$') then B.count = nil; B.mark(ch == '0' and 10 or tonumber(ch), 'go'); return true end
    if c == 27 then B.count = nil; return true end
  end
  if ch == "'" then B.quote = true; if ctx.msg then ctx.msg("' - a bookmark: 1 ... 0") end; return true end
  if ch:match('^%d$') and not (ch == '0' and not B.count) then B.count = (B.count or 0) * 10 + tonumber(ch); if ctx.msg then ctx.msg(tostring(B.count)) end; return true end
  local n = B.count or 1
  local had_count = B.count ~= nil
  B.count = nil
  if c == 27 and had_count then return true end   -- Esc — только сбросить набранный счётчик
  if MARK_SHIFT[ch] then B.mark(MARK_SHIFT[ch], 'set')
  elseif ch == 'H' then B.history(-1)
  elseif ch == 'L' then B.history(1)
  elseif ch == '/' then B.start_find()                           -- поиск прямо в списке (2 окт); 26 окт: f — прыжок по меткам, как в других модулях
  elseif ch == 't' then B.set_mode(({ files = 'db', db = (B.pmpane and 'proj' or 'pm'), pm = 'proj', proj = 'libs', libs = 'presets', presets = 'files' })[B.mode] or 'files')   -- 9 окт: в панелях pm — своя панель
  elseif ch == 'p' then B.click('auto')
  elseif ch == 'o' then local e = B.entries[B.cur]; if e and e.pm and ctx.pm_open_project then ctx.pm_open_project(e.path, e.name) end
  elseif ch == 'T' then local e = B.entries[B.cur]; if e and e.pm and ctx.pm_tags then ctx.pm_tags(e) end        -- теги jf_pm
  elseif ch == 's' then local e = B.entries[B.cur]; if e and e.pm and ctx.pm_status then ctx.pm_status(e) end     -- статус jf_pm
  elseif ch == 'v' then local e = B.entries[B.cur]; local pth = B.preview_path(e); if pth and ctx.sample_view then ctx.sample_view(pth) end
  elseif ch == 'w' then B.click('size')
  elseif ch == 'q' then B.click('hide')
  elseif c == 27 and B.filter ~= '' then B.filter = ''; B.set_all(B.all)
  elseif ch == 'j' or c == 1685026670 then B.cur = math.max(1, math.min(#B.entries, B.cur + n))
  elseif ch == 'k' or c == 30064 then B.cur = math.max(1, B.cur - n)
  elseif ch == 'g' then B.cur = 1
  elseif ch == 'G' then B.cur = had_count and math.max(1, math.min(#B.entries, n)) or #B.entries   -- 3G — третья строка
  elseif c == 13 and ctx.sf_enter and ctx.sf_enter() then   -- 20 окт: Shift+F — найденный сэмпл на место в трекере (первым: пэд / отметки не перехватывают)
  elseif c == 13 and ctx.mods and ctx.mods().cmd then if ctx.browser_replace then ctx.browser_replace() end   -- Cmd+Enter: заменить сэмпл инструмента
  elseif c == 13 and ctx.mods and ctx.mods().alt then   -- Opt+Enter (7 окт): файл — слайсом выбранного инструмента
    local e = B.entries[B.cur]
    if e and not (e.dir or e.db or e.pm or e.pmdir or e.kit or e.trk or e.rgn or e.mark or e.other or e.empty) and ctx.lib_append_slice then ctx.lib_append_slice(B.full(e)) end
  elseif ch == 'n' and B.mode == 'presets' and ctx.preset_save_menu then ctx.preset_save_menu(B.prdir)   -- 16 окт: трек курсора — пресетом
  elseif ch == 'a' and ctx.browser_send_menu then ctx.browser_send_menu()   -- 16 окт: add to: lib / drumrs5k / сэмплер / список / слайсы
  elseif ch == 'm' then B.toggle_mark()                                -- 10 окт: отметка строк
  elseif ch == 'u' then B.clear_marks()                                -- 12 окт: u — снять все отметки, как в lf (было M)
  elseif c == 13 and ctx.drum_browser_enter and (function()   -- 19 окт: выбран пэд drumrs5k — файл(ы) в рэк
      local fs = {}
      if #B.sel_order > 0 then for _, o in ipairs(B.sel_order) do if o.full then fs[#fs + 1] = o.full end end
      else local e = B.entries[B.cur]; if e and not e.dir and not e.pm and not e.db and not e.kit then fs[1] = B.full(e) end end
      return #fs > 0 and ctx.drum_browser_enter(fs)
    end)() then
  elseif c == 13 and ctx.mods and ctx.mods().alt and ctx.files_to_folder then   -- 27 окт (8): Opt+Enter — в lib папкой (отмеченные, иначе файл курсора)
    local fs = {}
    for _, o in ipairs(B.sel_order) do if o.full then fs[#fs + 1] = o.full end end
    local e = B.entries[B.cur]
    if #fs == 0 and e and not (e.dir or e.pm or e.trk or e.rgn or e.kit or e.other or e.db or e.empty or e.mark) then fs[1] = B.full(e) end
    if #fs > 0 then B.sel, B.sel_order = {}, {} end
    ctx.files_to_folder(fs)
  elseif c == 13 and #B.sel_order > 0 then B.enter_marked()
  elseif c == 13 or ch == 'l' then B.enter()
  elseif c == 8 or ch == '-' or ch == 'h' then B.up()
  elseif ch == ' ' then B.preview()
  elseif c == 9 or c == 27 then if c == 27 and ctx.sf_target then ctx.sf_target = nil; if ctx.msg then ctx.msg('sample find: cancelled') end end; ctx.toggle_focus()
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

-- 27 окт (7): плеер браузера — мини-волна, play / keys / cell, громкость, кнопки wave track sync …; одна функция
-- для браузера и панели map (тот же плеер, те же кнопки). btn(bx, by, label, what, on) рисует кнопку (hover — у вызывающего)
-- → h без плеера, hover плеера
function B.player_block(U, L, x, y, w, h, btn, opts)
  opts = opts or {}
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local hover
  if opts.buttons then         -- 9 окт: панель pm — без файловых кнопок (find wave track sync …)
    local by = y + h - L.rh - 2
    local bx = x + L.pad + 2
    for _, b in ipairs({ { 'wave', 'wave', B.wave },   -- 11 окт: find — слева от стрелок < > (на виду), здесь не дублируется
                         { 'track', 'track', B.via_track }, { 'sync', 'sync', B.sync }, { 'scroll', 'wscroll', B.wscroll }, { '*.*', 'allfiles', B.all_files }, { '.*', 'hidden', B.hidden } }) do
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
    if w >= L.cw * 90 then wh = math.max(wh, math.min(8 * L.rh, math.floor(h * 0.12))) end   -- 27 окт: браузер развёрнут — плеер выше
    local wy = sy - wh - 2
    local x0, ww = x + L.pad + 2, w - 2 * L.pad - 4
    -- 27 окт: большой браузер — справа от волны плеера отмеченные файлы (m; щелчок — играть, играющий — янтарём; Space — по очереди)
    local rx, rw
    if opts.marked ~= false and w >= L.cw * 90 then rw = math.floor(ww * 0.3); rx = x0 + ww - rw; ww = ww - rw - L.pad end
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
    if rx then
      U.set(U.BG); gfx.rect(rx, wy, rw, wh, 1)
      U.set(U.LINE); gfx.rect(rx, wy, rw, wh, 0)
      local rc = {}
      for _, o in ipairs(B.sel_order) do if o.full then rc[#rc + 1] = o.full end end
      B.mk_list = rc
      local nr = math.max(1, math.floor((wh - 2) / L.rh))
      if #rc == 0 then U.text(rx + L.pad, wy + 1, ctx.fit('marked: none - m marks files, Space plays them in a row', rw - 2 * L.pad), U.DIM) end
      local first = 0
      if B.pl and B.pl.i > nr then first = B.pl.i - nr end
      for i = 1, math.min(nr, #rc - first) do
        local ry = wy + 1 + (i - 1) * L.rh
        local pth = rc[first + i]
        local hot = mx >= rx and mx < rx + rw and my >= ry and my < ry + L.rh
        local on = ppath == pth
        if hot then U.set(U.tint(U.AMBER, 0.2)); gfx.rect(rx + 1, ry, rw - 2, L.rh, 1) end
        U.text(rx + L.pad, ry, ctx.fit(pth:match('([^/]+)$') or pth, rw - 2 * L.pad), on and U.AMBER or (hot and U.TEXT or U.GREY))
        if hot then hover = 'rec' .. (first + i) end
      end
    end
    -- слайдер громкости: подпись | дорожка | dB
    local vol = ctx.preview_vol and ctx.preview_vol() or 1
    local db = vol > 1e-6 and 20 * math.log(vol, 10) or -60
    local frac = (math.max(-40, math.min(6, db)) + 40) / 46
    local lbl, vs = 'vol', db <= -40 and '-inf' or ('%+.1f'):format(db)
    -- play / keys — на строке плеера (5 окт): автопрослушивание и клавиатура
    -- с высотой выбранного файла
    local px0 = x0
    B.pv_cur = path   -- 27 окт: файл плеера (звучит / выбран) — для slixer / drumrs5k
    for _, b in ipairs({ { 'play', 'auto', B.auto }, { 'keys', 'keys', B.keys }, { 'cell', 'drum', B.drum }, { 'slixer', 'pvslx', false }, { 'drumrs5k', 'pvdrum', false } }) do px0 = btn(px0, sy, b[1], b[2], b[3]) end   -- 27 окт: + новый slixer, drumrs5k   -- 24 окт: подпись cell (файл — в выбранную ячейку / пэд)
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
  return h, hover
end
function B.draw(U, L, x, y, w, h)
  B.marked_tick()   -- 27 окт (8): отметки — на диск, пока не очищены / не сохранены
  if B.filter_due and R.time_precise and R.time_precise() >= B.filter_due then B.filter_due = nil; B.set_all(B.all) end
  B.pl_tick()   -- 27 окт: плейлист отмеченных — следующий файл по концу
  B.hear_tick()   -- 27 окт: прозвучавшее — в recent   -- 19 окт: поиск после паузы набора
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
    -- 9 окт: опция pm as a pane — pm своей панелью; иначе вкладка браузера (fx — отдельной панелью)
    for _, t in ipairs(B.pmpane and (B.mode == 'pm' and {} or { 'files', 'recent', 'db', 'proj', 'libs', 'presets' }) or B.panes and { 'files', 'recent', 'db', 'pm', 'proj', 'libs', 'presets' } or (B.fx_draw and { 'files', 'recent', 'db', 'pm', 'proj', 'libs', 'presets', 'fx' } or { 'files', 'recent', 'db', 'pm', 'proj', 'libs', 'presets' })) do   -- 27 окт: recent — прослушанные (> 0.5 с или 2+ раза)
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
    if B.pmpane and B.mode == 'pm' then               -- 9 окт: панель pm — без закладок папок браузера
    elseif bx + mw <= x + w then B.draw_marks(btn, x + w - mw - L.pad, y, U) else wrap_marks = true end
  end
  do   -- 27 окт (7): плеер — B.player_block (его же зовёт панель map)
    local hv
    h, hv = B.player_block(U, L, x, y, w, h, btn, { buttons = not (B.pmpane and B.mode == 'pm') })
    if hv then hover = hv end
  end
  y = y + L.rh + 2; h = h - L.rh - 2
  -- управляющая строка (2 окт): < > * [1..5] и полный путь, клик по папке — туда
  do
    local bx = x + L.pad + 2
    if B.mode == 'files' then
      bx = btn(bx, y, '<', 'back', false)
      bx = btn(bx, y, '>', 'fwd', false)
      bx = btn(bx, y, '*', 'mkdir', false)
      bx = btn(bx, y, 'find', 'find', B.filtering or B.filter ~= '')   -- 11 окт: поиск — на виду, справа от * (новая папка)
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
      -- 17 окт: поиск — своей строкой под кнопками (было в той же, после закладок — резался)
      y = y + L.rh + 2; h = h - L.rh - 2
      local scope = 'in folder'
      local hint2 = B.filter == '' and '   words  -drum without  >2s <0.5s length  ^start end$' or ''
      U.text(x + L.pad + 2, y + 1, ctx.fit('/' .. B.filter .. (B.filtering and '_' or '') .. ('  %s: %d'):format(scope, #B.entries) .. hint2, w - 2 * L.pad - 2), U.AMBER)
      y = y + L.rh + 2; h = h - L.rh - 2
    end
  end
  -- путь / база / фильтр (не files: прежняя строка «где я»)
  local where
  if B.mode == 'files' then local rel = B.path:sub(#B.root + 2); where = rel ~= '' and rel or '/'
  elseif B.mode == 'proj' then where = ('project: %d sources'):format(#B.all)
  elseif B.mode == 'recent' then where = ('recently played: %d  (m - mark, Space - the marked ones in a row)'):format(#B.all)   -- 27 окт
  elseif B.mode == 'pm' then where = B.pmproj and ('@' .. (B.pmproj.e.name or '') .. (B.pmdir and ('/' .. B.pmdir) or '')) or (B.pm_folders and ('projects: ' .. (B.pmfolder or '')) or ('jf_pm: %d projects'):format(#B.all))
  else where = B.db and ('db ' .. B.db.name) or 'databases' end
  if B.filter ~= '' or B.filtering then
    local scope = B.mode == 'files' and 'in folder' or (B.mode == 'db' and B.db and 'in db' or 'in list')
    where = where .. ' /' .. B.filter .. (B.filtering and '_' or '') .. ('  %s: %d'):format(scope, #B.entries)
  end
  if B.mode ~= 'files' then
    local tx0 = x + L.pad + 2
    if not (B.pmpane and B.mode == 'pm') and B.mode ~= 'map' then tx0 = btn(tx0, y, 'find', 'find', B.filtering or B.filter ~= '') end   -- 11 окт: find — первым в строке
    if B.mode == 'proj' then tx0 = btn(tx0, y, 'map', 'projmap', false) end   -- 27 окт: источники проекта картой (вкладка map, proj)
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
  -- 27 окт: колонки как в lf — широкий браузер (развёрнут) в files без поиска: родитель | папка | превью
  local cols = B.mode == 'files' and B.filter == '' and not B.filtering and w >= L.cw * 90
  local pv_x, pv_w
  if cols then
    local pw, cw0 = math.floor(w * 0.22), math.floor(w * 0.36)
    B.pcol = nil
    if B.path ~= '/' then
      local parent = B.path:match('(.*)/[^/]+$') or ''
      if parent == '' then parent = '/' end
      B.pcol = { path = parent, list = list_dir(parent) }
      local hv = draw_col(U, L, B.pcol.list, x + 1, y, pw - 3, h, B.path:match('([^/]+)$'), 'pcol', mx, my)
      if hv then hover = hv end
    end
    U.set(U.LINE); gfx.rect(x + pw - 1, y, 1, h, 1); gfx.rect(x + pw + cw0 - 1, y, 1, h, 1)
    pv_x, pv_w = x + pw + cw0 + 1, w - pw - cw0 - 3
    x, w = x + pw, cw0 - 1
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
    local curc = idx == B.cur and U.list_cursor(x + 1, ry, w - 2, L.rh, B.focus)   -- 10 окт: курсор как в lib
    local col = (idx == B.cur and B.focus) and curc or ((e.dir or e.db) and U.CYAN or ((e.pm or e.trk or e.rgn) and U.AMBER or U.TEXT))
    -- отмеченная (10 окт): янтарная подложка и полоска слева, имя янтарём
    local marked = B.sel[B.mkey(e)] ~= nil
    if marked then
      if idx ~= B.cur then U.set(U.tint(U.AMBER, 0.22)); gfx.rect(x + 1, ry, w - 2, L.rh, 1) end
      U.set(U.AMBER); gfx.rect(x + 1, ry, 2, L.rh, 1)
      if idx ~= B.cur or not B.focus then col = U.AMBER end
    end
    local glyph = e.db and '#' or (e.pm and '@' or ((e.kit or e.preset) and '*' or (e.trk and '=' or (e.rgn and '[' or (e.mark and '|' or ((e.dir or e.prdir) and '/' or ' '))))))
    local is_file = not (e.dir or e.db or e.pm or e.trk or e.rgn or e.mark)
    local tw = w - 2 * L.pad
    if B.wave and is_file then tw = math.floor(tw * 0.55) end
    U.text(x + L.pad, ry + 1, ctx.fit(glyph .. e.name, tw), col)
    -- мета проекта pm справа (темп, тональность, теги, статус) — если влезает
    if e.meta then
      local nw = U.measure(glyph .. e.name) + L.pad
      if nw + U.measure('000bpm') < tw then
        U.text(x + L.pad + nw, ry + 1, ctx.fit(e.meta, tw - nw), (idx == B.cur and B.focus) and U.TEXT or U.GREY)
      end
    end
    if B.wave and is_file and ctx.file_peaks then
      -- мини-волна файла справа от имени (нативные пики REAPER, кеш по пути)
      local wx, ww = x + L.pad + tw + L.pad, w - 2 * L.pad - tw - L.pad
      local pk = ww > 8 and ctx.file_peaks(B.full(e), ww)
      local cy, hh = ry + L.rh / 2, L.rh / 2 - 1
      U.set((idx == B.cur and B.focus) and U.AMBER or U.readable(U.mix(U.TEXT, U.CYAN, 0.4), U.BG, 4.0))
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
  -- 27 окт: третья колонка — что под курсором: папка — её содержимое (щелчок — туда), файл — крупная волна и сведения
  if cols then
    local e = B.entries[B.cur]
    B.ncol = nil
    -- 27 окт (3): карты в третьей колонке больше нет — у неё своя панель map (одно место на инструмент)
    if e and e.dir then
      local p = B.full(e)
      B.ncol = { path = p, list = list_dir(p) }
      local hv = draw_col(U, L, B.ncol.list, pv_x, y, pv_w, h, nil, 'ncol', mx, my)
      if hv then hover = hv end
    elseif e then
      local path = B.preview_path(e)
      local wx, ww = pv_x + L.pad, pv_w - 2 * L.pad
      local wh = math.max(2 * L.rh, math.min(h - 4 * L.rh, 12 * L.rh))
      U.text(wx, y + 1, ctx.fit(e.name or '', ww), U.TEXT)
      local wy = y + L.rh + 4
      U.set(U.BG); gfx.rect(wx, wy, ww, wh, 1)
      U.set(U.LINE); gfx.rect(wx, wy, ww, wh, 0)
      local pk = path and ww > 8 and ctx.file_peaks and ctx.file_peaks(path, ww)
      local cy, hh = wy + math.floor(wh / 2), math.floor(wh / 2) - 2
      U.set(U.readable(U.mix(U.TEXT, U.CYAN, 0.4), U.BG, 4.0))
      if pk and pk.n > 0 then
        for px = 0, ww - 1 do
          local i = math.floor(px / ww * pk.n) + 1
          local a, b = pk.min[i] or 0, pk.max[i] or 0
          if b - a < 0.02 then a, b = -0.01, 0.01 end
          gfx.line(wx + px, cy - b * hh, wx + px, cy - a * hh)
        end
      else gfx.line(wx, cy, wx + ww - 1, cy) end
      local len = path and file_len({ path = path })
      local ext = (e.name or ''):match('%.([%w]+)$')
      local info = (len and ('%.2f s'):format(len) or '') .. (ext and ('   ' .. ext:lower()) or '')
      U.text(wx, wy + wh + 4, ctx.fit(info, ww), U.GREY)
      U.text(wx, wy + wh + 4 + L.rh, ctx.fit('Enter - into the lib, Space - listen', ww), U.DIM)
    end
  end
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

pcall(B.hist_load)   -- 27 окт (8): history и marked с прошлого раза
return B
