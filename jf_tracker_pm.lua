-- jf_tracker_pm.lua — проект-менеджер jf_pm в трекере (6 окт, экспериментально).
--
-- Вкладка pm браузера как СЕТКА КАРТОЧЕК проектов с превью; опция big —
-- карточки на всё окно (:pm big, b). Данные — индекс jf_pm
-- (Scripts/jf_pm/jf_pm_index.json, ~5 МБ, ~2200 проектов): читается
-- декодером-корутиной по 12 мс на кадр (целиком — полсекунды стопа), живёт в
-- памяти; правки тегов / статуса / pin пишутся отложенно (1.5 с) безопасно:
-- index.tmp → .bak → index, с проверкой, не перезаписал ли индекс сам jf_pm.
-- Превью карточки (приоритет): картинка проекта (thumb_user / <имя>.png) →
-- метка чужой DAW → волна превью-аудио → навигатор (мини-аранжировка: items
-- по трекам + полоса регионов, цвета по хэшу пути — та же картинка, что в
-- jf_pm и его HTML-галерее). Превью запекаются в картинки gfx 0..87 (кольцо,
-- единственный свободный диапазон) и дальше только блитятся.
-- Без зависимости от jf_pm_core.lua: он не грузится под Lua 5.5 (тесты),
-- JSON и константы — свои копии. Логика (декодер, сортировка, раскладка,
-- приоритет превью, курсор) — без reaper / gfx: tests/test_pm.lua.
--
-- Модуль браузера: фокус 'browser', клавиши через B.key → PM.key, клики
-- через hover.browser (индекс карточки), f-хинты kind 'browser'.

local PM = { ready = false, loading = nil, idx = nil, ops = {}, dirty = nil, gen = 0, frame = 0 }
local U, ctx
local R = reaper

PM.INDEX = nil                               -- путь индекса (init)
PM.BUDGET = 0.012                            -- с на кадр для декодера
PM.YIELD_EVERY = 4000                        -- значений JSON между yield
PM.FLUSH_AFTER = 1.5                         -- с: отложенная запись
PM.BAKE_MS, PM.BAKE_MAX = 3, 8               -- бюджет запекания за кадр
PM.SLOT0, PM.NSLOTS, PM.SCRATCH = 0, 88, 88  -- картинки gfx: 0..87 кольцо, 88 — loadimg

-- ── константы jf_pm (копии jf_pm_core.lua:17-70) ──────────────────────────
PM.STATUSES = { 'зерно', 'джем', 'ритм', 'луп', 'аранжировка', 'микс', 'мастер', 'издано', 'на расслоение', 'семплпак', 'покой' }
PM.PIPELINE = { ['зерно'] = 1, ['джем'] = 2, ['ритм'] = 3, ['луп'] = 4, ['аранжировка'] = 5, ['микс'] = 6, ['мастер'] = 7, ['издано'] = 8 }
PM.STATUS_COLORS = {
  ['зерно'] = 0x8A8A8AFF, ['джем'] = 0xB58AD9FF, ['ритм'] = 0xD98A8AFF, ['луп'] = 0x7BB8D9FF, ['аранжировка'] = 0xD9B96CFF,
  ['микс'] = 0xE8E8E8FF, ['мастер'] = 0xC98AD9FF, ['издано'] = 0x7FD98AFF, ['на расслоение'] = 0xD98ABDFF, ['семплпак'] = 0x7BD9D0FF, ['покой'] = 0x5F5F5FFF,
}
PM.STATUS_EN = {
  ['зерно'] = 'seed', ['джем'] = 'jam', ['ритм'] = 'beat', ['луп'] = 'loop', ['аранжировка'] = 'arrangement', ['микс'] = 'mix',
  ['мастер'] = 'master', ['издано'] = 'out', ['на расслоение'] = 'to harvest', ['семплпак'] = 'samplepack', ['покой'] = 'rest',
}
PM.STATUS_ALIASES = {
  ['набросок'] = 'зерно', ['идея'] = 'зерно', ['в работе'] = 'аранжировка', ['доделать'] = 'аранжировка', ['к миксу'] = 'микс',
  ['отмиксить'] = 'микс', ['мастеринг'] = 'мастер', ['готово'] = 'издано', ['заморожено'] = 'покой', ['архив'] = 'покой',
}
PM.DAW_TYPES = {
  als = { daw = 'ableton', label = 'Ab', color = 0xB8D97BFF }, flp = { daw = 'flstudio', label = 'FL', color = 0xD9A87BFF },
  xrns = { daw = 'renoise', label = 'Rn', color = 0x7BD9D0FF }, ptx = { daw = 'protools', label = 'PT', color = 0x9A7BD9FF },
  ptf = { daw = 'protools', label = 'PT', color = 0x9A7BD9FF }, logicx = { daw = 'logic', label = 'Lg', color = 0x7FD98AFF, is_dir = true },
  bwproject = { daw = 'bitwig', label = 'Bw', color = 0xD98A8AFF }, npr = { daw = 'nuendo', label = 'Nu', color = 0x8AA0D9FF },
  pd = { daw = 'puredata', label = 'Pd', color = 0xE8E8E8FF }, maxpat = { daw = 'max', label = 'Mx', color = 0x8A8F93FF },
}
PM.AUDIO_EXT = { wav = true, aif = true, aiff = true, flac = true, mp3 = true, ogg = true, m4a = true }
PM.SORTS = { 'date', 'name', 'bpm', 'status' }
PM.DAWS = { 'all', 'rpp', 'other' }

