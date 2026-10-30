-- jf_tracker_undosnap.lua — снимок состояния проекта для ветвей дерева undo (15 окт).
-- Что снимается — то, что REAPER пишет в .rpp: chunk каждого трека (items, FX, огибающие) по
-- порядку, мастер, маркеры и регионы, темп-карта. Восстановление — одним шагом undo REAPER.
-- Упаковка — UT.pack / UT.unpack (jf_tracker_undotree.lua).

local R = reaper
local US = {}

-- → данные снимка (строка)
function US.capture(UT)
  local parts = {}
  for i = 0, R.CountTracks(0) - 1 do
    local tr = R.GetTrack(0, i)
    local ok, ch = R.GetTrackStateChunk(tr, '', true)
    if ok then parts[#parts + 1] = { 'T', R.GetTrackGUID(tr) .. '\n' .. ch } end
  end
  local okm, mch = R.GetTrackStateChunk(R.GetMasterTrack(0), '', true)
  if okm then parts[#parts + 1] = { 'M', mch } end
  local mk = {}   -- 15 окт: имя в скобках — gsub отдаёт и число замен, оно влезало в имя маркера
  local _, nm, nr = R.CountProjectMarkers(0)
  for k = 0, nm + nr - 1 do
    local ok, isrgn, pos, rend, name, idx, col = R.EnumProjectMarkers3(0, k)
    if ok and ok > 0 then mk[#mk + 1] = table.concat({ isrgn and 1 or 0, pos, rend, idx, col, ((name or ''):gsub('[\t\n]', ' ')) }, '\t') end
  end
  parts[#parts + 1] = { 'K', table.concat(mk, '\n') }
  local tm = {}
  for k = 0, R.CountTempoTimeSigMarkers(0) - 1 do
    local ok, tpos, _, _, bpm, num, den, lin = R.GetTempoTimeSigMarker(0, k)
    if ok then tm[#tm + 1] = table.concat({ tpos, bpm, num, den, lin and 1 or 0 }, '\t') end
  end
  parts[#parts + 1] = { 'P', table.concat(tm, '\n') }
  return UT.pack(parts)
end

local function lines(s) local t = {}; for l in (s or ''):gmatch('[^\n]+') do t[#t + 1] = l end; return t end

-- восстановить снимок; label — подпись шага undo
function US.restore(UT, data, label)
  local parts = UT.unpack(data)
  if #parts == 0 then return false end
  R.Undo_BeginBlock2(0)
  R.PreventUIRefresh(1)
  local want, master, marks, tempo = {}, nil, nil, nil
  for _, p in ipairs(parts) do
    if p[1] == 'T' then
      local guid, ch = p[2]:match('^([^\n]*)\n(.*)$')
      if guid then want[#want + 1] = { guid = guid, chunk = ch } end
    elseif p[1] == 'M' then master = p[2]
    elseif p[1] == 'K' then marks = p[2]
    elseif p[1] == 'P' then tempo = p[2] end
  end
  -- 30 окт: карта темпа — первой. Позиции в chunk'ах и маркерах — секунды по карте снимка; при тайм-базе «доли»
  -- REAPER сам двигает айтемы и регионы на каждой смене темпа — восстановленные до неё съезжали с долей
  if tempo then
    for k = R.CountTempoTimeSigMarkers(0) - 1, 0, -1 do R.DeleteTempoTimeSigMarker(0, k) end
    for _, l in ipairs(lines(tempo)) do
      local tp, bpm, num, den, lin = l:match('^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)$')
      if tp then R.SetTempoTimeSigMarker(0, -1, tonumber(tp), -1, -1, tonumber(bpm), tonumber(num), tonumber(den), lin == '1') end
    end
    R.UpdateTimeline()
  end
  -- треки: лишние — прочь, недостающие — вставить, порядок — как в снимке, chunk — из снимка
  local keep = {}
  for _, w in ipairs(want) do keep[w.guid] = true end
  for i = R.CountTracks(0) - 1, 0, -1 do
    local tr = R.GetTrack(0, i)
    if not keep[R.GetTrackGUID(tr)] then R.DeleteTrack(tr) end
  end
  for i, w in ipairs(want) do
    local at
    for j = 0, R.CountTracks(0) - 1 do if R.GetTrackGUID(R.GetTrack(0, j)) == w.guid then at = j; break end end
    if not at then
      R.InsertTrackAtIndex(i - 1, false)
      at = i - 1
    elseif at ~= i - 1 then
      R.SetOnlyTrackSelected(R.GetTrack(0, at))
      R.ReorderSelectedTracks(i - 1, 0)
      at = i - 1
    end
    R.SetTrackStateChunk(R.GetTrack(0, at), w.chunk, false)
  end
  if master then R.SetTrackStateChunk(R.GetMasterTrack(0), master, false) end
  if marks then
    local _, nm, nr = R.CountProjectMarkers(0)
    for k = nm + nr - 1, 0, -1 do R.DeleteProjectMarkerByIndex(0, k) end
    for _, l in ipairs(lines(marks)) do
      local isr, pos, rend, idx, col, name = l:match('^(%d)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$')
      if isr then R.AddProjectMarker2(0, isr == '1', tonumber(pos), tonumber(rend), name, tonumber(idx), tonumber(col)) end
    end
  end
  R.PreventUIRefresh(-1)
  R.TrackList_AdjustWindows(false)
  R.UpdateArrange()
  R.Undo_EndBlock2(0, label or 'undotree: to a branch', -1)
  return true
end

return US
