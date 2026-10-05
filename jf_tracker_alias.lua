-- jf_tracker_alias.lua — алиасы паттернов (этап 6).
--
-- Паттерн = регион; ПОВТОР паттерна = ещё один регион с ТЕМ ЖЕ ИМЕНЕМ.
-- Содержимое повторов — копии items (как aliases в Renoise): после каждой
-- правки (хук edit.after, тот же undo-блок) регион под курсором становится
-- источником и переписывает все одноимённые регионы: их items внутри
-- диапазона удаляются, items источника копируются state chunk'ом со
-- смещением. Каждая копия получает P_EXT:jf_pattern = имя (метка для
-- сторонних скриптов; сам алгоритм идёт по имени региона).
--
-- Что считается «внутри региона»: item, чей старт попадает в [pos, end).
-- Хвост, торчащий за конец региона, копируется как есть.
-- Трек DEPOT не участвует.

local A = {}
local R = reaper
local model, edit

function A.init(m, e) model, edit = m, e end

local EPS = 1e-6

function A.region_at(regions, t)
  for _, rg in ipairs(regions) do
    if t >= rg.pos - EPS and t < rg.rgnend - EPS then return rg end
  end
  return nil
end

local function strip_guids(chunk)
  return (chunk:gsub('\n%s*GUID %b{}', ''):gsub('\n%s*IGUID %b{}', ''))
end