function PM.rgb(u32) return { ((u32 >> 24) & 255) / 255, ((u32 >> 16) & 255) / 255, ((u32 >> 8) & 255) / 255 } end

function PM.init(u, c)
  U, ctx = u, c
  local res = R and R.GetResourcePath and R.GetResourcePath() or ((os.getenv('HOME') or '') .. '/Library/Application Support/REAPER')
  PM.INDEX = PM.INDEX or (res .. '/Scripts/jf_pm/jf_pm_index.json')
end
-- файловые операции — подменяемые (тесты)
PM.fs = {
  read = function(path) local f = io.open(path, 'rb'); if not f then return nil end; local s = f:read('a'); f:close(); return s end,
  write = function(path, s) local f = io.open(path, 'wb'); if not f then return false end; f:write(s); f:close(); return true end,
  rename = function(a, b) return os.rename(a, b) end,
  exists = function(path) if R and R.file_exists then return R.file_exists(path) end local f = io.open(path, 'rb'); if f then f:close(); return true end return false end,
  tail = function(path, n) local f = io.open(path, 'rb'); if not f then return nil end; local sz = f:seek('end'); f:seek('set', math.max(0, sz - n)); local s = f:read('a'); f:close(); return s end,
  time = function() return R and R.time_precise and R.time_precise() or os.clock() end,
  now = function() return os.time() end,
}

-- ── JSON (копия jf_pm_core.lua:74-211; декодер — корутина) ───────────────
local function is_array(t)
  local n = 0
  for k in pairs(t) do if type(k) ~= 'number' then return false end; n = n + 1 end
  for i = 1, n do if t[i] == nil then return false end end
  return n > 0
end
local ESC = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t', ['\b'] = '\\b', ['\f'] = '\\f' }
local function esc_str(s) return (s:gsub('[%z\1-\31"\\]', function(c) return ESC[c] or string.format('\\u%04x', c:byte()) end)) end
-- тот же формат, что у jf_pm (отсортированные ключи, отступы): индекс остаётся
-- читаемым и для него; ~0.2 с на 5 МБ — редкое событие (flush)
function PM.encode(v, indent)
  indent = indent or ''
  local t = type(v)
  if v == nil then return 'null' end
  if t == 'boolean' then return tostring(v) end
  if t == 'number' then
    if v % 1 == 0 and math.abs(v) < 2 ^ 53 then return string.format('%d', v) end
    return string.format('%.10g', v)
  end
  if t == 'string' then return '"' .. esc_str(v) .. '"' end
  if t == 'table' then
    local ind2 = indent .. '  '
    if is_array(v) then
      local out = {}
      for i = 1, #v do out[i] = ind2 .. PM.encode(v[i], ind2) end
      return '[\n' .. table.concat(out, ',\n') .. '\n' .. indent .. ']'
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    if #keys == 0 then return '{}' end
    local out = {}
    for i, k in ipairs(keys) do out[i] = ind2 .. '"' .. esc_str(k) .. '": ' .. PM.encode(v[k], ind2) end
    return '{\n' .. table.concat(out, ',\n') .. '\n' .. indent .. '}'
  end
  error('json: unsupported type ' .. t)
end