local function tracks()
  local out = {}
  for ti = 0, R.CountTracks(0) - 1 do
    local tr = R.GetTrack(0, ti)
    local _, name = R.GetTrackName(tr)
    if name ~= model.DEPOT then out[#out + 1] = tr end
  end
  return out
end

local function items_in(tr, t0, t1)
  local out = {}
  for i = 0, R.CountTrackMediaItems(tr) - 1 do
    local it = R.GetTrackMediaItem(tr, i)
    local pos = R.GetMediaItemInfo_Value(it, 'D_POSITION')
    if pos >= t0 - EPS and pos < t1 - EPS then out[#out + 1] = it end
  end
  return out
end

-- ── связь повторов, нативно (3 окт) ──────────────────────────────────────
-- Повтор паттерна (алиас) связан средствами REAPER, а не только синком
-- трекера: MIDI — общий пул (POOLEDEVTS: правка нот в одном меняет все),
-- каждый item и его копии — одна группа (I_GROUPID: перенос, обрезка, mute
-- вместе, «как в трекере», и в аранжировке). Clone / библиотека — без связи:
-- свой пул у каждой копии, группа снята.
local gid_next
local function new_group_id()
  if not gid_next then
    gid_next = 0
    for ti = 0, R.CountTracks(0) - 1 do
      local tr = R.GetTrack(0, ti)
      for i = 0, R.CountTrackMediaItems(tr) - 1 do
        local g = math.floor(R.GetMediaItemInfo_Value(R.GetTrackMediaItem(tr, i), 'I_GROUPID'))
        if g > gid_next then gid_next = g end
      end
    end
  end
  gid_next = gid_next + 1
  return gid_next
end
function A.reset_groups() gid_next = nil end
local function new_guid() return R.genGuid and R.genGuid('') or ('{%08X-0000-0000-0000-%012X}'):format(math.random(0, 0x7fffffff), math.random(0, 0x7fffffff)) end
-- свой пул каждой копии (clone): новый GUID в POOLEDEVTS; группа снята
local function unlink_chunk(chunk)
  chunk = chunk:gsub('POOLEDEVTS %b{}', function() return 'POOLEDEVTS ' .. new_guid() end)
  chunk = chunk:gsub('\n%s*GROUP %d+', '')
  return chunk
end
A.unlink_chunk = unlink_chunk
-- исходник повтора: MIDI — в пул (нет POOLEDEVTS — назначить), группа — своя
-- или новая. Возвращает чанк копии и id группы.
local function link_src(it)
  local gid = math.floor(R.GetMediaItemInfo_Value(it, 'I_GROUPID'))
  if gid <= 0 then gid = new_group_id(); R.SetMediaItemInfo_Value(it, 'I_GROUPID', gid) end
  local ok, chunk = R.GetItemStateChunk(it, '', false)
  if not ok then return nil, gid end
  local tk = R.GetActiveTake(it)
  if tk and R.TakeIsMIDI(tk) and not chunk:find('POOLEDEVTS') then
    local nc, n = chunk:gsub('(<SOURCE MIDI[^\n]*\n)', '%1POOLEDEVTS ' .. new_guid() .. '\n', 1)
    if n > 0 then R.SetItemStateChunk(it, nc, false); chunk = nc end
  end
  return strip_guids(chunk), gid
end

-- скопировать items трека из [src.pos, src.end) в dst (смещение dt);
-- link = true — связанный повтор (общий пул MIDI + общая группа), иначе
-- независимая копия
local function copy_span(tr, src, dst, tag, link)
  local dt = dst.pos - src.pos
  local chunks = {}
  for _, it in ipairs(items_in(tr, src.pos, src.rgnend)) do
    local chunk, gid
    if link then chunk, gid = link_src(it)
    else local ok, c = R.GetItemStateChunk(it, '', false); chunk = ok and unlink_chunk(strip_guids(c)) or nil end
    if chunk then
      chunks[#chunks + 1] = { chunk = chunk, gid = gid,
        pos = R.GetMediaItemInfo_Value(it, 'D_POSITION'),
        lane = R.GetMediaItemInfo_Value(it, 'I_FIXEDLANE') }
      if tag then R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_pattern', tag, true) end
    end
  end
  for _, c in ipairs(chunks) do
    local it = R.AddMediaItemToTrack(tr)
    R.SetItemStateChunk(it, c.chunk, false)
    R.SetMediaItemInfo_Value(it, 'D_POSITION', c.pos + dt)
    R.SetMediaItemInfo_Value(it, 'I_GROUPID', c.gid or 0)
    if R.GetMediaTrackInfo_Value(tr, 'I_FREEMODE') == 2 then R.SetMediaItemInfo_Value(it, 'I_FIXEDLANE', c.lane) end
    if tag then R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_pattern', tag, true) end
  end
  return #chunks
end

A.copy_span = copy_span          -- заполнение долей последней долей (:sig, 5 окт)

-- Переписать все одноимённые регионы содержимым src. Без своего undo-блока:
-- зовётся из edit.run (хук) или из A.append (свой блок).
-- Лайв (2 окт): хук зовётся после каждой правки, а пересоздание items
-- (Delete + AddMediaItem + SetItemStateChunk) — самое дорогое и раздувает
-- undo. Поэтому трек копируется, только если содержимое отличается: отпечаток
-- спана — чанки items без GUID / IID / SEL / POSITION плюс позиция от начала
-- региона. Чанки источника читаются один раз на трек.
local function norm_chunk(chunk)
  return (strip_guids(chunk):gsub('\n%s*POSITION [^\n]*', ''):gsub('\n%s*IID [^\n]*', ''):gsub('\n%s*SEL [^\n]*', ''))
end
local function span_print(tr, t0, t1)
  local parts = {}
  for _, it in ipairs(items_in(tr, t0, t1)) do
    local ok, chunk = R.GetItemStateChunk(it, '', false)
    local rel = R.GetMediaItemInfo_Value(it, 'D_POSITION') - t0
    parts[#parts + 1] = ('%.6f|'):format(rel) .. (ok and norm_chunk(chunk) or '?')
  end
  table.sort(parts)
  return table.concat(parts, '\0'), #parts
end
A._norm_chunk = norm_chunk
function A.sync(regions, src)
  if not src or src.name == '' then return 0 end
  local dsts = {}
  for _, dst in ipairs(regions) do
    if dst ~= src and dst.name == src.name and dst.idx ~= src.idx then dsts[#dsts + 1] = dst end
  end
  if #dsts == 0 then return 0 end
  local n = 0
  for _, tr in ipairs(tracks()) do
    local sp = span_print(tr, src.pos, src.rgnend)
    for _, dst in ipairs(dsts) do
      if span_print(tr, dst.pos, dst.rgnend) ~= sp then
        for _, it in ipairs(items_in(tr, dst.pos, dst.rgnend)) do R.DeleteTrackMediaItem(tr, it) end
        copy_span(tr, src, dst, src.name, true)
        n = n + 1
      end
    end
  end
  return n
end

-- ЖЁСТКИЕ ГРАНИЦЫ ПАТТЕРНОВ (решение пользователя 1 окт): item, вылезающий
-- за конец своего региона, обрезается по нему (D_LENGTH); item, входящий в
-- регион из-за его начала, режется на границе (SplitMediaItem) — так
-- содержимое каждого региона самодостаточно, и алиасы/слоты копируют ровно
-- то, что видно. Без своего undo-блока (зовётся из хука или из edit.run).
-- Возвращает число правок. Библиотека (=LIB) не трогается.
-- Лайв (2 окт): один проход по items трека, регион item — бинарным поиском
-- по отсортированным регионам (было регионы × треки × items × items).
function A.trim(regions)
  local regs = {}
  for _, rg in ipairs(regions) do if not rg.lib then regs[#regs + 1] = rg end end
  if #regs == 0 then return 0 end
  table.sort(regs, function(a, b) return a.pos < b.pos end)
  -- последний регион с началом ≤ t
  local function at_or_before(t)
    local lo, hi, k = 1, #regs, 0
    while lo <= hi do
      local m = (lo + hi) // 2
      if regs[m].pos <= t + EPS then k = m; lo = m + 1 else hi = m - 1 end
    end
    return k
  end
  local n = 0
  local function fix(it, pos, fin, depth)
    local k = at_or_before(pos)
    -- начинается внутри региона: вылезает за конец — укоротить
    -- (перекрытые регионы: самый ранний конец среди содержащих)
    local cut
    for j = k, math.max(1, k - 4), -1 do
      local rg = regs[j]
      if pos >= rg.pos - EPS and pos < rg.rgnend - EPS and (not cut or rg.rgnend < cut) then cut = rg.rgnend end
    end
    if cut then
      if fin > cut + EPS then R.SetMediaItemInfo_Value(it, 'D_LENGTH', cut - pos); n = n + 1 end
      return
    end
    -- вне регионов: входит в следующий из-за его начала — разрезать на границе
    local nx = regs[k + 1]
    if nx and fin > nx.pos + EPS and depth < 64 then
      local right = R.SplitMediaItem(it, nx.pos)
      if right then n = n + 1; fix(right, nx.pos, fin, depth + 1) end
    end
  end
  for _, tr in ipairs(tracks()) do
    local list = {}
    for i = 0, R.CountTrackMediaItems(tr) - 1 do
      local it = R.GetTrackMediaItem(tr, i)
      local pos = R.GetMediaItemInfo_Value(it, 'D_POSITION')
      list[#list + 1] = { it, pos, pos + R.GetMediaItemInfo_Value(it, 'D_LENGTH') }
    end
    for _, e in ipairs(list) do fix(e[1], e[2], e[3], 0) end
  end
  return n
end

-- ── блок ячеек матрицы (слоты r0..r1 × треки c0..c1) ─────────────────────
local function each_cell(regions, snap, r0, r1, c0, c1, fn)
  for ri = math.min(r0, r1), math.max(r0, r1) do
    local rg = regions[ri]
    if rg then
      for ci = math.min(c0, c1), math.max(c0, c1) do
        local col = snap.cols[ci]
        if col then fn(ri - math.min(r0, r1) + 1, ci - math.min(c0, c1) + 1, rg, col) end
      end
    end
  end
end

-- mute: все items блока в одно состояние (противоположное первому найденному)
function A.cells_mute(regions, snap, r0, r1, c0, c1)
  local flag
  each_cell(regions, snap, r0, r1, c0, c1, function(_, _, rg, col)
    for _, it in ipairs(items_in(col.track, rg.pos, rg.rgnend)) do
      if flag == nil then flag = R.GetMediaItemInfo_Value(it, 'B_MUTE') ~= 1 end
      R.SetMediaItemInfo_Value(it, 'B_MUTE', flag and 1 or 0)
    end
  end)
  return flag
end

function A.cells_delete(regions, snap, r0, r1, c0, c1)
  local n = 0
  each_cell(regions, snap, r0, r1, c0, c1, function(_, _, rg, col)
    for _, it in ipairs(items_in(col.track, rg.pos, rg.rgnend)) do R.DeleteTrackMediaItem(col.track, it); n = n + 1 end
  end)
  return n
end

-- копия блока: chunks без GUID, позиция относительно начала региона, lane
function A.cells_copy(regions, snap, r0, r1, c0, c1)
  local clip = { nr = math.abs(r1 - r0) + 1, nc = math.abs(c1 - c0) + 1, cells = {} }
  each_cell(regions, snap, r0, r1, c0, c1, function(dr, dc, rg, col)
    local list = {}
    for _, it in ipairs(items_in(col.track, rg.pos, rg.rgnend)) do
      local ok, chunk = R.GetItemStateChunk(it, '', false)
      if ok then list[#list + 1] = { chunk = strip_guids(chunk), rel = R.GetMediaItemInfo_Value(it, 'D_POSITION') - rg.pos, lane = R.GetMediaItemInfo_Value(it, 'I_FIXEDLANE') } end
    end
    clip.cells[dr] = clip.cells[dr] or {}
    clip.cells[dr][dc] = list
  end)
  return clip
end

-- вставка блока от ячейки (ri, ci): содержимое ячеек-целей заменяется;
-- items, не влезающие в регион, обрезаются по его концу
function A.cells_paste(regions, snap, ri, ci, clip)
  if not clip then return 0 end
  local n = 0
  for dr = 1, clip.nr do
    for dc = 1, clip.nc do
      local rg, col = regions[ri + dr - 1], snap.cols[ci + dc - 1]
      local list = clip.cells[dr] and clip.cells[dr][dc]
      if rg and col and list then
        for _, it in ipairs(items_in(col.track, rg.pos, rg.rgnend)) do R.DeleteTrackMediaItem(col.track, it) end
        for _, c in ipairs(list) do
          local pos = rg.pos + c.rel
          if pos < rg.rgnend - EPS then
            local it = R.AddMediaItemToTrack(col.track)
            R.SetItemStateChunk(it, unlink_chunk(c.chunk), false)        -- копия ячеек — без связи
            R.SetMediaItemInfo_Value(it, 'I_GROUPID', 0)
            R.SetMediaItemInfo_Value(it, 'D_POSITION', pos)
            if R.GetMediaTrackInfo_Value(col.track, 'I_FREEMODE') == 2 then R.SetMediaItemInfo_Value(it, 'I_FIXEDLANE', c.lane) end
            local fin = pos + R.GetMediaItemInfo_Value(it, 'D_LENGTH')
            if fin > rg.rgnend + EPS then R.SetMediaItemInfo_Value(it, 'D_LENGTH', rg.rgnend - pos) end
            n = n + 1
          end
        end
      end
    end
  end
  return n
end

-- Новый повтор src в конце проекта (от следующей границы такта после
-- последнего региона / конца проекта). Возвращает время начала.
function A.append(regions, src)
  if not src then return nil end
  local t_end = R.GetProjectLength(0)
  for _, rg in ipairs(regions) do if rg.rgnend > t_end then t_end = rg.rgnend end end
  local qn = R.TimeMap2_timeToQN(0, t_end)
  local _, qms, qme = R.TimeMap_QNToMeasures(0, qn)
  local start_qn = (qms and math.abs(qn - qms) < 1e-6) and qms or (qme or qn)
  local t0 = R.TimeMap2_QNToTime(0, start_qn)
  local len = src.rgnend - src.pos
  local dst = { pos = t0, rgnend = t0 + len, name = src.name }
  edit.run('pattern copy ' .. src.name, function()
    R.AddProjectMarker2(0, true, t0, t0 + len, src.name, -1, src.color or 0)
    for _, tr in ipairs(tracks()) do copy_span(tr, src, dst, src.name, true) end
  end)
  return t0
end

-- ── библиотека паттернов и слоты последовательности ──────────────────────
-- Слот = регион последовательности (до маркера =LIB). Переключить слот на
-- паттерн P: регион меняет длину на длину P (всё после сдвигается на
-- разницу: items всех треков кроме DEPOT, регионы и маркеры), содержимое
-- заменяется копией источника P, имя — на P. Если прежний паттерн слота
-- больше нигде не встречается, он переезжает в библиотеку (после =LIB), а
-- не удаляется.
local function bar_ceil(t)
  local qn = R.TimeMap2_timeToQN(0, t)
  local _, qms, qme = R.TimeMap_QNToMeasures(0, qn)
  if qms and math.abs(qn - qms) < 1e-6 then return t end
  return R.TimeMap2_QNToTime(0, qme or (qn + 4))
end

function A.ensure_lib(regions)
  local endp = model.marker_pos and model.marker_pos(model.END_MARKER)
  if regions.lib_pos and not (endp and regions.lib_pos < endp - EPS) then return regions.lib_pos end
  if regions.lib_pos then
    -- =LIB раньше =END — переставить за =END (маркер трекера, не пользователя)
    local i = 0
    while true do
      local ret, isrgn, pos, _, nm, _, color = R.EnumProjectMarkers3(0, i)
      if not ret or ret == 0 then break end
      if not isrgn and nm == model.LIB_MARKER then
        local nt = bar_ceil(endp)
        R.SetProjectMarkerByIndex(0, i, false, nt, 0, -1, nm, color or 0)
        return nt
      end
      i = i + 1
    end
  end
  local t = R.GetProjectLength(0)
  for _, rg in ipairs(regions) do if rg.rgnend > t then t = rg.rgnend end end
  t = bar_ceil(t) + R.TimeMap2_QNToTime(0, R.TimeMap2_timeToQN(0, 0) + 4) -- +такт
  local endp = model.marker_pos and model.marker_pos(model.END_MARKER)
  if endp and t < endp then t = endp end                    -- библиотека не раньше =END (2 окт)
  R.AddProjectMarker2(0, false, t, 0, model.LIB_MARKER, -1, 0)
  return t
end

-- сдвинуть всё, что начинается после t (включая маркеры/регионы), на delta
function A.shift_after(t, delta)
  if math.abs(delta) < 1e-9 then return end
  for _, tr in ipairs(tracks()) do
    for i = 0, R.CountTrackMediaItems(tr) - 1 do
      local it = R.GetTrackMediaItem(tr, i)
      local pos = R.GetMediaItemInfo_Value(it, 'D_POSITION')
      if pos >= t - EPS then R.SetMediaItemInfo_Value(it, 'D_POSITION', pos + delta) end
    end
  end
  local list = {}
  local i = 0
  while true do
    local ret, isrgn, pos, rgnend, name, idx, color = R.EnumProjectMarkers3(0, i)
    if not ret or ret == 0 then break end
    if pos >= t - EPS then list[#list + 1] = { i = i, isrgn = isrgn, pos = pos, rgnend = rgnend, name = name, color = color } end
    i = i + 1
  end
  -- при сдвиге вперёд идём с конца, чтобы не наехать
  table.sort(list, function(a, b) if delta > 0 then return a.pos > b.pos end return a.pos < b.pos end)
  for _, m in ipairs(list) do
    R.SetProjectMarkerByIndex(0, m.i, m.isrgn, m.pos + delta, m.isrgn and (m.rgnend + delta) or 0, -1, m.name, m.color)
  end
end

-- только маркеры/регионы от t: items двигает E.time_insert/time_delete
-- (с огибающими и разрезом на границе) — иначе items ехали дважды (ревью 1 окт)
-- keep: маркеры (не регионы) с этими именами, стоящие ровно в t, не едут —
-- вставка слота перед первым регионом не должна утащить =START (2 окт)
function A.shift_markers(t, delta, keep)
  if math.abs(delta) < 1e-9 then return end
  local list = {}
  local i = 0
  while true do
    local ret, isrgn, pos, rgnend, name, idx, color = R.EnumProjectMarkers3(0, i)
    if not ret or ret == 0 then break end
    local kept = keep and not isrgn and keep[name] and math.abs(pos - t) < EPS
    if pos >= t - EPS and not kept then list[#list + 1] = { i = i, isrgn = isrgn, pos = pos, rgnend = rgnend, name = name, color = color } end
    i = i + 1
  end
  table.sort(list, function(a, b) if delta > 0 then return a.pos > b.pos end return a.pos < b.pos end)
  for _, m in ipairs(list) do
    R.SetProjectMarkerByIndex(0, m.i, m.isrgn, m.pos + delta, m.isrgn and (m.rgnend + delta) or 0, -1, m.name, m.color)
  end
end

-- индекс маркера в EnumProjectMarkers3 по idx региона
local function marker_i(idx)
  local i = 0
  while true do
    local ret, isrgn, pos, rgnend, name, id, color = R.EnumProjectMarkers3(0, i)
    if not ret or ret == 0 then return nil end
    if isrgn and id == idx then return i, pos, rgnend, name, color end
    i = i + 1
  end
end

-- новый регион последовательности: после последнего (не библиотечного), с
-- начала следующего такта, длиной bars тактов. Маркер =END (если есть)
-- переезжает за него; библиотека (=LIB и её регионы) — если мешает — тоже.
function A.add_region(regions, name, bars)
  local t = 0
  for _, r in ipairs(regions) do if not r.lib and r.rgnend > t then t = r.rgnend end end
  t = bar_ceil(t)
  local qn = R.TimeMap2_timeToQN(0, t)
  local _, qms, qme = R.TimeMap_QNToMeasures(0, qn)
  local blen = (qme and qms) and (qme - qms) or 4
  local t1 = R.TimeMap2_QNToTime(0, qn + blen * math.max(1, bars or 1))
  -- библиотека — только =LIB ПОСЛЕ =END (2 окт: =LIB раньше =END — не библиотека;
  -- раньше сдвигалось всё после такого =LIB, вся песня уезжала на каждое «+»)
  local endp0 = model.marker_pos and model.marker_pos(model.END_MARKER)
  local lib = regions.lib_pos
  if lib and endp0 and lib < endp0 - EPS then lib = nil end
  if lib and t1 > lib + EPS then A.shift_after(lib, bar_ceil(t1) - lib) end
  local i = 0
  while true do
    local ret, isrgn, pos, _, nm, _, color = R.EnumProjectMarkers3(0, i)
    if not ret or ret == 0 then break end
    if not isrgn and nm == '=END' and pos < t1 - EPS then R.SetProjectMarkerByIndex(0, i, false, t1, 0, -1, nm, color or 0) end
    i = i + 1
  end
  R.AddProjectMarker2(0, true, t, t1, name or '', -1, 0)
  return t, t1
end

function A.rename(rg, name)
  local i, pos, rgnend, _, color = marker_i(rg.idx)
  if not i then return false end
  R.SetProjectMarkerByIndex(0, i, true, pos, rgnend, -1, name, color or 0)
  return true
end

function A.set_end(rg, t1)
  local i, pos, _, name, color = marker_i(rg.idx)
  if not i then return false end
  R.SetProjectMarkerByIndex(0, i, true, pos, t1, -1, name, color or 0)
  return true
end

-- регион → в библиотеку (новый регион после всех библиотечных + копия items)
function A.move_to_lib(regions, rg)
  local lib = A.ensure_lib(regions)
  local t = lib
  for _, r in ipairs(regions) do if r.lib and r.rgnend > t then t = r.rgnend end end
  t = bar_ceil(t)
  local len = rg.rgnend - rg.pos
  local dst = { pos = t, rgnend = t + len, name = rg.name }
  R.AddProjectMarker2(0, true, t, t + len, rg.name, -1, rg.color or 0)
  for _, tr in ipairs(tracks()) do copy_span(tr, rg, dst, rg.name) end
end

-- переключить слот (регион последовательности) на паттерн name
function A.set_slot(regions, slot, pat)
  if not slot or not pat or not pat.src then return false end
  if slot.name == pat.name then return false end
  local _, by = model.patterns(regions)
  local old = by[slot.name]
  edit.run('slot → ' .. pat.name, function()
    -- прежний паттерн: единственный экземпляр — в библиотеку
    if old and old.n <= 1 then
      local others = 0
      for _, r in ipairs(regions) do if r.name == slot.name and r.idx ~= slot.idx then others = others + 1 end end
      if others == 0 then A.move_to_lib(regions, slot) end
    end
    -- содержимое слота — долой
    for _, tr in ipairs(tracks()) do
      for _, it in ipairs(items_in(tr, slot.pos, slot.rgnend)) do R.DeleteTrackMediaItem(tr, it) end
    end
    -- длина: сдвинуть всё после конца слота
    local newlen = pat.src.rgnend - pat.src.pos
    local delta = newlen - (slot.rgnend - slot.pos)
    A.shift_after(slot.rgnend, delta)
    -- сам регион: новое имя, новая длина
    local i = 0
    while true do
      local ret, isrgn, pos, rgnend, name, idx, color = R.EnumProjectMarkers3(0, i)
      if not ret or ret == 0 then break end
      if isrgn and idx == slot.idx then
        R.SetProjectMarkerByIndex(0, i, true, slot.pos, slot.pos + newlen, -1, pat.name, pat.src.color or 0)
        break
      end
      i = i + 1
    end
    -- содержимое — копия источника (источник мог сдвинуться, если он после слота)
    local src = { pos = pat.src.pos, rgnend = pat.src.rgnend, name = pat.name }
    if src.pos >= slot.rgnend - EPS then src.pos = src.pos + delta; src.rgnend = src.rgnend + delta end
    local dst = { pos = slot.pos, rgnend = slot.pos + newlen, name = pat.name }
    for _, tr in ipairs(tracks()) do copy_span(tr, src, dst, pat.name, true) end
  end)
  return true
end

-- ── слоты матрицы как строки Vim (2 окт): o O dd yy p P D ────────────────
-- Снимок слота: имя, цвет, длина и items всех колонок (chunks без GUID,
-- позиция от начала слота). Огибающие не копируются — только items.
function A.slot_snapshot(regions, snap, ri)
  local rg = regions[ri]
  if not rg then return nil end
  local clip = A.cells_copy(regions, snap, ri, ri, 1, math.max(1, #snap.cols))
  local n = 0
  for _, list in pairs(clip.cells[1] or {}) do n = n + #list end
  return { name = rg.gap and '' or rg.name, color = rg.color or 0, len = rg.rgnend - rg.pos,
           gap = rg.gap, clip = clip, nitems = n }
end

-- вставить пустое время [t, t+len) во все треки, регионы и маркеры после t
-- едут; =START в точке t остаётся. Без своего undo — внутри edit.run.
function A.open_time(t, len)
  local trs = {}
  for ti = 0, R.CountTracks(0) - 1 do trs[#trs + 1] = R.GetTrack(0, ti) end
  A.shift_markers(t, len, { [model.START_MARKER or '=START'] = true })
  edit.time_insert(trs, t, len, math.huge)
end

-- новый слот в t длиной len: регион (если не пустой такт) + items снимка
function A.put_slot(snap, t, sl)
  A.open_time(t, sl.len)
  if not sl.gap then R.AddProjectMarker2(0, true, t, t + sl.len, sl.name or '', -1, sl.color or 0) end
  if sl.clip then return A.cells_paste({ { pos = t, rgnend = t + sl.len } }, snap, 1, 1, sl.clip) end
  return 0
end

-- связанный повтор (dup, 3 окт): регион src повторяется в t — то же имя,
-- items связаны (пул MIDI + группа); всё после t едет на длину
function A.put_alias(src, t)
  local len = src.rgnend - src.pos
  local s0 = src.pos
  A.open_time(t, len)
  -- исходник мог уехать, если он после t
  local sp = { pos = s0 >= t - EPS and (s0 + len) or s0 }
  sp.rgnend = sp.pos + len
  R.AddProjectMarker2(0, true, t, t + len, src.name or '', -1, src.color or 0)
  A.reset_groups()
  local dst = { pos = t, rgnend = t + len }
  local n = 0
  for _, tr in ipairs(tracks()) do n = n + copy_span(tr, sp, dst, src.name, true) end
  return n
end

-- make unique (3 окт, как в Renoise): повтор отвязывается — новое имя
-- (свой паттерн), MIDI — свой пул, items — без группы. Без своего undo.
function A.make_unique(regions, rg)
  local name = A.free_name(regions, rg.name)
  A.rename(rg, name)
  local n = 0
  for _, tr in ipairs(tracks()) do
    for _, it in ipairs(items_in(tr, rg.pos, rg.rgnend)) do
      local ok, chunk = R.GetItemStateChunk(it, '', false)
      if ok and chunk:find('POOLEDEVTS') then R.SetItemStateChunk(it, unlink_chunk(chunk), false) end
      R.SetMediaItemInfo_Value(it, 'I_GROUPID', 0)
      R.GetSetMediaItemInfo_String(it, 'P_EXT:jf_pattern', name, true)
      n = n + 1
    end
  end
  return name, n
end

-- удалить слот: регион, время слота во всех треках, простые маркеры внутри;
-- всё после конца слота едет назад
function A.delete_slot(rg)
  local len = rg.rgnend - rg.pos
  if not rg.gap then
    local i = marker_i(rg.idx)
    if i then R.DeleteProjectMarkerByIndex(0, i) end
  end
  local i = 0
  while true do
    local ret, isrgn, pos, _, name, idx = R.EnumProjectMarkers3(0, i)
    if not ret or ret == 0 then break end
    if not isrgn and pos > rg.pos + EPS and pos < rg.rgnend - EPS and not name:match('^=') then
      R.DeleteProjectMarkerByIndex(0, i)
    else i = i + 1 end
  end
  local trs = {}
  for ti = 0, R.CountTracks(0) - 1 do trs[#trs + 1] = R.GetTrack(0, ti) end
  edit.time_delete(trs, rg.pos, rg.rgnend, math.huge)
  A.shift_markers(rg.rgnend, -len)
end

-- свободное имя для дубля: «name 2», «name 3» … (числовое имя — следующее число)
function A.free_name(regions, name)
  local used = {}
  for _, r in ipairs(regions) do used[r.name] = true end
  if name == '' then return '' end
  local num = tonumber(name)
  if num then
    local k = num + 1
    while used[('%0' .. #name .. 'd'):format(k)] do k = k + 1 end
    return ('%0' .. #name .. 'd'):format(k)
  end
  local base = name:gsub('%s+%d+$', '')
  local k = 2
  while used[base .. ' ' .. k] do k = k + 1 end
  return base .. ' ' .. k
end

return A