-- декодер: та же грамматика, что jf_pm_core.json_decode; каждые yield_every
-- значений — coroutine.yield(доля). Вне корутины yield не зовётся
function PM.decode(s, yield_every)
  local pos, count = 1, 0
  local in_co = coroutine.isyieldable and coroutine.isyieldable() or false
  local function skip_ws() pos = s:find('[^ \t\r\n]', pos) or #s + 1 end
  local parse_value
  local function parse_string()
    pos = pos + 1
    local out = {}
    while true do
      local c = s:sub(pos, pos)
      if c == '' then error('json: unterminated string') end
      if c == '"' then pos = pos + 1; break end
      if c == '\\' then
        local e = s:sub(pos + 1, pos + 1)
        if e == 'u' then
          local cp = tonumber(s:sub(pos + 2, pos + 5), 16) or 0
          out[#out + 1] = utf8 and utf8.char(cp) or string.char(cp % 256)
          pos = pos + 6
        else
          local map = { n = '\n', r = '\r', t = '\t', b = '\b', f = '\f' }
          out[#out + 1] = map[e] or e
          pos = pos + 2
        end
      else
        -- кусок без спецсимволов разом (быстрее посимвольного)
        local e = s:find('["\\]', pos) or (#s + 1)
        out[#out + 1] = s:sub(pos, e - 1)
        pos = e
      end
    end
    return table.concat(out)
  end
  parse_value = function()
    count = count + 1
    if in_co and yield_every and count % yield_every == 0 then coroutine.yield(pos / #s) end
    skip_ws()
    local c = s:sub(pos, pos)
    if c == '"' then return parse_string() end
    if c == '{' then
      pos = pos + 1
      local obj = {}
      skip_ws()
      if s:sub(pos, pos) == '}' then pos = pos + 1; return obj end
      while true do
        skip_ws()
        local k = parse_string()
        skip_ws()
        if s:sub(pos, pos) ~= ':' then error('json: expected :') end
        pos = pos + 1
        obj[k] = parse_value()
        skip_ws()
        local d = s:sub(pos, pos)
        pos = pos + 1
        if d == '}' then return obj end
        if d ~= ',' then error('json: expected , or }') end
      end
    end
    if c == '[' then
      pos = pos + 1
      local arr = {}
      skip_ws()
      if s:sub(pos, pos) == ']' then pos = pos + 1; return arr end
      while true do
        arr[#arr + 1] = parse_value()
        skip_ws()
        local d = s:sub(pos, pos)
        pos = pos + 1
        if d == ']' then return arr end
        if d ~= ',' then error('json: expected , or ]') end
      end
    end
    local lit = s:match('^[%w%.%+%-]+', pos)
    if lit == 'true' then pos = pos + 4; return true end
    if lit == 'false' then pos = pos + 5; return false end
    if lit == 'null' then pos = pos + 4; return nil end
    local num = tonumber(lit)
    if num then pos = pos + #lit; return num end
    error('json: unexpected token at ' .. pos)
  end
  return parse_value()
end

-- ── загрузка по кускам ────────────────────────────────────────────────────
function PM.load_start()
  local s = PM.fs.read(PM.INDEX)
  if not s or s == '' then PM.loading = nil; PM.ready = true; PM.idx = { version = 1, projects = {} }; PM.empty = true; if PM.on_ready then PM.on_ready() end; return end
  PM.empty = nil
  PM.loading = { co = coroutine.create(function() return PM.decode(s, PM.YIELD_EVERY) end), frac = 0, size = #s }
end
function PM.load_step(budget)
  local ld = PM.loading
  if not ld then return end
  local t0 = PM.fs.time()
  while true do
    local ok, r = coroutine.resume(ld.co)
    if not ok then PM.loading = nil; PM.error = tostring(r); PM.ready = true; PM.idx = { version = 1, projects = {} }; if PM.on_ready then PM.on_ready() end; return end
    if coroutine.status(ld.co) == 'dead' then
      PM.loading = nil
      if type(r) ~= 'table' or type(r.projects) ~= 'table' then PM.error = 'jf_pm: bad index'; r = { version = 1, projects = {} } end
      PM.idx = r; PM.ready = true
      -- правки, сделанные пока индекс перечитывался — заново на свежий
      for _, op in ipairs(PM.ops) do local c = r.projects[op[1]]; if c then op[2](c) end end
      if PM.on_ready then PM.on_ready() end
      return
    end
    ld.frac = tonumber(r) or ld.frac
    if PM.fs.time() - t0 > (budget or PM.BUDGET) then return end
  end
end
function PM.ensure()
  if PM.ready or PM.loading then return end
  PM.load_start()
end
function PM.reload()
  PM.ready, PM.idx = false, nil
  PM.load_start()
end
-- «updated» из хвоста файла (ключи отсортированы, updated — в конце): чужая
-- запись индекса (сам jf_pm) видна без полного чтения
function PM.file_updated()
  local t = PM.fs.tail(PM.INDEX, 200)
  return t and tonumber(t:match('"updated"%s*:%s*(%d+)')) or nil
end

-- ── правки и отложенная запись ────────────────────────────────────────────
function PM.card(path) return PM.idx and PM.idx.projects and PM.idx.projects[path] or nil end
-- fn(card) правит карточку; true — есть такая. Запись — позже (flush)
function PM.edit(path, fn)
  local c = PM.card(path)
  if not c then return false end
  fn(c)
  PM.ops[#PM.ops + 1] = { path, fn }
  PM.dirty = PM.dirty or PM.fs.time()
  if PM.on_edit then PM.on_edit(path, c) end
  return true
end
function PM.flush(force)
  if not PM.dirty or not PM.idx then return false end
  if not force and PM.fs.time() - PM.dirty < PM.FLUSH_AFTER then return false end
  if PM.loading then return false end
  local fu = PM.file_updated()
  if fu and PM.idx.updated and fu ~= PM.idx.updated then
    -- индекс переписал jf_pm: перечитать и переприменить правки (load_step)
    PM.reload(); return false
  end
  PM.idx.updated = PM.fs.now()
  local okj, s = pcall(PM.encode, PM.idx)
  if not okj then PM.error = 'jf_pm: encode failed'; return false end
  local tmp, bak = PM.INDEX .. '.tmp', PM.INDEX .. '.bak'
  if not PM.fs.write(tmp, s) then PM.error = 'jf_pm: cannot write ' .. tmp; return false end
  PM.fs.rename(bak, bak .. '.old'); PM.fs.rename(PM.INDEX, bak)
  if not PM.fs.rename(tmp, PM.INDEX) then PM.fs.rename(bak, PM.INDEX); PM.error = 'jf_pm: rename failed'; return false end
  PM.ops, PM.dirty = {}, nil
  return true
end

-- ── карточка → запись браузера ────────────────────────────────────────────
function PM.name_bpm(name)
  if not name then return nil end
  for num in name:gmatch('%[(%d+%.?%d*)%]') do local b = tonumber(num); if b and b >= 40 and b <= 300 then return b end end
  local b = tonumber(name:match('%f[%d](%d+%.?%d*)%s*[bB][pP][mM]'))
  if b and b >= 40 and b <= 300 then return b end
  return nil
end
function PM.card_status(c)
  local s = c.status_over or (c.ext or {}).STATUS or ''
  return PM.STATUS_ALIASES[s] or s
end
function PM.entry(path, c)
  local nm = c.name or (path:match('[^/]+$') or path)
  local st = PM.card_status(c)
  local bpm = PM.name_bpm(nm) or c.tempo
  local meta = {}
  if bpm then meta[#meta + 1] = math.floor(bpm + 0.5) .. 'bpm' end
  local keystr = type(c.keys) == 'table' and #c.keys > 0 and table.concat(c.keys, ' ', 1, math.min(#c.keys, 3)) or nil
  if keystr then meta[#meta + 1] = keystr end
  local tags = {}
  if type(c.fs_tags) == 'table' then for t in pairs(c.fs_tags) do tags[#tags + 1] = t end end
  if type(c.tags_extra) == 'table' then for _, t in ipairs(c.tags_extra) do tags[#tags + 1] = t end
  elseif type(c.tags_extra) == 'string' and c.tags_extra ~= '' then tags[#tags + 1] = c.tags_extra end
  for raw in ((c.ext or {}).TAGS or ''):gmatch('[^,]+') do local t = raw:match('^%s*(.-)%s*$'); if t ~= '' then tags[#tags + 1] = t end end   -- не присваивать переменной цикла (Lua 5.5)
  table.sort(tags)
  local tagstr = #tags > 0 and ('#' .. table.concat(tags, ' #')) or nil
  if tagstr then meta[#meta + 1] = tagstr end
  if st ~= '' then meta[#meta + 1] = '[' .. (PM.STATUS_EN[st] or st) .. ']' end
  local ms = table.concat(meta, ' ')
  local daw = c.daw
  return {
    name = nm, path = path, pm = true, dir = false, card = c,
    meta = ms ~= '' and ms or nil,
    label = nm .. ' ' .. ms .. ' ' .. (daw or 'reaper rpp') .. (st ~= '' and (' [' .. st .. ']') or ''),
    mtime = tonumber(c.mtime) or 0, len = tonumber(c.duration), render = (c.render_file and c.render_file ~= '') and c.render_file or nil,
    tracks = c.track_names, daw = daw, daw_ext = c.daw_ext, pinned = c.pinned and true or false,
    status = st, st_en = PM.STATUS_EN[st] or st, bpm = bpm, keystr = keystr, tagstr = tagstr,
  }
end
-- opts.daw: 'all' | 'rpp' | 'other'
function PM.entries(idx, opts)
  local out, mode = {}, (opts and opts.daw) or 'all'
  for path, c in pairs(idx and idx.projects or {}) do
    local ext = (path:match('%.(%w+)$') or ''):lower()
    local base = path:match('[^/]+$') or ''
    local isrpp = ext == 'rpp'
    local keep = not (isrpp and (base:sub(1, 1) == '.' or base:find('TemporaryUnsaved', 1, true)))
    if keep and mode == 'rpp' then keep = isrpp elseif keep and mode == 'other' then keep = not isrpp end
    if keep and not c.gone then out[#out + 1] = PM.entry(path, c) end
  end
  return out
end
function PM.sort(list, mode)
  mode = mode or 'date'
  local function key(e)
    if mode == 'name' then return (e.name or ''):lower() end
    if mode == 'bpm' then return e.bpm or 1e9 end
    if mode == 'status' then return (e.status ~= '' and (PM.PIPELINE[e.status] or 50) or 99) end
    return -(e.mtime or 0)
  end
  table.sort(list, function(a, b)
    if a.pinned ~= b.pinned then return a.pinned end
    local ka, kb = key(a), key(b)
    if ka ~= kb then return ka < kb end
    if mode ~= 'date' and (a.mtime or 0) ~= (b.mtime or 0) then return (a.mtime or 0) > (b.mtime or 0) end
    return (a.name or '') < (b.name or '')
  end)
  return list
end

-- ── сетка: раскладка и курсор (чисто) ─────────────────────────────────────
-- cols по ширине: карточка не уже 9 символов; card_w / thumb / card_h
function PM.grid(w, cw, pad, rh)
  local cols = math.max(1, math.floor((w - pad) / (9 * cw + pad)))
  local card_w = math.floor((w - (cols + 1) * pad) / cols)
  local thumb = math.max(4, card_w - 2 * pad)
  local rows_txt = card_w >= 14 * cw and 3 or 2
  return { cols = cols, card_w = card_w, thumb = thumb, rows_txt = rows_txt, card_h = thumb + rows_txt * rh + 3 * pad }
end
-- курсор: dir 'h' 'j' 'k' 'l', n — число карточек
function PM.move(cur, n, cols, dir)
  if n < 1 then return 1 end
  local d = (dir == 'h' and -1) or (dir == 'l' and 1) or (dir == 'j' and cols) or (dir == 'k' and -cols) or 0
  local nxt = cur + d
  if (dir == 'j' or dir == 'k') and (nxt < 1 or nxt > n) then return cur end
  return math.max(1, math.min(n, nxt))
end

-- ── превью: вид, аудио, запекание ─────────────────────────────────────────
local exists_cache, audio_cache, dircount = {}, {}, {}
local function file_ok(p)
  if exists_cache[p] == nil then exists_cache[p] = PM.fs.exists(p) and true or false end
  return exists_cache[p]
end
-- 'image' | 'daw' | 'wave' | 'nav'
function PM.thumb_kind(c, audio)
  local img = c.thumb_user or c.thumb_file
  if img and img ~= '' and file_ok(img) then return 'image', img end
  if c.daw then return 'daw' end
  if audio then return 'wave', audio end
  return 'nav'
end
-- превью-аудио проекта (порт find_preview_audio jf_pm_browser.lua:1992, без
-- фаззи-обхода папки); кэш по пути, false — нет
function PM.find_audio(c)
  local hit = audio_cache[c.path]
  if hit ~= nil then return hit or nil end
  local dir = c.path:match('^(.*)[/\\]') or '.'
  local name = c.name or (c.path:match('[^/]+$') or '')
  local cands = {}
  if c.preview_found then cands[#cands + 1] = c.preview_found end
  cands[#cands + 1] = dir .. '/' .. name .. '_preview.wav'
  if c.daw then for _, e in ipairs({ 'wav', 'mp3', 'aiff', 'aif', 'flac', 'm4a', 'ogg' }) do cands[#cands + 1] = dir .. '/' .. name .. '.' .. e end end
  local n = dircount[dir]
  if not n then
    n = 0
    for p in pairs(PM.idx and PM.idx.projects or {}) do if (p:match('^(.*)[/\\]') or '.') == dir then n = n + 1 end end
    dircount[dir] = n
  end
  if n <= 1 then cands[#cands + 1] = dir .. '/jf_preview.wav' end
  cands[#cands + 1] = c.path .. '-PROX.wav'
  local rf = c.render_file or ''
  if rf ~= '' then
    if not rf:match('^/') then rf = dir .. '/' .. rf end
    local ext = rf:lower():match('%.(%w+)$')
    if ext and PM.AUDIO_EXT[ext] then cands[#cands + 1] = rf end
  end
  for _, p in ipairs(cands) do if file_ok(p) then audio_cache[c.path] = p; return p end end
  audio_cache[c.path] = false
  return nil
end

function PM.fnv1a(str)
  local h = 2166136261
  for i = 1, #str do h = ((h ~ str:byte(i)) * 16777619) & 0xFFFFFFFF end
  return h
end
function PM.hsv(h, s, v)
  h = (h % 360) / 60
  local i = math.floor(h); local f = h - i
  local p, q, t = v * (1 - s), v * (1 - s * f), v * (1 - s * (1 - f))
  if i == 0 then return { v, t, p } elseif i == 1 then return { q, v, p } elseif i == 2 then return { p, v, t }
  elseif i == 3 then return { p, q, v } elseif i == 4 then return { t, p, v } end
  return { v, p, q }
end
-- навигатор: прямоугольники items по трекам + полоса регионов (порт
-- jf_pm_browser.lua:2984-3005); rect(x, y, w, h, rgb) — чтобы тестировать без gfx
function PM.paint_nav(c, size, rect)
  local h = PM.fnv1a(c.path or '')
  local dur = tonumber(c.duration) or 0
  local items = c.items or {}
  if #items == 0 or dur <= 0 then
    -- пустой проект: тусклая заливка хэш-цветом
    rect(0, 0, size, size, PM.hsv(h % 360, 0.25, 0.25)); return 0
  end
  local tracks = math.max(tonumber(c.track_count) or 1, 1)
  local row = size / tracks
  local n = 0
  for _, it in ipairs(items) do
    local x0 = (it.p or 0) / dur * size
    local x1 = math.min(x0 + (it.l or 0) / dur * size, size)
    if x1 - x0 < 1 then x1 = x0 + 1 end
    local y0 = ((it.t or 1) - 1) * row
    rect(math.floor(x0), math.floor(y0 + 0.5), math.max(1, math.floor(x1 - x0)), math.max(1, math.floor(row - 1)), PM.hsv((h + (it.t or 1) * 53) % 360, 0.5, 0.85))
    n = n + 1
  end
  for _, r in ipairs(c.regions or {}) do
    local x0 = math.max((r.pos or 0) / dur, 0) * size
    local x1 = math.min((r.fin or 0) / dur, 1) * size
    if x1 - x0 < 1 then x1 = x0 + 1 end
    rect(math.floor(x0), size - 4, math.max(1, math.floor(x1 - x0)), 4, PM.hsv(PM.fnv1a((r.name and r.name ~= '') and r.name or '?') % 360, 0.6, 0.9))
    n = n + 1
  end
  return n
end

-- кольцо картинок: key → слот; LRU по кадру последнего использования
local slots, slot_of = {}, {}
function PM.slot(key)
  local s = slot_of[key]
  if s then s.used = PM.frame; return s.id, true end
  local best
  for i = 0, PM.NSLOTS - 1 do
    local id = PM.SLOT0 + i
    local sl = slots[id]
    if not sl then best = { id = id }; break end
    if not best or (sl.used or 0) < (best.used or 0) then best = sl end
  end
  if best.key then slot_of[best.key] = nil end
  best.key, best.used = key, PM.frame
  slots[best.id] = best; slot_of[key] = best
  return best.id, false
end
function PM.invalidate() slot_of = {}; slots = {}; PM.gen = PM.gen + 1; exists_cache = {} end

-- запечь превью в слот; возвращает false, если пока нельзя (волна строится)
function PM.bake(id, kind, c, arg, size)
  local dest = gfx.dest
  gfx.setimgdim(id, -1, -1); gfx.setimgdim(id, size, size)
  gfx.dest = id
  local done = true
  U.set(U.PANEL); gfx.rect(0, 0, size, size, 1)
  if kind == 'image' then
    local ok = gfx.loadimg(PM.SCRATCH, arg)
    local iw, ih = 0, 0
    if ok and ok >= 0 then iw, ih = gfx.getimgdim(PM.SCRATCH) end
    if iw > 0 and ih > 0 then
      local sc = math.max(size / iw, size / ih)                     -- cover
      local sw, sh = size / sc, size / sc
      gfx.blit(PM.SCRATCH, 1, 0, (iw - sw) / 2, (ih - sh) / 2, sw, sh, 0, 0, size, size)
    else kind = c.daw and 'daw' or 'nav' end
  end
  if kind == 'daw' then
    local dt = PM.DAW_TYPES[c.daw_ext or ''] or {}
    local col = dt.color and PM.rgb(dt.color) or U.GREY
    U.set(U.tint(col, 0.35)); gfx.rect(1, 1, size - 2, size - 2, 1)
    local lbl = dt.label or (c.daw or '?'):sub(1, 2)
    local tw, th = gfx.measurestr(lbl)
    U.text(math.floor((size - tw) / 2), math.floor((size - th) / 2), lbl, col)
  elseif kind == 'wave' then
    local pk = ctx.file_peaks and ctx.file_peaks(arg, size)
    if pk and pk.n > 0 then
      local cy, hh = math.floor(size / 2), math.floor(size / 2) - 1
      U.set(U.CYAN)
      for px = 0, size - 1 do
        local i = math.floor(px / size * pk.n) + 1
        local a, b = pk.min[i] or 0, pk.max[i] or 0
        if b - a < 0.03 then a, b = -0.015, 0.015 end
        gfx.line(px, cy - b * hh, px, cy - a * hh)
      end
    else
      PM.paint_nav(c, size, function(x, y, w, h, rgb) U.set(rgb); gfx.rect(x, y, w, h, 1) end)
      done = false                                                  -- пики строятся: перепечь позже
    end
  elseif kind == 'nav' then
    PM.paint_nav(c, size, function(x, y, w, h, rgb) U.set(rgb); gfx.rect(x, y, w, h, 1) end)
  end
  if c.daw then local dt = PM.DAW_TYPES[c.daw_ext or ''] or {}; U.set(dt.color and PM.rgb(dt.color) or U.GREY); gfx.rect(0, 0, size, size, 0) end
  gfx.dest = dest
  return done
end

-- очередь запекания: заполняет отрисовка, сливает tick / конец кадра
local queue, queued = {}, {}
local function enqueue(e, size)
  local k = e.path .. '|' .. size
  if queued[k] then return end
  queued[k] = true; queue[#queue + 1] = { e = e, size = size }
end
function PM.bake_pending()
  if #queue == 0 then return end
  local t0, n, loads = PM.fs.time(), 0, 0
  while #queue > 0 and n < PM.BAKE_MAX and (PM.fs.time() - t0) * 1000 < PM.BAKE_MS do
    local q = table.remove(queue, 1)
    queued[q.e.path .. '|' .. q.size] = nil
    local c = q.e.card
    local audio = PM.find_audio(c)
    local kind, arg = PM.thumb_kind(c, audio)
    if kind == 'image' then loads = loads + 1; if loads > 1 then enqueue(q.e, q.size); break end end
    local key = q.e.path .. '|' .. q.size .. '|' .. kind .. '|' .. PM.gen
    local id, have = PM.slot(key)
    if not have or not slots[id].done then
      slots[id].done = PM.bake(id, kind, c, arg, q.size)
      slots[id].kind = kind
    end
    n = n + 1
  end
end
-- слот превью для карточки сейчас (nil — ещё не запечено, поставлено в очередь)
function PM.thumb(e, size)
  local c = e.card
  local audio = audio_cache[c.path]
  local kind = PM.thumb_kind(c, audio or nil)
  local key = e.path .. '|' .. size .. '|' .. kind .. '|' .. PM.gen
  local s = slot_of[key]
  if s then s.used = PM.frame; if not s.done or audio == nil then enqueue(e, size) end; return s.id end
  enqueue(e, size)
  return nil
end

function PM.tick()
  PM.frame = PM.frame + 1
  if PM.loading then PM.load_step() end
  if PM.dirty then PM.flush(false) end
  PM.bake_pending()
end

-- ── отрисовка сетки ───────────────────────────────────────────────────────
local function daw_col(e) local dt = PM.DAW_TYPES[e.daw_ext or ''] or {}; return dt.color and PM.rgb(dt.color) or U.GREY end
-- возвращает hover (индекс карточки) и число колонок
function PM.draw_grid(L, x, y, w, h, entries, cur, focus, scroll_ref)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local G = PM.grid(w, L.cw, L.pad, L.rh)
  local cols, cw, ch = G.cols, G.card_w, G.card_h
  local nrows = math.ceil(#entries / cols)
  local nvis = math.max(1, math.floor(h / ch))
  local currow = math.floor((cur - 1) / cols)
  -- за курсором — только когда он сдвинулся (как список браузера)
  if PM.last_cur ~= cur then
    PM.last_cur = cur
    if currow < scroll_ref.v then scroll_ref.v = currow end
    if currow >= scroll_ref.v + nvis then scroll_ref.v = currow - nvis + 1 end
  end
  scroll_ref.v = math.max(0, math.min(scroll_ref.v, math.max(0, nrows - nvis)))
  local hover
  local shown = 0
  for r = 0, nvis - 1 do
    local row = scroll_ref.v + r
    for c = 0, cols - 1 do
      local i = row * cols + c + 1
      local e = entries[i]
      if not e then break end
      local cx = x + L.pad + c * (cw + L.pad)
      local cy = y + r * ch + L.pad
      local is_cur = i == cur
      local hot = mx >= cx and mx < cx + cw and my >= cy and my < cy + ch - L.pad
      if hot then hover = i end
      U.set(is_cur and (focus and U.tint(U.AMBER, 0.25) or U.PANEL) or (hot and U.tint(U.TEXT, 0.06) or U.BG)); gfx.rect(cx, cy, cw, ch - L.pad, 1)
      U.set(is_cur and (focus and U.AMBER or U.TEXT) or U.LINE); gfx.rect(cx, cy, cw, ch - L.pad, 0)
      -- превью
      local tx, ty, ts = cx + L.pad, cy + L.pad, G.thumb
      shown = shown + 1
      local id = shown <= 80 and PM.thumb(e, ts) or nil
      if id then gfx.blit(id, 1, 0, 0, 0, ts, ts, tx, ty, ts, ts)
      else
        -- заглушка: хэш-цвет и две буквы имени
        U.set(PM.hsv(PM.fnv1a(e.path) % 360, 0.3, 0.3)); gfx.rect(tx, ty, ts, ts, 1)
        local lbl = (e.name or '?'):sub(1, 2)
        local lw, lh = gfx.measurestr(lbl)
        if lw < ts then U.text(tx + math.floor((ts - lw) / 2), ty + math.floor((ts - lh) / 2), lbl, U.GREY) end
        if e.daw then U.set(daw_col(e)); gfx.rect(tx, ty, ts, ts, 0) end
      end
      -- строки текста
      local ly = ty + ts + 1
      local tw = cw - 2 * L.pad
      U.text(tx, ly, ctx.fit(e.name, tw), e.pinned and U.AMBER or (is_cur and focus and U.TEXT or U.TEXT))
      ly = ly + L.rh
      local left = (e.bpm and (math.floor(e.bpm + 0.5) .. 'bpm ') or '') .. (e.keystr or '')
      local date = e.mtime > 0 and os.date('%d.%m.%y', e.mtime) or ''
      if left ~= '' then U.text(tx, ly, ctx.fit(left, tw), U.CYAN) end
      if date ~= '' and U.measure(left) + U.measure(date) + L.pad <= tw then U.text(tx + tw - U.measure(date), ly, date, U.GREY) end
      if G.rows_txt >= 3 then
        ly = ly + L.rh
        local sx = tx
        if e.status ~= '' then
          local scol = PM.STATUS_COLORS[e.status] and PM.rgb(PM.STATUS_COLORS[e.status]) or U.GREY
          U.set(scol); gfx.rect(tx, ly + L.rh - 2, math.min(tw, U.measure(e.st_en) + 2), 2, 1)
          U.text(tx, ly, ctx.fit(e.st_en, tw), scol)
          sx = tx + U.measure(e.st_en) + L.pad
        end
        if e.tagstr and sx < tx + tw - L.cw * 3 then U.text(sx, ly, ctx.fit(e.tagstr, tx + tw - sx), U.GREY) end
      end
      if ctx.hint then ctx.hint('browser', cx, cy, cw, ch - L.pad, i) end
    end
  end
  if ctx.vbar then ctx.vbar('browser', x + w - 2, y, 2, nvis * ch, scroll_ref.v, nvis, nrows) end
  return hover, cols
end

-- ── big: карточки на всё окно (оверлей после draw.frame) ─────────────────
function PM.draw_big(L, B, x, y, w, h)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local hover = {}
  U.set(U.BG); gfx.rect(x, y, w, h, 1)
  local bx, by = x + L.pad, y + 2
  local function btn(label, what, on)
    local bw = U.measure(label) + 2 * L.pad
    local hot = mx >= bx and mx < bx + bw and my >= by and my < by + L.rh
    U.set(hot and U.tint(U.AMBER, 0.3) or (on and U.tint(U.AMBER, 0.15) or U.BG)); gfx.rect(bx, by, bw, L.rh, 1)
    U.set(on and U.AMBER or U.LINE); gfx.rect(bx, by, bw, L.rh, 0)
    U.text(bx + L.pad, by + 1, label, on and U.AMBER or (hot and U.TEXT or U.GREY))
    if hot then hover.browser = what end
    bx = bx + bw + L.pad
  end
  U.text(bx, by + 1, 'pm', U.AMBER); bx = bx + U.measure('pm') + 2 * L.pad
  btn('grid', 'pmgrid', B.grid); btn('list', 'pmlist', not B.grid)
  btn('sort ' .. (B.pm_sort or 'date'), 'pmsort', false); btn('daw ' .. (B.pm_daw or 'all'), 'pmdaw', false)
  btn('x', 'pmbig', true)
  local info = ('/%s%s  %d of %d'):format(B.filter or '', B.filtering and '_' or '', #B.entries, #B.all)
  U.text(bx + L.pad, by + 1, ctx.fit(info, x + w - bx - 2 * L.pad), B.filtering and U.AMBER or U.GREY)
  local gy = y + L.rh + 6
  if not PM.ready then
    U.text(x + L.pad, gy, PM.loading and ('jf_pm: loading %d %%'):format(math.floor((PM.loading.frac or 0) * 100)) or 'jf_pm: no index', U.GREY)
  elseif B.grid then
    local hv, cols = PM.draw_grid(L, x, gy, w, h - (gy - y), B.entries, B.cur, true, PM.scroll_big)
    B.grid_cols = cols
    if hv then hover.browser = hv end
  else
    -- список в big: строки как в сайдбаре, но во всю ширину
    local nvis = math.floor((h - (gy - y)) / L.rh)
    for i = 1, nvis do
      local idx = (B.scroll or 0) + i
      local e = B.entries[idx]; if not e then break end
      local ry = gy + (i - 1) * L.rh
      if idx == B.cur then U.set(U.TEXT); gfx.rect(x + 1, ry, w - 2, L.rh, 1) end
      U.text(x + L.pad, ry + 1, ctx.fit('@' .. e.name .. (e.meta and ('  ' .. e.meta) or ''), w - 2 * L.pad), idx == B.cur and U.BG or U.AMBER)
      if mx >= x and mx < x + w and my >= ry and my < ry + L.rh then hover.browser = idx end
    end
  end
  U.set(U.AMBER); gfx.rect(x, y, w, h, 0)
  return hover
end
PM.scroll_big = { v = 0 }

-- ── клавиши сетки (из B.key); true — съедена ─────────────────────────────
function PM.key(c, B, mods)
  local ch = c < 256 and string.char(c) or ''
  local e = B.entries[B.cur]
  local cols = B.grid_cols or 1
  if ch == 'h' or ch == 'j' or ch == 'k' or ch == 'l' or c == 1685026670 or c == 30064 or c == 1818584692 or c == 1919379572 then
    local d = ch ~= '' and ch or ({ [1685026670] = 'j', [30064] = 'k', [1818584692] = 'h', [1919379572] = 'l' })[c]
    B.cur = PM.move(B.cur, #B.entries, cols, d); return true
  end
  if ch == 'g' then B.cur = 1; return true end
  if ch == 'G' then B.cur = #B.entries; return true end
  if c == 13 and mods and mods.shift then if e then B.pm_open(e) end; return true end
  if c == 13 or ch == 'o' then if e and ctx.pm_open_project then ctx.pm_open_project(e.path, e.name) end; return true end
  if ch == ' ' then
    if not e then return true end
    local audio = PM.find_audio(e.card)
    if not audio then if ctx.msg then ctx.msg('pm: no preview audio for ' .. e.name) end; return true end
    if ctx.preview_pos and ctx.preview_stop then
      local _, _, ppath = ctx.preview_pos()
      if ppath == audio then ctx.preview_stop(); return true end
    end
    if ctx.preview_file then ctx.preview_file(audio) end
    return true
  end
  if ch == 'T' then if e and ctx.pm_tags then ctx.pm_tags(e) end; return true end
  if ch == 's' then if e and ctx.pm_status then ctx.pm_status(e) end; return true end
  if ch == 'p' then
    if e then
      local on
      PM.edit(e.path, function(cd) cd.pinned = not cd.pinned or nil; on = cd.pinned end)
      e.pinned = on and true or false
      if ctx.msg then ctx.msg((on and 'pinned ' or 'unpinned ') .. e.name) end
      B.pm = nil; B.set_all(B.read_pm())
      for i, x in ipairs(B.entries) do if x.path == e.path then B.cur = i; break end end
    end
    return true
  end
  if ch == 'a' then if e and ctx.pm_add then ctx.pm_add(e) end; return true end
  if ch == 'S' then B.click('pmsort'); return true end
  if ch == 'd' then B.click('pmdaw'); return true end
  if ch == 'b' then B.click('pmbig'); return true end
  if ch == 'r' then PM.reload(); B.pm = nil; B.set_all({}); if ctx.msg then ctx.msg('jf_pm: reloading the index') end; return true end
  return false
end

-- текст статуса для карточки (B.describe)
function PM.describe(e)
  local len = e.len and e.len > 0 and (' %d:%02d'):format(math.floor(e.len / 60), math.floor(e.len % 60)) or ''
  local what = e.daw and (e.daw .. ' project') or 'project'
  return ('%s %s%s - Enter: open in REAPER, Shift+Enter: inside, Space: listen, T tags, s status, p pin, a add as subproject, drag to a track'):format(what, e.name, len)
end

return PM
